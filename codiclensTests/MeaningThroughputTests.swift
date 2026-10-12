import Foundation
import Synchronization
import Testing
@testable import codiclens

private let measureSeconds = ProcessInfo.processInfo.environment["CODICLENS_MEASURE_THROUGHPUT"].flatMap { Double($0) }

/// The meaning backfill's speed with the real model and helpers, on text cut
/// from this repository into files shaped like the dev machine's backlog
/// (half of them one chunk, a few past 40): texts per call to the helper;
/// files per batch with a batch's texts sent together; and the gentle and
/// full pace (`MeaningPace`) through the real batch loop, with a warm Query's
/// latency beside each. Everything in temporary folders; the model files are
/// only read. Off unless asked for; the value is at most how many seconds
/// each run embeds. The model files must be there (`ModelFilesDownloadTests`).
///
/// ```
/// TEST_RUNNER_CODICLENS_MEASURE_THROUGHPUT=60 xcodebuild test \
///   -project codiclens.xcodeproj -scheme codiclens -configuration Debug \
///   -parallel-testing-enabled NO -only-testing:codiclensTests/MeaningThroughputTests
/// ```
@Suite(.serialized, .enabled(if: measureSeconds != nil), .timeLimit(.minutes(60)))
struct MeaningThroughputTests {
    let seconds = measureSeconds ?? 30

