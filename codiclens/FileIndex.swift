import Foundation
import Synchronization

/// The File Index — see `GLOSSARY.md`. What the files in the folder Sources
/// are called, where they are, what the ones with words in them say, and —
/// with search by meaning on — what every one of them says, shows or sounds
/// like as vectors, on disk in `FileIndex.sqlite` (and `FileIndex.vectors`,
/// built from `VectorCache.sqlite`, which outlives the index), kept current
/// by FSEvents. File Results and Finder's Target list read it
/// through `search(_:limit:)` on the keystroke; the list below the apps asks
/// `searchSettled(_:limit:)` once typing pauses, where meaning joins.
///
/// Two halves that share nothing but the database. The writing half —
/// `FileIndexer`, `FileIndexWatcher`, `FileContentScheduler`,
/// `MeaningScheduler` and the writer connection — lives on one serial queue,
/// and reads contents and asks for vectors off it. The reading half is
/// `FileIndexReader`, on connections of its own, safe from any thread and fast
/// enough for the keystroke path. The writing half is meant to move into a
/// helper process, and nothing on the reading side may come to depend on it
/// being here.
@Observable
final class FileIndex {
    static let shared: FileIndex = {
        let files = ModelFiles()
        return FileIndex(
            databaseURL: FileIndex.defaultDatabaseURL,
            sources: .shared,
            meaning: MeaningSettings(files: files, choice: .defaults(.standard, files: files)),
            prune: NSBackgroundActivityScheduler.vectorCachePrune()
        )
    }()

