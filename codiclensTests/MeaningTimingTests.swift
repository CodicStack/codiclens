import Foundation
import Testing
@testable import codiclens

private let secondsPerKind = ProcessInfo.processInfo.environment["CODICLENS_TIME_MEANING"].flatMap { Double($0) }
private let scaleRows = ProcessInfo.processInfo.environment["CODICLENS_TIME_MEANING_SCALE"].flatMap { Int($0) }
/// A Release build's app binary to run as both helpers, so the rates are
/// the shipping ones: `Embedder`'s Swift around llama.cpp (image sizing, RGB
/// packing) is many times slower in Debug.
private let helperBinary = ProcessInfo.processInfo.environment["CODICLENS_HELPER_BINARY"].map(URL.init(fileURLWithPath:))

/// Search by meaning over this Mac's real Downloads, Documents and Desktop,
/// into a temporary database: the crawl and the contents pass in full, then
/// the meaning pass with the real model for at most N seconds of each kind of
/// file (newest first, as the backfill goes), which gives its rate and from
/// that an estimate of the whole backfill; what the vectors add to the
/// database; and a Query's cost — the vector, scoring every vector, fusing —
/// on what was embedded and on 300,000 vectors made up for the purpose. The
/// files are only read. Off unless asked for; the value is N.
/// `TEST_RUNNER_CODICLENS_HELPER_BINARY=<…/Release/codiclens.app/Contents/MacOS/codiclens>`
/// runs a Release build as the helpers. `TEST_RUNNER_CODICLENS_TIME_MEANING_SCALE=<rows>`
/// times scoring alone, on that many vectors of noise.
///
/// ```
/// TEST_RUNNER_CODICLENS_TIME_MEANING=60 xcodebuild test \
///   -project codiclens.xcodeproj -scheme codiclens -configuration Debug \
///   -parallel-testing-enabled NO -only-testing:codiclensTests/MeaningTimingTests
/// ```
@Suite(.serialized, .enabled(if: secondsPerKind != nil || scaleRows != nil), .timeLimit(.minutes(180)))
struct MeaningTimingTests {
    static func helper(textOnly: Bool) -> EmbeddingClient {
        guard let helperBinary else { return EmbeddingClient.helper(textOnly: textOnly, idleExit: 60) }
        var options = EmbeddingService.Options()
        options.textOnly = textOnly
        return EmbeddingClient(launcher: HelperProcessLauncher(
            executable: helperBinary, options: options, qualityOfService: textOnly ? .userInitiated : .utility
        ))
    }

