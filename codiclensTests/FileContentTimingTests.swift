import Foundation
import Testing
@testable import codiclens

private let timingRuns = ProcessInfo.processInfo.environment["CODICLENS_TIME_FILE_CONTENTS"].flatMap { Int($0) }

/// The contents layer over this Mac's real Downloads, Documents and Desktop
/// under the default skip rules (`timingRules`, which can turn "Ignored by
/// git" off): how long the backfill takes per kind of
/// file, how much it adds to the database and with what, and how long a
/// search takes once names and contents are both in. Not a pass/fail test —
/// the numbers depend on what is on disk and how busy the Mac is — so it is
/// off unless asked for. The files are only read; the database goes to a
/// temporary folder, never Application Support.
///
/// ```
/// TEST_RUNNER_CODICLENS_TIME_FILE_CONTENTS=20 xcodebuild test \
///   -project codiclens.xcodeproj -scheme codiclens -configuration Debug \
///   -only-testing:codiclensTests/FileContentTimingTests
/// ```
///
/// The variable's value is the number of runs per Query; each is their median.
@Suite(.serialized, .enabled(if: timingRuns != nil), .timeLimit(.minutes(120)))
struct FileContentTimingTests {
    static let queries = ["invoice", "skat", "kontrakt", "func", "a"]