    /// `~/Library/Application Support/codiclens/FileIndex.sqlite`.
    static var defaultDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("codiclens")
            .appendingPathComponent("FileIndex.sqlite")
    }

    let sources: SourceStore
    /// Search by meaning's choice and status, for the Sources page and Setup.
    let meaning: MeaningSettings

    /// How much of each folder Source is in the index, keyed by its path in
    /// `SourceStore`: every file the crawl found, and how many of those have
    /// had their contents read (or have none to read). The Settings page shows
    /// them moving, and `readingFolders` says the work is still on.
    private(set) var counts: [String: SourceCounts] = [:]

    /// Folder Sources being read right now, by their path in `SourceStore`:
    /// crawled, or — while the contents backfill runs — with contents still
    /// unread.
    var readingFolders: Set<String> {
        guard isReadingContents else { return crawlingFolders }
        return crawlingFolders.union(counts.filter { $0.value.indexed < $0.value.total }.keys)
    }

    private var crawlingFolders: Set<String> = []
    private var isReadingContents = false

    /// Folder Sources macOS refused when the crawl came to them, by their
    /// path in `SourceStore`. Nothing in them is read until it lets go
    /// (`recheckAccess`).
    private(set) var deniedFolders: Set<String> = []

    /// Whether macOS refused the folder Source at `path`: what Setup's
    /// Folders row and the Sources page ask.
    func isDenied(_ path: String) -> Bool {
        deniedFolders.contains(path)
    }

    /// How far the meaning pass has got in the enabled folder Sources, and
    /// how many vectors a search scores.
    private(set) var meaningCounts = MeaningCounts()
    private(set) var isLowPower = false

    /// Bumped whenever rows land. A search showing results can ignore it —
    /// ADR 0004's rule that rows do not reshuffle under the user holds here
    /// too — and pick up the change on the next keystroke.
    private(set) var generation = 0

    @ObservationIgnored nonisolated private let reader: FileIndexReader
    /// The settled pass's own connection: its prefix and fusion queries can
    /// take tens of milliseconds, and the keystroke's search must not wait
    /// behind them on one lock.
    @ObservationIgnored nonisolated private let settledReader: FileIndexReader
    @ObservationIgnored nonisolated private let vectors: MeaningVectors
    /// The query encoder: the text model alone in a helper of its own,
    /// held while the Panel is open (`holdQueryEncoder`).
    @ObservationIgnored nonisolated private let queryEncoder: any QueryEncoder
    @ObservationIgnored nonisolated private let isMeaningApplied = Mutex(false)
    @ObservationIgnored nonisolated private let settledGeneration = Mutex(0)
    /// The enabled folder Sources as real paths: the only thing `search`
    /// needs from the main actor, kept where any thread can read it.
    @ObservationIgnored nonisolated private let searchableFolders = Mutex<[String]>([])
    @ObservationIgnored nonisolated private let countsRefreshPending = Mutex(false)
    @ObservationIgnored private let worker: Worker
    @ObservationIgnored private let prune: (any BackgroundSchedule)?
    @ObservationIgnored private var powerObserver: NSObjectProtocol?
    /// Whether `start()` has run. The unit-test host never calls it.
    @ObservationIgnored private(set) var isStarted = false

    /// - Parameters:
    ///   - meaning: search by meaning's choice. A test's is off unless it
    ///     hands in one that is not; nothing downloads or embeds without it.
    ///   - indexEmbedder, textIndexEmbedder, queryEncoder: the helpers that
    ///     index with the encoders and without them (the Text choice), and
    ///     the query encoder; tests pass their own.
    ///   - prune: what runs the vector cache's daily prune from `start()`.
    ///     None unless handed one: the app's is the system's scheduler.
    init(
        databaseURL: URL,
        sources: SourceStore,
        meaning: MeaningSettings = MeaningSettings(files: ModelFiles(), choice: .off),
        indexEmbedder: any MeaningEmbedder & EmbeddingShutdown = EmbeddingClient.helper(.indexing, idleExit: 60),
        textIndexEmbedder: any MeaningEmbedder & EmbeddingShutdown = EmbeddingClient.helper(.textIndexing, idleExit: 60),
        queryEncoder: any QueryEncoder = EmbeddingClient.helper(.queries, idleExit: 60),
        prune: (any BackgroundSchedule)? = nil
    ) {
        self.sources = sources
        self.meaning = meaning
        self.prune = prune
        self.reader = FileIndexReader(url: databaseURL)
        self.settledReader = FileIndexReader(url: databaseURL)
        self.vectors = MeaningVectors(databaseURL: databaseURL)
        self.queryEncoder = queryEncoder
        self.worker = Worker(databaseURL: databaseURL, vectors: vectors, embedder: indexEmbedder,
                             textOnlyEmbedder: textIndexEmbedder)
        meaning.apply = { [weak self] mode in self?.applyMeaning(mode) }
        meaning.removeVectors = { [weak self] in self?.worker.removeMeaning() }
        meaning.progress = { [weak self] in
            MeaningSettings.Progress(counts: self?.meaningCounts ?? MeaningCounts(), isLowPower: self?.isLowPower ?? false)
        }
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
        // Low Power Mode pauses both backfills; files that change are read
        // regardless. The meaning pass reads the power source and the user's
        // idle time itself, as each batch starts (`MeaningPace`).
        powerChanged()
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.powerChanged() }
        }
        sourcesChanged()
        meaning.start()
        // After `sourcesChanged()`, so its first run finds the Sources
        // applied, on the same queue.
        let worker = self.worker
        prune?.schedule { completion in worker.pruneVectorCache(completion) }
    }

    private func powerChanged() {
        isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        worker.setLowPower(isLowPower)
    }

    /// Stops watching. Called from `applicationWillTerminate`, for the same
    /// reason as `AppIndex.stop()`: a singleton never deinitialises.
    func stop() {
        prune?.invalidate()
        worker.stop()
    }

    // MARK: - Reading

    /// Files in the enabled folder Sources whose name, words or — ranked
    /// below both — folder have every word of `query`, the last as a prefix.
    /// Best first, scored on `fuzzyScore`'s scale; a file found by its words
    /// carries the Passage. Synchronous, from any thread.
    nonisolated func search(_ query: String, limit: Int = 50) -> [FileHit] {
        reader.search(query, limit: limit, sources: searchableFolders.withLock { $0 })
    }

    /// `search(_:limit:)` as a value: what Subject search and Finder's Target
    /// list are handed, so a test can hand them something else.
    typealias Search = @Sendable (_ query: String) -> [FileHit]

    var searcher: Search {
        { [self] query in search(query) }
    }

    /// The settled pass's search, once typing pauses: the word search with
    /// the last word a prefix in Passages too, and — with search by meaning
    /// on and vectors to score — meaning fused in (`FileIndexReader.fusedSearch`,
    /// which documents where it lands on `fuzzyScore`'s scale). Without
    /// meaning it is the word search, with the Kind a Kind Word asks for
    /// first.
    ///
    /// Cancellable: a cancelled Task, or a newer call that started while
    /// this one waited for its Query's vector, makes it return `[]` at the
    /// next step, and the newer Query wins. The Query's vector comes from the
    /// warm query encoder in ~5 ms (`holdQueryEncoder`); scoring every vector
    /// and fusing is measured in `MeaningTimingTests`.
    nonisolated func searchSettled(_ query: String, limit: Int = 50) async -> [FileHit] {
        let folders = searchableFolders.withLock { $0 }
        let generation = settledGeneration.withLock { generation in
            generation += 1
            return generation
        }
        func isStale() -> Bool {
            Task.isCancelled || settledGeneration.withLock { $0 } != generation
        }
        guard isMeaningApplied.withLock({ $0 }), !query.trimmingCharacters(in: .whitespaces).isEmpty,
              vectors.snapshot() != nil,
              let vector = try? await queryEncoder.embedQuery(query, code: false)
        else {
            return isStale() ? [] : settledReader.fusedSearch(query, limit: limit, sources: folders, meaning: nil)
        }
        guard !isStale() else { return [] }
        // Taken after the wait, so vectors that landed meanwhile count.
        guard let snapshot = vectors.snapshot() else {
            return settledReader.fusedSearch(query, limit: limit, sources: folders, meaning: nil)
        }
        let scores = MeaningScores(snapshot, query: vector)
        guard !isStale() else { return [] }
        return settledReader.fusedSearch(query, limit: limit, sources: folders, meaning: scores)
    }

    /// `searchSettled(_:limit:)` as a value, for the settled pass of the
    /// list below the apps.
    typealias SettledSearch = @Sendable (_ query: String) async -> [FileHit]

    var settledSearcher: SettledSearch {
        { [self] query in await searchSettled(query) }
    }

    /// The Panel opened: load the query encoder now, before the first
    /// keystroke, and keep it while the Panel stays open, and the meaning
    /// backfill goes gently meanwhile (`MeaningPace`). Nothing more without
    /// search by meaning on.
    nonisolated func holdQueryEncoder() {
        worker.setPanelOpen(true)
        guard isMeaningApplied.withLock({ $0 }) else { return }
        let encoder = queryEncoder
        Task { try? await encoder.hold() }
    }

    /// The Panel closed: the query encoder may go after its idle exit.
    /// Nothing without search by meaning on: turning it off has already
    /// told the encoder to go.
    nonisolated func releaseQueryEncoder() {
        worker.setPanelOpen(false)
        guard isMeaningApplied.withLock({ $0 }) else { return }
        let encoder = queryEncoder
        Task { await encoder.release() }
    }

    /// The indexed file at exactly `path`, in any Source.
    nonisolated func file(atPath path: String) -> FileHit? {
        reader.file(atPath: FileIndexer.realPath(path))
    }

    // MARK: - Sources

    /// Crawls again each folder Source macOS refused, if it now lets it be
    /// read: the user may have turned Codiclens on in Privacy & Security.
    /// One that is still refused stays as it is, without asking macOS again.
    /// The app calls it whenever it comes to the front.
    func recheckAccess() {
        let denied = sources.folders.filter { source in
            source.isEnabled && source.folderPath.map(deniedFolders.contains) == true
        }
        guard !denied.isEmpty else { return }
        worker.recrawl(denied.compactMap(\.folderPath).map(FileIndexer.realPath))
    }

    // MARK: - Search by meaning

    private func applyMeaning(_ mode: MeaningMode) {
        isMeaningApplied.withLock { $0 = mode != .off }
        worker.setMeaning(mode)
        if mode == .off {
            let encoder = queryEncoder
            Task { await encoder.shutdown() }
            meaningCounts = MeaningCounts()
        }
        refreshCounts()
    }

    private func sourcesChanged() {
        let folders = sources.folders.compactMap { source in
            source.folderPath.map { (path: $0, isEnabled: source.isEnabled) }
        }
        searchableFolders.withLock { searchable in
            searchable = folders.filter(\.isEnabled).map { FileIndexer.realPath($0.path) }
        }
        deniedFolders.formIntersection(folders.map(\.path))
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
                    if isReading { crawlingFolders.insert(path) } else { crawlingFolders.remove(path) }
                }
            }
        case .readingContents(let isReading):
            DispatchQueue.main.async { [weak self] in self?.isReadingContents = isReading }
        case .access(let source, let isDenied):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let paths = sources.folders.compactMap(\.folderPath).filter { FileIndexer.realPath($0) == source }
                for path in paths where deniedFolders.contains(path) != isDenied {
                    if isDenied { deniedFolders.insert(path) } else { deniedFolders.remove(path) }
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
            var meaning = MeaningCounts()
            if isMeaningApplied.withLock({ $0 }) {
                meaning = reader.meaningCounts(sources: searchableFolders.withLock { $0 })
                meaning.vectors = vectors.liveCount
            }
            DispatchQueue.main.async { [weak self] in
                self?.adopt(raw)
                if self?.isMeaningApplied.withLock({ $0 }) == true { self?.meaningCounts = meaning }
            }
        }
    }

    private func adopt(_ raw: [String: SourceCounts]) {
        var counts: [String: SourceCounts] = [:]
        for source in sources.folders {
            guard let path = source.folderPath else { continue }
            counts[path] = raw[FileIndexer.realPath(path)] ?? SourceCounts(indexed: 0, total: 0)
        }
        self.counts = counts
        generation &+= 1
    }
}

