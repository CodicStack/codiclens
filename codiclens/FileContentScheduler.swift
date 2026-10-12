import Foundation

/// The background pass that reads what files say, once their names are in.
///
/// Lives on the File Index's queue beside the writer, and reads off it: a
/// batch of `FileContentJob`s goes to `FileContentReader` at background QoS
/// and the results come back to the queue to be stored, so neither a crawl
/// nor an FSEvents batch ever waits on a PDF. One batch at a time.
///
/// Files that changed while the app runs (FSEvents) are read first, in any
/// power state, the newest `burstCap` of a burst. The backfill — every file
/// still unread, in `FileContent`'s order, newest first, then the later steps
/// of long ones — pauses in Low Power Mode. Which files are read, and how far,
/// is `files.state` and `read_to` in the database, so a restart carries on
/// where the last run stopped.
nonisolated final class FileContentScheduler: @unchecked Sendable {
    typealias Read = @Sendable ([FileContentJob]) async -> [FileContentResult]

    /// Files read per batch: small, so an OCR'd screenshot or a long PDF
    /// holds up little behind it.
    static let batchSize = 8
    /// The changed files read ahead of the backfill from one burst. An unzip
    /// of ten thousand files is a backfill, not news.
    static let burstCap = 50

    static let readAll: Read = { jobs in
        var results: [FileContentResult] = []
        for job in jobs { results.append(await FileContentReader.read(job)) }
        return results
    }

    private let writer: FileIndexWriter
    private let queue: DispatchQueue
    private let read: Read
    private let onProgress: (FileIndexer.Progress) -> Void

    private var changed: [Int64] = []
    private var sources: [String] = []
    private var isLowPower = false
    private var isBusy = false
    private var isStopped = false
    private var isBackfilling = false

    /// - Parameters:
    ///   - queue: the writer's. Every method is called on it, and results are
    ///     stored on it.
    ///   - read: the reading itself; tests pass their own.
    init(
        writer: FileIndexWriter,
        queue: DispatchQueue,
        read: @escaping Read = FileContentScheduler.readAll,
        onProgress: @escaping (FileIndexer.Progress) -> Void = { _ in }
    ) {
        self.writer = writer
        self.queue = queue
        self.read = read
        self.onProgress = onProgress
    }

    // The setters only change what the next batch is; the caller then calls
    // `resume()`, or a test `readBatch()`.

    /// The enabled folder Sources, as real paths: the backfill reads only
    /// these.
    func setSources(_ roots: [String]) {
        sources = roots
    }

    /// Files a batch of FSEvents added or changed: read before the backfill.
    func filesChanged(_ ids: [Int64]) {
        changed = Array((changed + ids).suffix(Self.burstCap))
    }

    func setLowPower(_ isLowPower: Bool) {
        self.isLowPower = isLowPower
    }

    func stop() {
        isStopped = true
        setBackfilling(false)
    }

    /// The next files to read: changed ones first, then the backfill unless
    /// Low Power Mode is on. Empty when there is nothing to do now.
    func nextBatch() throws -> [FileContentJob] {
        while !changed.isEmpty {
            let ids = Array(changed.prefix(Self.batchSize))
            changed.removeFirst(ids.count)
            let jobs = try writer.contentJobs(ids: ids)
            if !jobs.isEmpty { return jobs }
        }
        guard !isLowPower, !sources.isEmpty else {
            setBackfilling(false)
            return []
        }
        let jobs = try writer.contentJobs(limit: Self.batchSize, sources: sources)
        setBackfilling(!jobs.isEmpty)
        return jobs
    }

    /// Stores a batch's results in one transaction. A file that changed while
    /// it was read is left for its next turn.
    func store(_ results: [FileContentResult]) throws {
        guard !results.isEmpty else { return }
        try writer.db.transaction {
            for result in results { try writer.storeContents(result) }
        }
        onProgress(.wrote)
    }

    /// One batch, start to finish, on the caller's thread: what `resume`
    /// does across two queues. For tests and measurements.
    @discardableResult
    func readBatch() async throws -> Int {
        let jobs = try nextBatch()
        try store(await read(jobs))
        return jobs.count
    }

    /// Starts the next batch unless one is out. Its results come back to the
    /// queue, and the one after starts from there: the pass drives itself,
    /// with nothing timed.
    func resume() {
        guard !isBusy, !isStopped else { return }
        let jobs: [FileContentJob]
        do {
            jobs = try nextBatch()
        } catch {
            NSLog("File Index: %@", String(describing: error))
            return
        }
        guard !jobs.isEmpty else { return }
        isBusy = true
        let read = self.read
        Task.detached(priority: .background) { [self] in
            let results = await read(jobs)
            queue.async { [self] in
                isBusy = false
                do {
                    try store(results)
                    resume()
                } catch {
                    // Not again straight away: the same files would fail the
                    // same way. The next change, switch or power state does.
                    NSLog("File Index: %@", String(describing: error))
                }
            }
        }
    }

    /// Changed files read between backfill batches leave the Sources page's
    /// "Reading" as it was; only the backfill turns it on or off.
    private func setBackfilling(_ isBackfilling: Bool) {
        guard isBackfilling != self.isBackfilling else { return }
        self.isBackfilling = isBackfilling
        onProgress(.readingContents(isReading: isBackfilling))
    }
}