    @Test(.enabled(if: scaleRows != nil)) func scoringAtScale() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try Self.scoreAtScale(folder: folder, rows: scaleRows ?? 300_000)
    }

    static let queries = ["kontrakt", "smoothie opskrift", "faktura fra tandlægen", "screenshot of an error",
                          "invoice 2024", "a", "how to retry with backoff"]

    @Test(.enabled(if: secondsPerKind != nil)) func backfillAndQueryTimings() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = folder.url.appendingPathComponent("FileIndex.sqlite")
        let writer = try FileIndexWriter(url: url)
        let indexer = FileIndexer(writer: writer, rules: timingRules)
        let roots = SourceStore.defaultFolders.map { FileIndexer.realPath($0) }

        let reading = try await ContinuousClock().measure {
            for root in try indexer.setSources(roots.map { (path: $0, isEnabled: true) }) { try indexer.crawl(root) }
            let contents = FileContentScheduler(writer: writer, queue: DispatchQueue(label: "timing.contents"))
            contents.setSources(roots)
            while true {
                let jobs = try contents.nextBatch()
                if jobs.isEmpty { break }
                try contents.store(await FileContentScheduler.readAll(jobs))
            }
        }
        try writer.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let before = try Self.size(of: url)
        print("crawl and contents \(reading), database \(before / 1_048_576) MB")

        let embedder = Self.helper(textOnly: false)
        let vectors = MeaningVectors(databaseURL: url)
        let cache = try VectorCache(url: VectorCache.url(besideDatabase: url))
        let meaning = MeaningScheduler(writer: writer, vectors: vectors, cache: cache, queue: DispatchQueue(label: "timing.meaning"),
                                       embed: MeaningScheduler.embedAll(with: embedder, cache: cache))
        meaning.setSources(roots)
        try meaning.enable()
        // The helper's model load, apart from the work.
        let load = try await ContinuousClock().measure { _ = try await embedder.embed(texts: ["warm up"]) }
        print("indexing helper started in \(load)")

        let budget = Duration.seconds(secondsPerKind ?? 60)
        var estimate = Duration.zero
        print("kind          files  vectors  time       per vector  left: files  vectors  ≈ time")
        for kind in FileContent.allCases {
            var files = 0
            var stored = 0
            let started = ContinuousClock.now
            while ContinuousClock.now - started < budget {
                var ids: [Int64] = []
                try writer.db.query("""
                    SELECT id FROM files WHERE content = ? AND state != 'pending' AND vec_state != 'done'
                    ORDER BY vec_state DESC, mtime DESC LIMIT ?
                    """, [.int(Int64(kind.rawValue)), .int(kind == .pdf || kind == .audio || kind == .video ? 1 : 8)]) {
                    ids.append($0.int(0))
                }
                let jobs = try writer.meaningJobs(ids: ids).jobs
                if jobs.isEmpty { break }
                var results: [MeaningResult] = []
                for job in jobs { results.append(try await MeaningReader.read(job, with: embedder, cache: cache)) }
                files += jobs.count
                stored += results.reduce(0) { $0 + $1.vectors.count }
                try meaning.store(results)
            }
            let time = ContinuousClock.now - started
            let (leftFiles, leftTexts) = try Self.left(kind, writer: writer)
            let perVector = stored > 0 ? time / stored : .zero
            let perFile = files > 0 ? time / files : .zero
            // Text is counted by Passage, everything else by file.
            let left = kind.hasWords && kind != .screenshot ? perVector * leftTexts : perFile * leftFiles
            estimate += left
            print([
                "\(kind)".padding(toLength: 12, withPad: " ", startingAt: 0),
                "\(files)".padding(toLength: 7, withPad: " ", startingAt: 0),
                "\(stored)".padding(toLength: 9, withPad: " ", startingAt: 0),
                Self.format(time).padding(toLength: 11, withPad: " ", startingAt: 0),
                Self.format(perVector).padding(toLength: 12, withPad: " ", startingAt: 0),
                "\(leftFiles)".padding(toLength: 13, withPad: " ", startingAt: 0),
                "\(leftTexts)".padding(toLength: 9, withPad: " ", startingAt: 0),
                Self.format(left),
            ].joined())
        }
        print("the rest of the backfill ≈ \(Self.format(estimate)) at these rates")
        await embedder.shutdown()

        try writer.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let after = try Self.size(of: url)
        let rows = vectors.liveCount
        let sidecar = try Self.size(of: vectors.vectorsURL) + Self.size(of: vectors.rowsURL)
        let cached = try Self.size(of: cache.url) + ((try? Self.size(of: URL(fileURLWithPath: cache.url.path + "-wal"))) ?? 0)
        print("\(rows) vectors: database \(before / 1_048_576) → \(after / 1_048_576) MB "
              + "(\(rows > 0 ? (after - before) / rows : 0) bytes a vector), vector files \(sidecar / 1_048_576) MB, "
              + "cache \(cached / 1_048_576) MB (\(cache.count) inputs)")

        let encoder = Self.helper(textOnly: true)
        try await encoder.hold()
        let reader = FileIndexReader(url: url)
        print("query                       embed    score+scale  fuse     hits (meaning)")
        for query in Self.queries {
            var embed: [Duration] = [], score: [Duration] = [], fuse: [Duration] = []
            var hits: [FileHit] = []
            for _ in 0..<5 {
                var vector: [Float] = []
                embed.append(try await ContinuousClock().measure { vector = try await encoder.embedQuery(query, code: false) })
                var scores = MeaningScores.none
                score.append(ContinuousClock().measure {
                    scores = vectors.snapshot().map { MeaningScores($0, query: vector) } ?? .none
                })
                fuse.append(ContinuousClock().measure {
                    hits = reader.fusedSearch(query, limit: 50, sources: roots, meaning: scores)
                })
            }
            print([
                query.padding(toLength: 28, withPad: " ", startingAt: 0),
                Self.format(Self.median(embed)).padding(toLength: 9, withPad: " ", startingAt: 0),
                Self.format(Self.median(score)).padding(toLength: 13, withPad: " ", startingAt: 0),
                Self.format(Self.median(fuse)).padding(toLength: 9, withPad: " ", startingAt: 0),
                "\(hits.count) (\(hits.filter { $0.meaning != nil }.count))",
            ].joined())
            for hit in hits.prefix(3) {
                print("    \(hit.score) \(hit.name) \(hit.meaning.map { "\($0)" } ?? "") \(hit.passage?.subtitle.prefix(60) ?? "")")
            }
        }
        await encoder.shutdown()

        try Self.scoreAtScale(folder: folder, rows: 300_000)
    }

    /// Scoring and scaling 300,000 vectors of noise: the cost a Query pays
    /// on an index the size of this Mac's, apart from what is in it.
    static func scoreAtScale(folder: TemporaryFolder, rows: Int) throws {
        let vectors = MeaningVectors(databaseURL: folder.url.appendingPathComponent("scale.sqlite"))
        try vectors.rebuild { emit in
            var generator = SystemRandomNumberGenerator()
            for index in 0..<rows {
                let vector = EmbeddingVector.normalized((0..<EmbeddingVector.dimension).map { _ in
                    Float.random(in: -1...1, using: &generator)
                })
                try emit(MeaningVectors.Row(segment: Int64(index + 1), file: Int64(index / 6 + 1),
                                            modality: index % 10 == 0 ? .image : .text, setsScale: true),
                         EmbeddingVector.float16Data(vector))
            }
        }
        let snapshot = try #require(vectors.snapshot())
        let query = EmbeddingVector.normalized((0..<EmbeddingVector.dimension).map { _ in Float.random(in: -1...1) })
        var cosine: [Duration] = [], whole: [Duration] = []
        for _ in 0..<7 {
            cosine.append(ContinuousClock().measure { _ = snapshot.scores(query) })
            whole.append(ContinuousClock().measure { _ = MeaningScores(snapshot, query: query) })
        }
        print("\(rows) vectors: cosine \(format(median(cosine))), with the scale and the best per file "
              + "\(format(median(whole))) (median of 7)")
    }

    /// Files of `kind` still to embed, and Passages of it still without a
    /// vector.
    static func left(_ kind: FileContent, writer: FileIndexWriter) throws -> (files: Int, texts: Int) {
        var files = 0, texts = 0
        try writer.db.query("SELECT COUNT(*) FROM files WHERE content = ? AND vec_state != 'done'",
                            [.int(Int64(kind.rawValue))]) { files = Int($0.int(0)) }
        try writer.db.query("""
            SELECT COUNT(*) FROM segments s JOIN files f ON f.id = s.file
            WHERE f.content = ? AND s.vec_key IS NULL AND s.kind IN ('chunk', 'page')
            """, [.int(Int64(kind.rawValue))]) { texts = Int($0.int(0)) }
        return (files, texts)
    }

    static func median(_ samples: [Duration]) -> Duration { samples.sorted()[samples.count / 2] }

    static func size(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        if seconds >= 3600 { return String(format: "%.1f h", seconds / 3600) }
        if seconds >= 60 { return String(format: "%.1f min", seconds / 60) }
        if seconds >= 10 { return String(format: "%.1f s", seconds) }
        return String(format: "%.1f ms", seconds * 1000)
    }
}
