import Foundation

/// The background pass that gives the File Index its vectors: search by
/// meaning's half of indexing, beside the contents pass and like it.
///
/// Lives on the File Index's queue beside the writer. A batch of
/// `MeaningJob`s goes to `MeaningReader` off the queue, which takes what
/// `VectorCache` already has and asks the indexing helper (`EmbeddingClient`,
/// the full model, ~1 GB while it works, gone after its idle exit) for the
/// rest; the results come back to the queue, are stored in one transaction
/// and appended to `MeaningVectors`, where the next search scores them. One
/// batch at a time, and each store starts the next: nothing is timed.
///
/// Order: files that changed while the app runs first (FSEvents), the newest
/// `burstCap` of a burst, in any power state; a changed text file as soon as
/// the contents pass has read it. Then the backfill: every file's first step
/// before any file's later ones, in `FileContent`'s order — screenshots,
/// photos, PDFs, documents, notes, recordings, videos, code last — newest
/// first. Low Power Mode pauses the backfill. How far each file got is
/// `files.vec_state` and `vec_to`, so a restart carries on.
///
/// Off until `enable()`: the switch in Settings is on and the model files
/// are there (`MeaningSettings`).
nonisolated final class MeaningScheduler: @unchecked Sendable {
    typealias Embed = @Sendable ([MeaningJob]) async throws -> [MeaningResult]

    /// Files embedded per batch: pictures and text go eight at a time; a PDF,
    /// a recording or a video alone (`MeaningJob.isHeavy`).
    static let batchSize = 8
    /// The changed files embedded ahead of the backfill from one burst.
    static let burstCap = FileContentScheduler.burstCap

    /// Each job read in turn with `embedder`, `cache` first.
    static func embedAll(with embedder: some MeaningEmbedder, cache: VectorCache) -> Embed {
        { jobs in
            var results: [MeaningResult] = []
            for job in jobs { results.append(try await MeaningReader.read(job, with: embedder, cache: cache)) }
            return results
        }
    }

    private let writer: FileIndexWriter
    private let vectors: MeaningVectors
    private let cache: VectorCache
    private let queue: DispatchQueue
    private let embed: Embed
    private let onProgress: (FileIndexer.Progress) -> Void

    private var changed: [Int64] = []
    private var sources: [String] = []
    private var isLowPower = false
    private var isBusy = false
    private(set) var isEnabled = false
    /// The helper could not start, or kept crashing: no more batches until
    /// the next `enable()`.
    private var isFailed = false
    /// Bumped by `disable()`, so a batch that was out when the switch went
    /// off stores nothing.
    private var generation = 0

    /// - Parameters:
    ///   - cache: where the vectors the database points to are kept.
    ///   - queue: the writer's. Every method is called on it.
    ///   - embed: the embedding itself; tests pass their own.
    init(
        writer: FileIndexWriter,
        vectors: MeaningVectors,
        cache: VectorCache,
        queue: DispatchQueue,
        embed: @escaping Embed,
        onProgress: @escaping (FileIndexer.Progress) -> Void = { _ in }
    ) {
        self.writer = writer
        self.vectors = vectors
        self.cache = cache
        self.queue = queue
        self.embed = embed
        self.onProgress = onProgress
    }

    // The setters only change what the next batch is; the caller then calls
    // `resume()`, or a test `readBatch()`.

    func setSources(_ roots: [String]) {
        sources = roots
    }

    func filesChanged(_ ids: [Int64]) {
        var seen = Set<Int64>()
        changed = Array((changed + ids).reversed().filter { seen.insert($0).inserted }.reversed().suffix(Self.burstCap))
    }

    func setLowPower(_ isLowPower: Bool) {
        self.isLowPower = isLowPower
    }

    /// Starts embedding: the database's vectors under `MeaningPass.fingerprint`
    /// and in this `cache` (any others are dropped), and the vector files
    /// opened, or rebuilt from the cache when they do not match the database.
    func enable() throws {
        let isNewFingerprint = try writer.adoptMeaningFingerprint()
        let isNewCache = try writer.adoptVectorCache(cache.id)
        if try isNewFingerprint || isNewCache || !vectors.open(expectedRows: writer.vectorRows()) {
            try writer.rebuild(vectors, from: cache)
        }
        isEnabled = true
        isFailed = false
    }

    /// Stops embedding and gives back the vectors' memory. What is on disk
    /// stays for the next `enable()`.
    func disable() {
        isEnabled = false
        generation += 1
        changed = []
        vectors.close()
    }

    /// The next files to embed: changed ones first, then the backfill unless
    /// Low Power Mode is on. Empty when there is nothing to do now.
    func nextBatch() throws -> [MeaningJob] {
        guard isEnabled, !isFailed else { return [] }
        if !changed.isEmpty {
            let (jobs, waiting) = try writer.meaningJobs(ids: changed)
            let batch = Self.batch(from: jobs)
            changed = jobs.dropFirst(batch.count).map(\.id) + waiting
            if !batch.isEmpty { return batch }
        }
        guard !isLowPower, !sources.isEmpty else { return [] }
        return Self.batch(from: try writer.meaningJobs(limit: Self.batchSize, sources: sources))
    }

    /// A heavy job alone, or the light ones from the front.
    static func batch(from jobs: [MeaningJob]) -> [MeaningJob] {
        guard let first = jobs.first else { return [] }
        if first.isHeavy { return [first] }
        return Array(jobs.prefix { !$0.isHeavy }.prefix(batchSize))
    }

    /// Stores a batch's vectors in one transaction, then hands them to the
    /// vector files. A file that changed while it was embedded is left for
    /// its next turn.
    func store(_ results: [MeaningResult]) throws {
        guard !results.isEmpty else { return }
        var rows: [(row: MeaningVectors.Row, vector: Data)] = []
        try writer.db.transaction {
            for result in results {
                rows += try writer.storeMeaning(result) ?? []
            }
        }
        do {
            try vectors.append(rows)
        } catch {
            // The files no longer match the database: write them again.
            try writer.rebuild(vectors, from: cache)
        }
        if vectors.needsCompaction { try writer.rebuild(vectors, from: cache) }
        onProgress(.wrote)
    }

    /// One batch, start to finish, on the caller's thread: what `resume`
    /// does across two queues. For tests and measurements.
    @discardableResult
    func readBatch() async throws -> Int {
        let jobs = try nextBatch()
        guard !jobs.isEmpty else { return 0 }
        try store(try await embed(jobs))
        return jobs.count
    }

    /// Starts the next batch unless one is out. Its results come back to the
    /// queue, and the one after starts from there.
    func resume() {
        guard !isBusy, isEnabled, !isFailed else { return }
        let jobs: [MeaningJob]
        do {
            jobs = try nextBatch()
        } catch {
            NSLog("File Index meaning: %@", String(describing: error))
            return
        }
        guard !jobs.isEmpty else { return }
        isBusy = true
        let embed = self.embed
        let generation = self.generation
        Task.detached(priority: .background) { [self] in
            let outcome: Result<[MeaningResult], Error>
            do { outcome = .success(try await embed(jobs)) } catch { outcome = .failure(error) }
            queue.async { [self] in
                isBusy = false
                guard generation == self.generation else { return }
                do {
                    try store(try outcome.get())
                    resume()
                } catch {
                    // The helper would not start or kept crashing, or the
                    // database refused: not again until the switch is thrown
                    // again, or the next launch.
                    NSLog("File Index meaning: %@", String(describing: error))
                    isFailed = true
                }
            }
        }
    }
}