    @Test func backfillAndQueryTimings() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try await Self.measure(url: folder.url.appendingPathComponent("FileIndex.sqlite"), runs: timingRuns ?? 1)
    }

    private static func measure(url: URL, runs: Int) async throws {
        let writer = try FileIndexWriter(url: url)
        let indexer = FileIndexer(writer: writer, rules: timingRules)
        let roots = SourceStore.defaultFolders.map { FileIndexer.realPath($0) }
        print("rules: \(timingRules.skipped.map(\.rawValue).sorted().joined(separator: ", "))")

        let crawl = ContinuousClock().measure {
            let toCrawl = (try? indexer.setSources(roots.map { (path: $0, isEnabled: true) })) ?? []
            for root in toCrawl { try? indexer.crawl(root) }
        }
        try writer.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let namesSize = try size(of: url)
        let reader = FileIndexReader(url: url)
        let before = reader.counts()
        print("crawl \(ms(crawl)), \(before.values.map(\.total).reduce(0, +)) rows, \(namesSize / 1024) KB, "
              + "\(before.values.map(\.indexed).reduce(0, +)) with nothing to read")

        // The backfill as the app runs it, a batch at a time, with each file
        // timed on its own so the cost can be put on each kind.
        let contents = FileContentScheduler(writer: writer, queue: DispatchQueue(label: "timing.contents"))
        contents.setSources(roots)
        var perKind: [String: (files: Int, time: Duration)] = [:]
        var firstPass: Duration = .zero
        var laterSteps: Duration = .zero
        var batches = 0
        let start = ContinuousClock.now
        while true {
            let jobs = try contents.nextBatch()
            guard !jobs.isEmpty else { break }
            var results: [FileContentResult] = []
            for job in jobs {
                var result: FileContentResult?
                let time = await ContinuousClock().measure { result = await FileContentReader.read(job) }
                let key = "\(job.content)" + (job.readTo > 0 ? " (later steps)" : "")
                perKind[key, default: (0, .zero)].files += 1
                perKind[key, default: (0, .zero)].time += time
                if job.readTo == 0 { firstPass += time } else { laterSteps += time }
                if let result { results.append(result) }
            }
            try contents.store(results)
            batches += 1
            if batches % 500 == 0 {
                print("  … \(batches) batches, \(ms(ContinuousClock.now - start))")
            }
        }
        let backfill = ContinuousClock.now - start
        try writer.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let contentsSize = try size(of: url)

        print("backfill \(ms(backfill)) in \(batches) batches: reading \(ms(firstPass)) first steps, "
              + "\(ms(laterSteps)) later steps, the rest storing")
        for (kind, cost) in perKind.sorted(by: { $0.key < $1.key }) {
            print("  \(kind.padding(toLength: 28, withPad: " ", startingAt: 0)) \(cost.files) files  \(ms(cost.time))")
        }
        print("database \(namesSize / 1024) KB → \(contentsSize / 1024) KB")
        try printCounts(writer: writer)

        print("query       hits  contents  first search  median")
        for query in queries {
            let cold = FileIndexReader(url: url)
            var hits: [FileHit] = []
            let first = ContinuousClock().measure { hits = cold.search(query, limit: 50, sources: roots) }
            var samples: [Duration] = []
            for _ in 0..<runs {
                samples.append(ContinuousClock().measure { hits = reader.search(query, limit: 50, sources: roots) })
            }
            print([
                query.padding(toLength: 12, withPad: " ", startingAt: 0),
                "\(hits.count)".padding(toLength: 6, withPad: " ", startingAt: 0),
                "\(hits.filter { $0.passage != nil }.count)".padding(toLength: 10, withPad: " ", startingAt: 0),
                ms(first).padding(toLength: 14, withPad: " ", startingAt: 0),
                ms(samples.sorted()[samples.count / 2])
            ].joined())
            for hit in hits.prefix(2) + hits.filter({ $0.passage != nil }).prefix(2) {
                print("    \(hit.score)  \(hit.name)  \(hit.passage.map { "“\($0.subtitle.prefix(70))”" } ?? "(\(hit.folder))")")
            }
        }
    }

    /// Files by what is read from them and how far it got, why nothing was
    /// read where nothing was, and Passages by kind.
    private static func printCounts(writer: FileIndexWriter) throws {
        print("files by content, state:")
        try writer.db.query("""
            SELECT content, state, COUNT(*), SUM(size) FROM files WHERE content IS NOT NULL
            GROUP BY content, state ORDER BY content, state
            """) { row in
            let content = FileContent(rawValue: Int(row.int(0))).map { "\($0)" } ?? "?"
            print("  \(content.padding(toLength: 12, withPad: " ", startingAt: 0)) \(row.text(1) ?? "")  "
                  + "\(row.int(2)) files, \(row.int(3) / 1_048_576) MB")
        }
        print("nothing read, by reason:")
        try writer.db.query("""
            SELECT content, detail, COUNT(*) FROM files WHERE detail IS NOT NULL GROUP BY content, detail ORDER BY 3 DESC
            """) { row in
            let content = FileContent(rawValue: Int(row.int(0))).map { "\($0)" } ?? "?"
            print("  \(content.padding(toLength: 12, withPad: " ", startingAt: 0)) \(row.text(1) ?? ""): \(row.int(2))")
        }
        print("documents and text read, by extension (top 25):")
        var byExtension: [String: (files: Int, passages: Int)] = [:]
        try writer.db.query("""
            SELECT f.path, (SELECT COUNT(*) FROM segments s WHERE s.file = f.id) FROM files f
            WHERE f.content IS NOT NULL AND (f.detail IS NULL OR f.detail LIKE 'first%')
            """) { row in
            let name = ((row.text(0) ?? "") as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            let key = ext.isEmpty ? "(none)" : ext
            byExtension[key, default: (0, 0)].files += 1
            byExtension[key, default: (0, 0)].passages += Int(row.int(1))
        }
        for (ext, count) in byExtension.sorted(by: { $0.value.files > $1.value.files }).prefix(25) {
            print("  \(ext.padding(toLength: 12, withPad: " ", startingAt: 0)) \(count.files) files, \(count.passages) passages")
        }
        print("passages by kind:")
        try writer.db.query("SELECT kind, COUNT(*) FROM segments GROUP BY kind") { row in
            print("  \(row.text(0) ?? ""): \(row.int(1))")
        }
    }

    private static func size(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private static func ms(_ duration: Duration) -> String {
        let millis = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return millis >= 10_000 ? String(format: "%.1f s", millis / 1000) : String(format: "%.1f ms", millis)
    }
}