// MARK: - The writing half

extension FileIndex {
    /// Owns the writer connection, the indexer, the watcher and the contents
    /// and meaning passes, and touches them only on `queue`.
    nonisolated private final class Worker: @unchecked Sendable {
        let queue = DispatchQueue(label: "com.codiclens.file-index", qos: .utility)
        var onProgress: (@Sendable (FileIndexer.Progress) -> Void)?

        private let databaseURL: URL
        private let vectors: MeaningVectors
        private let embedder: any MeaningEmbedder & EmbeddingShutdown
        private let textOnlyEmbedder: any MeaningEmbedder & EmbeddingShutdown
        private var indexer: FileIndexer?
        private var contents: FileContentScheduler?
        private var meaning: MeaningScheduler?
        private var watcher: FileIndexWatcher?
        private var isLowPower = false
        private var isPanelOpen = false
        private var writer: FileIndexWriter?
        private var cache: VectorCache?
        private var meaningMode = MeaningMode.off
        /// Already noted this session that the vector files are behind.
        private var isVectorFileStale = false

        init(
            databaseURL: URL, vectors: MeaningVectors, embedder: any MeaningEmbedder & EmbeddingShutdown,
            textOnlyEmbedder: any MeaningEmbedder & EmbeddingShutdown
        ) {
            self.databaseURL = databaseURL
            self.vectors = vectors
            self.embedder = embedder
            self.textOnlyEmbedder = textOnlyEmbedder
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
                    // Contents once the names are in, and vectors for what
                    // there is to see and hear.
                    contents?.setSources(indexer.watchedPaths)
                    contents?.resume()
                    meaning?.setSources(indexer.watchedPaths)
                    meaning?.resume()
                } catch {
                    NSLog("File Index: %@", String(describing: error))
                }
            }
        }

        /// Crawls `roots` again, if they are still Sources, and reads what
        /// the crawl found.
        func recrawl(_ roots: [String]) {
            queue.async { [self] in
                guard let indexer else { return }
                do {
                    for root in roots where indexer.watchedPaths.contains(root) {
                        try indexer.crawl(root)
                    }
                    contents?.resume()
                    meaning?.resume()
                } catch {
                    NSLog("File Index: %@", String(describing: error))
                }
            }
        }

        func setLowPower(_ isLowPower: Bool) {
            queue.async { [self] in
                self.isLowPower = isLowPower
                contents?.setLowPower(isLowPower)
                contents?.resume()
                meaning?.setLowPower(isLowPower)
                meaning?.resume()
            }
        }

        /// The Panel opened or closed. Opening it also takes the helper off
        /// full speed at once, for the rest of a batch that is out.
        func setPanelOpen(_ isPanelOpen: Bool) {
            if isPanelOpen {
                let embedders = [embedder, textOnlyEmbedder]
                Task { for embedder in embedders { await embedder.setFullSpeed(false) } }
            }
            queue.async { [self] in
                self.isPanelOpen = isPanelOpen
                meaning?.setPanelOpen(isPanelOpen)
            }
        }

        /// Search by meaning chosen: the vectors adopted and opened, and the
        /// backfill under way, with or without pictures and sound. Off: no
        /// more embedding, the vectors' memory given back and the indexing
        /// helper told to go. From one choice to the other, the helper of
        /// the one before is told to go.
        func setMeaning(_ mode: MeaningMode) {
            queue.async { [self] in
                let before = meaningMode
                meaningMode = mode
                guard let meaning else { return }
                if before != .off, before != mode {
                    meaning.disable()
                    let embedder = before == .text ? textOnlyEmbedder : self.embedder
                    Task { await embedder.shutdown() }
                }
                if mode != .off { enableMeaning(meaning) }
                onProgress?(.wrote)
            }
        }

        /// "Remove" in Settings: every vector out of the database and the
        /// cache, the vector files deleted.
        func removeMeaning() {
            queue.async { [self] in
                meaning?.disable()
                do {
                    try (writer ?? FileIndexWriter(url: databaseURL)).removeMeaning()
                    try (cache ?? VectorCache(url: VectorCache.url(besideDatabase: databaseURL))).removeAll()
                } catch {
                    NSLog("File Index meaning: %@", String(describing: error))
                }
                vectors.deleteFiles()
                onProgress?(.wrote)
            }
        }

        /// The vector cache's daily prune (`VectorCache.pruneIfCaughtUp`),
        /// here on the queue so no crawl, batch or rebuild runs beside it.
        /// Deferred, for the system to try again later, until the Sources
        /// have been applied and the index has caught up.
        func pruneVectorCache(_ completion: @escaping NSBackgroundActivityScheduler.CompletionHandler) {
            queue.async { [self] in
                guard let indexer, let writer, let cache else { return completion(.deferred) }
                do {
                    switch try cache.pruneIfCaughtUp(index: writer, sources: indexer.watchedPaths) {
                    case .deferred:
                        return completion(.deferred)
                    case .done:
                        break
                    case .pruned(let pruning):
                        NSLog("Vector cache: pruned %ld entries unused for %lld days, %ld left (%ld stamped); "
                              + "%.1f MB on disk before, %.1f MB after%@",
                              pruning.removed, VectorCache.unusedDays, pruning.kept, pruning.stamped,
                              Double(pruning.bytesBefore) / 1e6, Double(pruning.bytesAfter) / 1e6,
                              pruning.vacuumed ? ", vacuumed" : "")
                    }
                } catch {
                    NSLog("Vector cache prune: %@", String(describing: error))
                }
                completion(.finished)
            }
        }

        private func enableMeaning(_ meaning: MeaningScheduler) {
            do {
                isVectorFileStale = false
                try meaning.enable(textOnly: meaningMode == .text)
                meaning.resume()
            } catch {
                NSLog("File Index meaning: %@", String(describing: error))
            }
        }

        func stop() {
            queue.async { [self] in
                watcher?.stop()
                watcher = nil
                watchedPaths = []
                contents?.stop()
                meaning?.disable()
            }
        }

        private func openIndexer(rules: FileIndexRules) throws -> FileIndexer {
            if let indexer { return indexer }
            let cache = try VectorCache(url: VectorCache.url(besideDatabase: databaseURL))
            let writer = try FileIndexWriter(url: databaseURL, cache: cache)
            let indexer = FileIndexer(
                writer: writer,
                rules: rules,
                onProgress: { [weak self] progress in self?.onProgress?(progress) }
            )
            let meaning = MeaningScheduler(
                writer: writer,
                vectors: vectors,
                cache: cache,
                queue: queue,
                embed: MeaningScheduler.embedAll(full: embedder, textOnly: textOnlyEmbedder, cache: cache),
                machine: .system,
                onProgress: { [weak self] progress in self?.onProgress?(progress) }
            )
            let contents = FileContentScheduler(
                writer: writer,
                queue: queue,
                onProgress: { [weak self, weak meaning] progress in
                    self?.onProgress?(progress)
                    // What the contents pass stored is text to embed.
                    if case .wrote = progress { meaning?.resume() }
                }
            )
            writer.onVectorsRemoved = { [weak self] files in self?.vectorsRemoved(files) }
            self.writer = writer
            self.cache = cache
            contents.setLowPower(isLowPower)
            meaning.setLowPower(isLowPower)
            meaning.setPanelOpen(isPanelOpen)
            self.indexer = indexer
            self.contents = contents
            self.meaning = meaning
            if meaningMode != .off { enableMeaning(meaning) }
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
            watcher = FileIndexWatcher(paths: paths, since: since, queue: queue) { [weak self] events in
                do {
                    let changed = try indexer.handle(events)
                    self?.contents?.filesChanged(changed)
                    self?.contents?.resume()
                    self?.meaning?.filesChanged(changed)
                    self?.meaning?.resume()
                } catch {
                    NSLog("File Index: %@", String(describing: error))
                }
            }
        }

        private var watchedPaths: [String] = []

        /// Their rows or Passages went: their vectors leave the vector files
        /// too. With those closed, the database says they no longer match it
        /// (`vector_rows` -1), and the next `enable()` rebuilds them, after a
        /// relaunch too.
        private func vectorsRemoved(_ files: [Int64]) {
            if vectors.isOpen {
                vectors.remove(files: files)
            } else if !isVectorFileStale {
                isVectorFileStale = true
                try? writer?.setVectorRows(-1)
            }
        }
    }
}

// MARK: - The daily prune's schedule

/// What runs the vector cache's daily prune: `NSBackgroundActivityScheduler`
/// in the app, a test's own in tests.
nonisolated protocol BackgroundSchedule: AnyObject {
    func schedule(_ block: @escaping @Sendable (@escaping NSBackgroundActivityScheduler.CompletionHandler) -> Void)
    func invalidate()
}

nonisolated extension NSBackgroundActivityScheduler: BackgroundSchedule {
    /// Every 24 hours or so, run when the system finds it a good time: it
    /// defers background work on battery, when hot, or when busy. Maintenance,
    /// not a wait for anything; see AGENTS.md's timing exceptions.
    static func vectorCachePrune() -> NSBackgroundActivityScheduler {
        let scheduler = NSBackgroundActivityScheduler(
            identifier: "\(Bundle.main.bundleIdentifier ?? "com.codiclens").vector-cache-prune"
        )
        scheduler.repeats = true
        scheduler.interval = 24 * 60 * 60
        scheduler.tolerance = 12 * 60 * 60
        scheduler.qualityOfService = .background
        return scheduler
    }
}
