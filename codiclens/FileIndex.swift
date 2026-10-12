import Foundation
import Synchronization

/// The File Index — see `CONTEXT.md`. Names only for now: what the files in
/// the folder Sources are called and where they are, on disk in
/// `FileIndex.sqlite`, kept current by FSEvents. File Results and Finder's
/// Target list read it through `search(_:limit:)`.
///
/// Two halves that share nothing but the database. The writing half —
/// `FileIndexer`, `FileIndexWatcher` and the writer connection — lives on
/// one serial queue. The reading half is `FileIndexReader`, on its own
/// connection, safe from any thread and fast enough for the keystroke path.
/// The writing half is meant to move into a helper process once file contents
/// are read too, and nothing on the reading side may come to depend on it
/// being here.
@Observable
final class FileIndex {
    static let shared = FileIndex(databaseURL: FileIndex.defaultDatabaseURL, sources: .shared)

    /// `~/Library/Application Support/codiclens/FileIndex.sqlite`.
    static var defaultDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("codiclens")
            .appendingPathComponent("FileIndex.sqlite")
    }

    let sources: SourceStore

    /// How much of each folder Source is in the index, keyed by its path in
    /// `SourceStore`. A file's name is indexed the moment the crawl finds it,
    /// so until contents are read the two numbers are the same; the Settings
    /// page shows them moving, and `readingFolders` says a crawl is still on.
    private(set) var counts: [String: SourceCounts] = [:]

    /// Folder Sources being crawled right now, by their path in `SourceStore`.
    private(set) var readingFolders: Set<String> = []

    /// Bumped whenever rows land. A search showing results can ignore it —
    /// ADR 0004's rule that rows do not reshuffle under the user holds here
    /// too — and pick up the change on the next keystroke.
    private(set) var generation = 0

    @ObservationIgnored nonisolated private let reader: FileIndexReader
    /// The enabled folder Sources as real paths: the only thing `search`
    /// needs from the main actor, kept where any thread can read it.
    @ObservationIgnored nonisolated private let searchableFolders = Mutex<[String]>([])
    @ObservationIgnored nonisolated private let countsRefreshPending = Mutex(false)
    @ObservationIgnored private let worker: Worker
    /// Whether `start()` has run. The unit-test host never calls it.
    @ObservationIgnored private(set) var isStarted = false

    init(databaseURL: URL, sources: SourceStore) {
        self.sources = sources
        self.reader = FileIndexReader(url: databaseURL)
        self.worker = Worker(databaseURL: databaseURL)
    }

    /// Opens the index and starts watching, off the main thread. What changed
    /// while the app was not running arrives as an FSEvents replay; only a
    /// folder Source the replay cannot vouch for is crawled
    /// (`FileIndexer.setSources`). Only the first call does anything.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        sources.onFoldersChange = { [weak self] in self?.sourcesChanged() }
        sources.onRulesChange = { [weak self] in self?.sourcesChanged() }
        worker.onProgress = { [weak self] progress in self?.received(progress) }
        sourcesChanged()
    }

    /// Stops watching. Called from `applicationWillTerminate`, for the same
    /// reason as `AppIndex.stop()`: a singleton never deinitialises.
    func stop() {
        worker.stop()
    }

    // MARK: - Reading

    /// Files in the enabled folder Sources whose name — or, ranked below,
    /// folder — has every word of `query`, the last as a prefix. Best first,
    /// scored on `fuzzyScore`'s scale. Synchronous, from any thread.
    nonisolated func search(_ query: String, limit: Int = 50) -> [FileHit] {
        reader.search(query, limit: limit, sources: searchableFolders.withLock { $0 })
    }

    /// `search(_:limit:)` as a value: what Subject search and Finder's Target
    /// list are handed, so a test can hand them something else.
    typealias Search = @Sendable (_ query: String) -> [FileHit]

    var searcher: Search {
        { [self] query in search(query) }
    }

    /// The indexed file at exactly `path`, in any Source.
    nonisolated func file(atPath path: String) -> FileHit? {
        reader.file(atPath: FileIndexer.realPath(path))
    }

    // MARK: - Sources

    private func sourcesChanged() {
        let folders = sources.folders.compactMap { source in
            source.folderPath.map { (path: $0, isEnabled: source.isEnabled) }
        }
        searchableFolders.withLock { searchable in
            searchable = folders.filter(\.isEnabled).map { FileIndexer.realPath($0.path) }
        }
        worker.apply(folders, rules: sources.fileIndexRules)
        refreshCounts()
    }

    nonisolated private func received(_ progress: FileIndexer.Progress) {
        switch progress {
        case .reading(let source, let isReading):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let paths = sources.folders.compactMap(\.folderPath).filter { FileIndexer.realPath($0) == source }
                for path in paths {
                    if isReading { readingFolders.insert(path) } else { readingFolders.remove(path) }
                }
            }
        case .wrote:
            refreshCounts()
        }
    }

    /// Reads the counts again, off the main thread. Writes arrive every few
    /// hundred rows during a crawl; one read in flight absorbs all of them.
    nonisolated private func refreshCounts() {
        let alreadyPending = countsRefreshPending.withLock { pending in
            defer { pending = true }
            return pending
        }
        guard !alreadyPending else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            countsRefreshPending.withLock { $0 = false }
            let raw = reader.counts()
            DispatchQueue.main.async { [weak self] in self?.adopt(raw) }
        }
    }

    private func adopt(_ raw: [String: Int]) {
        var counts: [String: SourceCounts] = [:]
        for source in sources.folders {
            guard let path = source.folderPath else { continue }
            let rows = raw[FileIndexer.realPath(path)] ?? 0
            counts[path] = SourceCounts(indexed: rows, total: rows)
        }
        self.counts = counts
        generation &+= 1
    }
}

