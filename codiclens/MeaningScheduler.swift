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
/// first. How far each file got is `files.vec_state` and `vec_to`, so a
/// restart carries on.
///
/// Pace (`MeaningPace`), decided as each batch starts: full speed on power
/// with the user away and the Panel closed, gentle otherwise, and Low Power
/// Mode pauses the backfill.
///
/// Off until `enable()`: the switch in Settings is on and the model files
/// are there (`MeaningSettings`).
nonisolated final class MeaningScheduler: @unchecked Sendable {
    typealias Embed = @Sendable ([MeaningJob], MeaningPace) async throws -> [MeaningResult]

    /// The changed files embedded ahead of the backfill from one burst.
    static let burstCap = FileContentScheduler.burstCap

    /// The batch's texts together, then each job in turn, with `embedder`
    /// at `pace`, `cache` first.
    static func embedAll(with embedder: some MeaningEmbedder, cache: VectorCache) -> Embed {
        { jobs, pace in
            await embedder.setFullSpeed(pace == .full)
            return try await MeaningReader.read(jobs, with: embedder, cache: cache)
        }
    }

    private let writer: FileIndexWriter
    private let vectors: MeaningVectors
    private let cache: VectorCache
    private let queue: DispatchQueue
    private let embed: Embed
    private let machine: MeaningPace.Machine
    private let onProgress: (FileIndexer.Progress) -> Void

    private var changed: [Int64] = []
    private var sources: [String] = []
    private var isLowPower = false
    private var isPanelOpen = false
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
    ///   - machine: the power source and the user's idle time, read as each
    ///     batch starts; `.system` in the app, a test's own in tests.
    init(
        writer: FileIndexWriter,
        vectors: MeaningVectors,
        cache: VectorCache,
        queue: DispatchQueue,
        embed: @escaping Embed,
        machine: MeaningPace.Machine,
        onProgress: @escaping (FileIndexer.Progress) -> Void = { _ in }
    ) {
        self.writer = writer
        self.vectors = vectors
        self.cache = cache
        self.queue = queue
        self.embed = embed
        self.machine = machine
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

    /// The Panel is open: the backfill goes gently until it closes.
    func setPanelOpen(_ isPanelOpen: Bool) {
        self.isPanelOpen = isPanelOpen
    }

    /// The pace for the next batch, decided now.
    var pace: MeaningPace {
        MeaningPace(isLowPower: isLowPower, isPanelOpen: isPanelOpen, machine: machine)
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

    /// The next files to embed at `pace`: changed ones first, then the
    /// backfill unless it is paused. Empty when there is nothing to do now.
    func nextBatch(_ pace: MeaningPace) throws -> [MeaningJob] {
        guard isEnabled, !isFailed else { return [] }
        if !changed.isEmpty {
            let (jobs, waiting) = try writer.meaningJobs(ids: changed)
            let batch = Self.batch(from: jobs, size: pace.batchSize)
            changed = jobs.dropFirst(batch.count).map(\.id) + waiting
            if !batch.isEmpty { return batch }
        }
        guard pace != .paused, !sources.isEmpty else { return [] }
        return Self.batch(from: try writer.meaningJobs(limit: pace.batchSize, sources: sources), size: pace.batchSize)
    }

    /// `nextBatch(_:)` at the pace in force now.
    func nextBatch() throws -> [MeaningJob] {
        try nextBatch(pace)
    }

    /// A heavy job alone (`MeaningJob.isHeavy`: a PDF, a recording or a
    /// video), or up to `size` light ones from the front.
    static func batch(from jobs: [MeaningJob], size: Int) -> [MeaningJob] {
        guard let first = jobs.first else { return [] }
        if first.isHeavy { return [first] }
        return Array(jobs.prefix { !$0.isHeavy }.prefix(size))
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
        let pace = self.pace
        let jobs = try nextBatch(pace)
        guard !jobs.isEmpty else { return 0 }
        try store(try await embed(jobs, pace))
        return jobs.count
    }

    /// Starts the next batch unless one is out, at the pace decided now. Its
    /// results come back to the queue, and the one after starts from there.
    func resume() {
        guard !isBusy, isEnabled, !isFailed else { return }
        let pace = self.pace
        let jobs: [MeaningJob]
        do {
            jobs = try nextBatch(pace)
        } catch {
            NSLog("File Index meaning: %@", String(describing: error))
            return
        }
        guard !jobs.isEmpty else { return }
        isBusy = true
        let embed = self.embed
        let generation = self.generation
        // At full speed App Nap stays off this process while the batch is
        // out; the helper does the same for its requests. Idle sleep and the
        // display's are left to the system.
        let activity = pace == .full ? ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Search by meaning is catching up while the Mac is idle"
        ) : nil
        Task.detached(priority: pace == .full ? .utility : .background) { [self] in
            let outcome: Result<[MeaningResult], Error>
            do { outcome = .success(try await embed(jobs, pace)) } catch { outcome = .failure(error) }
            queue.async { [self] in
                if let activity { ProcessInfo.processInfo.endActivity(activity) }
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