    /// This repository's Swift and Markdown, joined.
    static func corpus() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var text = try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        let folder = root.appendingPathComponent("codiclens")
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() where name.hasSuffix(".swift") {
            text += try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
        }
        return text
    }

    /// Files cut from `corpus()`, by size: 120 of ~700 characters, 60 of
    /// 3,000, 40 of 10,000, 15 of 40,000 and 6 of 80,000 — about 1,100
    /// first-step chunks.
    static func makeFiles(in folder: TemporaryFolder) throws {
        let text = Array(try corpus().unicodeScalars)
        var offset = 0
        var index = 0
        for (count, size) in [(120, 700), (60, 3000), (40, 10_000), (15, 40_000), (6, 80_000)] {
            for _ in 0..<count {
                if offset + size > text.count { offset = 0 }
                var piece = String(String.UnicodeScalarView(text[offset..<(offset + size)]))
                piece += "\nfile \(index)"
                try folder.makeFile("Source/f\(index)\(index % 2 == 0 ? ".md" : ".swift")", contents: piece)
                offset += size
                index += 1
            }
        }
    }

    /// A database of `files` with its contents read, beside a cache of its
    /// own: nothing embedded yet.
    struct Run {
        let folder: TemporaryFolder
        let writer: FileIndexWriter
        let cache: VectorCache
        let vectors: MeaningVectors
        let root: String

        init(files: TemporaryFolder) async throws {
            folder = try TemporaryFolder()
            let url = folder.url.appendingPathComponent("FileIndex.sqlite")
            cache = try VectorCache(url: VectorCache.url(besideDatabase: url))
            writer = try FileIndexWriter(url: url, cache: cache)
            root = files.path("Source")
            let indexer = FileIndexer(writer: writer)
            for root in try indexer.setSources([(path: root, isEnabled: true)]) { try indexer.crawl(root) }
            let contents = FileContentScheduler(writer: writer, queue: DispatchQueue(label: "throughput.contents"))
            contents.setSources([root])
            while true {
                let jobs = try contents.nextBatch()
                guard !jobs.isEmpty else { break }
                try contents.store(await FileContentScheduler.readAll(jobs))
            }
            vectors = MeaningVectors(databaseURL: url)
        }
    }

    static func rate(_ count: Int, _ duration: Duration) -> Double {
        Double(count) / (Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    @Test func textsPerCall() async throws {
        try await #require(MainActor.run { ModelFiles().isReady }, "download the model files first")
        let client = EmbeddingClient.helper(textOnly: false, idleExit: 60)
        try await client.hold()
        let corpus = Array(try Self.corpus())
        let long = stride(from: 0, to: corpus.count - 1800, by: 1800).map { String(corpus[$0..<($0 + 1700)]) }
        for (label, texts) in [("1,700", long), ("700", long.map { String($0.prefix(700)) })] {
            for size in [1, 4, 8, 16, 32, 64] {
                var done = 0
                let clock = ContinuousClock()
                let started = clock.now
                while clock.now - started < .seconds(seconds / 4) {
                    let batch = (0..<size).map { EmbeddingPrompt.document(title: "t", text: texts[(done + $0) % texts.count] + " \(done + $0)") }
                    done += try await client.embed(texts: batch).count
                }
                print(String(format: "texts of %@ characters, %2d a call: %.1f vectors/s", label, size,
                             Self.rate(done, clock.now - started)))
            }
        }
        await client.shutdown()
    }

    @Test func filesPerBatch() async throws {
        try await #require(MainActor.run { ModelFiles().isReady }, "download the model files first")
        let files = try TemporaryFolder()
        defer { files.remove() }
        try Self.makeFiles(in: files)
        let client = EmbeddingClient.helper(textOnly: false, idleExit: 60)
        try await client.hold()
        await client.setFullSpeed(true)
        for size in [1, 8, 16, 32, 64] {
            let run = try await Run(files: files)
            defer { run.folder.remove() }
            _ = try run.writer.adoptMeaningFingerprint()
            let clock = ContinuousClock()
            let started = clock.now
            var done = 0
            while clock.now - started < .seconds(seconds) {
                let jobs = MeaningScheduler.batch(from: try run.writer.meaningJobs(limit: size, sources: [run.root]), size: size)
                guard !jobs.isEmpty else { break }
                let results = try await Task.detached(priority: .utility) {
                    try await MeaningReader.read(jobs, with: client, cache: run.cache)
                }.value
                try run.writer.db.transaction { for result in results { done += try run.writer.storeMeaning(result)?.count ?? 0 } }
            }
            print(String(format: "%2d files a batch: %.1f vectors/s (%d vectors)", size, Self.rate(done, clock.now - started), done))
        }
        await client.shutdown()
    }

    @Test func gentleAndFullThroughTheBatchLoop() async throws {
        try await #require(MainActor.run { ModelFiles().isReady }, "download the model files first")
        let files = try TemporaryFolder()
        defer { files.remove() }
        try Self.makeFiles(in: files)
        let encoder = EmbeddingClient.helper(textOnly: true, idleExit: 60)
        try await encoder.hold()
        var alone: [Duration] = []
        for index in 0..<20 {
            alone.append(try await ContinuousClock().measure { _ = try await encoder.embedQuery("receipt \(index)") })
            try await Task.sleep(for: .milliseconds(500))
        }
        alone.sort()
        print("no backfill here: a Query median \(alone[10]), p90 \(alone[18])")

        for pace in [MeaningPace.gentle, .full, .gentle, .full] {
            let run = try await Run(files: files)
            defer { run.folder.remove() }
            let client = EmbeddingClient.helper(textOnly: false, idleExit: 60)
            _ = try await client.embed(texts: ["warm up"])
            let queue = DispatchQueue(label: "throughput.meaning")
            let (stored, storedContinuation) = AsyncStream.makeStream(of: Void.self)
            let machine = MeaningPace.Machine(isOnPower: { true }, idleSeconds: { pace == .full ? 3600 : 0 })
            let meaning = MeaningScheduler(writer: run.writer, vectors: run.vectors, cache: run.cache, queue: queue,
                                           embed: MeaningScheduler.embedAll(with: client, cache: run.cache),
                                           machine: machine, onProgress: { _ in storedContinuation.yield() })
            meaning.setSources([run.root])
            try queue.sync { try meaning.enable() }

            // A Query every half second meanwhile, as someone typing would.
            let latencies = Mutex<[Duration]>([])
            let querying = Task {
                var index = 0
                while !Task.isCancelled {
                    let latency = try await ContinuousClock().measure { _ = try await encoder.embedQuery("invoice \(index)") }
                    latencies.withLock { $0.append(latency) }
                    index += 1
                    try await Task.sleep(for: .milliseconds(500))
                }
            }

            let clock = ContinuousClock()
            let started = clock.now
            var last = (time: Duration.zero, count: 0)
            queue.async { meaning.resume() }
            for await _ in stored {
                last = (clock.now - started, queue.sync { run.vectors.liveCount })
                if last.time > .seconds(seconds) || queue.sync(execute: { try? meaning.nextBatch().isEmpty }) == true { break }
            }
            querying.cancel()
            queue.sync { meaning.disable() }
            await client.shutdown()
            let sorted = latencies.withLock { $0 }.sorted()
            print(String(format: "%@: %.1f vectors/s (%d vectors in %@); a Query meanwhile median %@, p90 %@",
                         "\(pace)", Self.rate(last.count, last.time), last.count, "\(last.time)",
                         "\(sorted[sorted.count / 2])", "\(sorted[sorted.count * 9 / 10])"))
        }
        await encoder.shutdown()
    }
}