// MARK: - The writing half

extension FileIndex {
    /// Owns the writer connection, the indexer and the watcher, and touches
    /// them only on `queue`.
    nonisolated private final class Worker: @unchecked Sendable {
        let queue = DispatchQueue(label: "com.codiclens.file-index", qos: .utility)
        var onProgress: (@Sendable (FileIndexer.Progress) -> Void)?

        private let databaseURL: URL
        private var indexer: FileIndexer?
        private var watcher: FileIndexWatcher?

        init(databaseURL: URL) {
            self.databaseURL = databaseURL
        }

        /// Brings the index in line with the folder Sources and the skip
        /// rules, crawling whatever either asks for.
        func apply(_ folders: [(path: String, isEnabled: Bool)], rules: FileIndexRules) {
            queue.async { [self] in
                do {
                    let indexer = try openIndexer(rules: rules)
                    let toCrawl = try indexer.setSources(folders)
                    let recrawl = try indexer.setRules(rules)
                    watch(indexer.watchedPaths, indexer: indexer)
                    for root in toCrawl + recrawl.filter({ !toCrawl.contains($0) }) {
                        try indexer.crawl(root)
                    }
                } catch {
                    NSLog("File Index: %@", String(describing: error))
                }
            }
        }

        func stop() {
            queue.async { [self] in
                watcher?.stop()
                watcher = nil
                watchedPaths = []
            }
        }

        private func openIndexer(rules: FileIndexRules) throws -> FileIndexer {
            if let indexer { return indexer }
            let indexer = FileIndexer(
                writer: try FileIndexWriter(url: databaseURL),
                rules: rules,
                onProgress: { [weak self] progress in self?.onProgress?(progress) }
            )
            self.indexer = indexer
            return indexer
        }

        /// (Re)starts the stream when the watched folders change. The first
        /// one starts where the index was left, so FSEvents replays what
        /// changed while the app was not running; a new one picks up from the
        /// old one's last event, so a folder watched by both loses nothing in
        /// between.
        private func watch(_ paths: [String], indexer: FileIndexer) {
            guard paths != watchedPaths else { return }
            let since = watcher?.latestEventID ?? indexer.eventID
            watcher?.stop()
            watchedPaths = paths
            watcher = FileIndexWatcher(paths: paths, since: since, queue: queue) { events in
                do {
                    try indexer.handle(events)
                } catch {
                    NSLog("File Index: %@", String(describing: error))
                }
            }
        }

        private var watchedPaths: [String] = []
    }
}
