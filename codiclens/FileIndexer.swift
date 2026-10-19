import CoreServices
import Foundation

/// The writing side of the File Index: crawls folder Sources, applies
/// FSEvents batches, and keeps one row per file in `FileIndexWriter`.
///
/// Synchronous and not thread-safe: `FileIndex` calls every method on its one
/// serial queue, tests call them directly. Nothing here is read by the search
/// path — that goes through `FileIndexReader` and the database alone — which
/// is what lets this move into a helper process.
///
/// **Every row belongs to the most specific Source that contains it.** A
/// folder Source inside another is its own Source: the outer crawl does not
/// walk into it, and removing the inner one hands its files back to the
/// outer.
///
/// **A launch replays, it does not crawl.** The index keeps the FSEvents event
/// ID it has caught up to and, per root, the volume it was read on. Started
/// again, the watcher asks FSEvents for everything since that ID and `handle`
/// applies it like any other batch. A root is crawled instead only when the
/// replay cannot be trusted for it: nothing stored yet, its volume's event
/// history replaced, the rules changed, or its last crawl never finished.
///
/// **A restart does not make a file new.** Rows record the device number
/// (`st_dev`) a file was on, and macOS may number a volume differently at
/// each boot. Each root's volume is kept by its UUID beside the number its
/// rows say (`adoptVolume`), and when only the number changed the rows take
/// the new one before anything compares them with the disk; otherwise every
/// file would look changed, and be read and embedded again.
///
/// **What git ignores is git's to say** (`GitIgnored`). A crawl lists each
/// repo it walks into; a batch asks about the paths it brings that have no
/// row; and a `.gitignore`, `.git/info/exclude` or `.git` that changes reads
/// its repo again. A launch that replays asks git only about what the replay
/// brings.
nonisolated final class FileIndexer: @unchecked Sendable {
    /// What a caller is told as work happens. Called on the indexer's queue.
    enum Progress {
        /// A crawl of `source` started or finished.
        case reading(source: String, isReading: Bool)
        /// Rows were written; counts are worth reading again.
        case wrote
        /// The contents backfill started or stopped (`FileContentScheduler`).
        case readingContents(isReading: Bool)
    }

    /// How many rows a crawl writes per transaction, and so how often counts
    /// move during one.
    static let batchSize = 500

    private let writer: FileIndexWriter
    private let gitIgnored: GitIgnored
    private let home: String
    private let volumeID: (String) -> String?
    private let volume: (String) -> FileIndexVolume?
    private let onProgress: (Progress) -> Void

    /// Where the watcher starts: the event the index has caught up to. Set
    /// by the first `setSources`, moved on by every batch `handle` applies.
    private(set) var eventID: FSEventStreamEventId = 0

    /// What is left out. Changed with `setRules`.
    private(set) var rules: FileIndexRules

    /// Every folder Source, enabled or not, as real paths, longest first so
    /// the first prefix match is the most specific.
    private var allRoots: [String] = []
    private var enabledRoots: Set<String> = []
    private var hasSources = false

    private var pendingWrites = 0

    /// The files with contents to read that the batch being handled added or
    /// changed; nil outside `handle`.
    private var changedFiles: [Int64]?

    /// The repos listed again during the batch being handled, so a burst of
    /// new folders in one repo lists it once; nil outside `handle`.
    private var relistedRepos: Set<String>?

    /// - Parameters:
    ///   - gitIgnored: who asks git. Tests pass one without git.
    ///   - volumeID: the FSEvents history a path's events are kept in,
    ///     `volumeID(of:)`. Tests pass their own to stand for a disk whose
    ///     history was replaced.
    ///   - volume: the volume a path is on and its device number now,
    ///     `volume(of:)`. Tests pass their own to stand for a restart that
    ///     renumbered it, or another disk.
    init(
        writer: FileIndexWriter,
        rules: FileIndexRules = .defaults,
        gitIgnored: GitIgnored = GitIgnored(),
        home: String = NSHomeDirectory(),
        volumeID: @escaping (String) -> String? = FileIndexer.volumeID(of:),
        volume: @escaping (String) -> FileIndexVolume? = FileIndexer.volume(of:),
        onProgress: @escaping (Progress) -> Void = { _ in }
    ) {
        self.writer = writer
        self.rules = rules
        self.gitIgnored = gitIgnored
        self.home = home
        self.volumeID = volumeID
        self.volume = volume
        self.onProgress = onProgress
    }

    // MARK: - Sources

    /// Brings the index in line with the folder Sources and returns the
    /// roots to `crawl`: the first time, every enabled one a replay from
    /// `eventID` cannot catch up (`caughtUpRoots`), and after that the ones
    /// that are new or switched back on. The caller starts its watcher at
    /// `eventID` and crawls them after, so nothing that changes during a
    /// crawl is missed.
    ///
    /// A crawl of a folder already indexed is a reconcile — new files added,
    /// changed ones updated, moved ones re-pathed, vanished ones removed — so
    /// a root that has to be crawled at launch keeps its rows meanwhile.
    ///
    /// The rows of a folder no longer listed go. A disabled Source keeps its
    /// rows but is neither crawled nor watched; search leaves it out, and it
    /// is crawled again when it comes back, since nothing watched it.
    ///
    /// The first time, before any of that, every root's rows take the device
    /// number its volume has this boot (`adoptVolume`), the disabled ones'
    /// too: they are compared with the disk when they come back.
    func setSources(_ folders: [(path: String, isEnabled: Bool)]) throws -> [String] {
        let isFirst = !hasSources
        hasSources = true
        let previouslyEnabled = enabledRoots
        let resolved = folders.map { (path: Self.realPath($0.path), isEnabled: $0.isEnabled) }
        allRoots = Set(resolved.map(\.path)).sorted { $0.count > $1.count }
        enabledRoots = Set(resolved.filter(\.isEnabled).map(\.path))

        try writer.db.transaction {
            if isFirst { for root in allRoots { try adoptVolume(of: root) } }
            try writer.forgetVolumes(keeping: Set(allRoots))
        }

        // If a removed Source sat inside another, its folder belongs to that
        // one again and is read under it.
        let removed = try writer.sources().subtracting(allRoots)
        try writer.db.transaction {
            for source in removed { try writer.deleteSource(source) }
        }
        if !removed.isEmpty { onProgress(.wrote) }
        for source in removed {
            if let owner = root(containing: source), enabledRoots.contains(owner) {
                try reconcile(source, root: owner)
            }
        }

        let caughtUp = isFirst ? try caughtUpRoots() : []
        try writer.forgetCaughtUpRoots(keeping: enabledRoots)
        return allRoots.reversed().filter { root in
            enabledRoots.contains(root) && (isFirst ? !caughtUp.contains(root) : !previouslyEnabled.contains(root))
        }
    }

    /// At launch: the enabled roots a replay from the stored event ID brings
    /// up to date. None when there is no ID — the index was never watched —
    /// or the rows were read under other rules. Otherwise each root whose
    /// last crawl finished on the volume it is on now: a different volume
    /// UUID is FSEvents saying its history for that disk was replaced, and
    /// the IDs mean nothing there.
    ///
    /// Stores where the watcher is to start from: the old ID, or with none,
    /// the current one — every change after it is delivered, and every root
    /// is crawled after it.
    private func caughtUpRoots() throws -> Set<String> {
        let stored = try writer.eventID()
        let rulesMatch = try writer.rulesFingerprint() == rulesFingerprint
        let known = try writer.caughtUpRoots()
        eventID = stored ?? FSEventsGetCurrentEventId()
        try writer.db.transaction {
            if stored == nil { try writer.setEventID(eventID) }
            if !rulesMatch {
                try writer.forgetCaughtUpRoots()
                try writer.setRulesFingerprint(rulesFingerprint)
            }
        }
        guard stored != nil, rulesMatch else { return [] }
        return enabledRoots.filter { root in known[root].map { $0 == volumeID(root) } ?? false }
    }

    /// The enabled roots, for the watcher.
    var watchedPaths: [String] {
        allRoots.filter(enabledRoots.contains).sorted()
    }

    // MARK: - Rules

    /// What the rows are read under, as kept beside them: the rules, and with
    /// "Ignored by git" on, git's own setup (`GitIgnored.setupStamp`), which
    /// no event in a Source reports changing.
    var rulesFingerprint: String {
        guard rules.skips(.gitIgnored) else { return rules.fingerprint }
        return rules.fingerprint + "\n--\n" + gitIgnored.setupStamp
    }

    /// Whether git is asked at all: the switch is on and there is a git.
    private var asksGit: Bool {
        rules.skips(.gitIgnored) && gitIgnored.isAvailable
    }

    /// Adopts new skip rules and returns the roots to `crawl` under them.
    ///
    /// Rules that only skip more need no crawl: what they leave out is
    /// already in the index, and goes from there. Rules that let in anything
    /// the old ones kept out return every enabled root, because only a walk
    /// can find what was never read — and since a crawl is a reconcile, it
    /// deletes whatever the new rules leave out on the same pass. Rows nothing
    /// changed for are not written either way.
    ///
    /// The new rules are stored with the index. A root to be crawled stops
    /// counting as caught up until its crawl finishes, so quitting halfway
    /// leaves it to be crawled at the next launch.
    func setRules(_ rules: FileIndexRules) throws -> [String] {
        let old = self.rules
        self.rules = rules
        // Asked again from scratch when the switch next comes on.
        if !rules.skips(.gitIgnored) { gitIgnored.forgetAll() }
        guard hasSources, rules != old else { return [] }
        if rules.skipsAtLeast(old) {
            try prune()
            try writer.setRulesFingerprint(rulesFingerprint)
            return []
        }
        try writer.db.transaction {
            try writer.forgetCaughtUpRoots()
            try writer.setRulesFingerprint(rulesFingerprint)
        }
        return allRoots.reversed().filter(enabledRoots.contains)
    }

    /// Deletes the rows `rules` leave out, judged from the index: a row's
    /// path and kind, and the disk only where a rule has to look. Parents
    /// sort before their contents, so a folder is judged before what is in
    /// it, and what is in a skipped folder goes with it, unjudged. A repo is
    /// listed by git, if it was not already, before what is in it is judged.
    private func prune() throws {
        let asksGit = asksGit
        try writer.db.transaction {
            for root in allRoots where enabledRoots.contains(root) {
                if asksGit, FileIndexRules.Entry(url: URL(fileURLWithPath: root)).containsGit {
                    gitIgnored.loadIfNeeded(repo: root)
                }
                // Folders whose contents are gone: skipped, or no longer descended into.
                var emptied = Set<String>()
                for row in try writer.rows(inTree: root).sorted(by: { $0.path < $1.path })
                where row.path != root && self.root(containing: row.path) == root
                    && !Self.isInside(row.path, anyOf: emptied, below: root) {
                    var entry = FileIndexRules.Entry(row: row)
                    entry.isGitIgnored = asksGit && gitIgnored.isIgnored(row.path, below: root)
                    switch rules.verdict(for: entry, root: root, home: home) {
                    case .skip:
                        pendingWrites += try writer.deleteTree(row.path, source: root)
                        if row.kind != .file { emptied.insert(row.path) }
                    case .indexWithoutDescending:
                        pendingWrites += try writer.deleteTree(row.path, keepingRoot: true, source: root)
                        emptied.insert(row.path)
                    case .descendWithoutIndexing:
                        // Its own row only: what is in it is judged in turn.
                        try writer.delete(row.id)
                        pendingWrites += 1
                    case .index:
                        if asksGit, entry.containsGit { gitIgnored.loadIfNeeded(repo: row.path) }
                    }
                }
            }
        }
        flushProgress()
    }

    private static func isInside(_ path: String, anyOf folders: Set<String>, below root: String) -> Bool {
        guard !folders.isEmpty else { return false }
        var folder = (path as NSString).deletingLastPathComponent
        while folder.utf8.count > root.utf8.count {
            if folders.contains(folder) { return true }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return false
    }

    /// Reads a whole folder Source again. Once it has, the root is caught
    /// up, on the volume it is on.
    func crawl(_ root: String) throws {
        onProgress(.reading(source: root, isReading: true))
        defer { onProgress(.reading(source: root, isReading: false)) }
        // Every repo in it is listed again as the walk reaches it.
        gitIgnored.forget(below: root)
        // Its volume is noted before the walk writes rows on it: a new
        // Source's first, or one mounted again since launch under a new number.
        try writer.db.transaction { try adoptVolume(of: root) }
        try reconcile(root, root: root)
        try writer.setCaughtUp(root, volume: volumeID(root))
    }

    // MARK: - FSEvents

    /// Applies one batch from `FileIndexWatcher`, live or replayed, and
    /// stores its last event ID as how far the index has caught up. Returns
    /// the files it added or changed that have contents to read, for those to
    /// be read before the backfill (`FileContentScheduler`).
    ///
    /// Each path is looked at on disk; the flags are only trusted to say that
    /// FSEvents lost track. A path that exists is added or updated — or, if a
    /// file with its inode, size and date just vanished from another path,
    /// moved. A path that does not exist is removed with everything under it.
    /// Present paths go first, so a rename's new name claims the row before
    /// its old name is deleted.
    @discardableResult
    func handle(_ events: [FileIndexWatcher.Event]) throws -> [Int64] {
        changedFiles = []
        relistedRepos = []
        defer { (changedFiles, relistedRepos) = (nil, nil) }
        let latest = events.last { !$0.historyDone && $0.id != nil }?.id
        try apply(events.filter { !$0.historyDone })
        if let latest {
            eventID = latest
            try writer.setEventID(latest)
        }
        return changedFiles ?? []
    }

    private func apply(_ events: [FileIndexWatcher.Event]) throws {
        if events.contains(where: \.lostTrack) {
            for root in watchedPaths { try crawl(root) }
            return
        }

        var rescans: [(path: String, root: String)] = []
        var paths = Set<String>()
        for event in events {
            if event.rootChanged || event.mustRescan {
                for (path, root) in rescanTargets(for: event.path) { rescans.append((path, root)) }
                continue
            }
            paths.formUnion(relevantPaths(event.path))
        }

        for (path, root) in rescans {
            if path == root { try crawl(root) } else { try reconcile(path, root: root) }
        }
        for (repo, root) in reposToRead(after: events) {
            // Its `.git` may be gone, and then nothing lists it again.
            gitIgnored.forget(repo: repo)
            if repo == root { try crawl(root) } else { try reconcile(repo, root: root) }
        }

        var present: [String: String] = [:]
        var absent: [String] = []
        for path in paths {
            guard let root = root(containing: path), enabledRoots.contains(root) else { continue }
            // A case-only rename can arrive as just the old name: what is
            // there now is the same file under its new spelling.
            let actual = Self.realPath(path)
            if actual.lowercased() == path.lowercased(), Self.exists(exactly: actual) {
                present[actual] = root
                if actual != path { absent.append(path) }
            } else {
                absent.append(path)
            }
        }
        let ordered = present.sorted { $0.key.count < $1.key.count }

        // What git makes of the paths the index has never seen: one question
        // per repo for the whole batch.
        if asksGit {
            var unseen: [String: [String]] = [:]
            for (path, root) in ordered {
                if try writer.row(atPath: path) == nil { unseen[root, default: []].append(path) }
            }
            for (root, paths) in unseen { gitIgnored.ask(paths, below: root) }
        }

        var excluded = ExclusionCache()
        try writer.db.transaction {
            for (path, root) in ordered {
                try apply(presentPath: path, root: root, excluded: &excluded)
            }
            for path in absent {
                pendingWrites += try writer.deleteTree(path)
            }
        }
        flushProgress()
    }

    /// The paths an event is news about, none when it is about nothing
    /// indexed.
    ///
    /// An event inside a folder skipped by name alone — a `.git`, a
    /// `node_modules` — is dropped without looking at the disk. A `.git`
    /// arriving or leaving is news about its folder too: it just became a
    /// repo, or stopped being one.
    private func relevantPaths(_ path: String) -> [String] {
        guard let root = root(containing: path) else { return [] }
        let relative = path.dropFirst(root.count).split(separator: "/")
        guard let last = relative.last else { return [path] }
        let parent = last == ".git" ? [(path as NSString).deletingLastPathComponent] : []
        if relative.dropLast().contains(where: { rules.skipsFolder(named: String($0)) }) { return parent }
        return [path] + parent
    }

    /// The repos whose ignore rules the batch changed — a `.gitignore`
    /// anywhere in one, its `.git/info/exclude`, or its `.git` arriving or
    /// leaving — each with its root: they are listed and read again. Not in a
    /// folder skipped by name or one git ignores: npm puts a `.gitignore` all
    /// over `node_modules`, and git reads none of them. A repo inside another
    /// being read is read with it.
    private func reposToRead(after events: [FileIndexWatcher.Event]) -> [(String, String)] {
        guard asksGit else { return [] }
        var repos: [String: String] = [:]
        for event in events {
            let name = (event.path as NSString).lastPathComponent
            let folder = (event.path as NSString).deletingLastPathComponent
            guard let root = root(containing: folder), enabledRoots.contains(root) else { continue }
            let repo: String?
            switch name {
            case ".gitignore": repo = GitIgnored.repos(containing: event.path, below: root).last
            case ".git": repo = folder
            case "exclude" where folder.hasSuffix("/.git/info"): repo = String(folder.dropLast("/.git/info".count))
            default: repo = nil
            }
            // The folder the rules came from: the `.gitignore`'s, or the repo.
            guard let repo, self.root(containing: repo) == root else { continue }
            let source = name == ".gitignore" ? folder : repo
            let names = source.dropFirst(root.count).split(separator: "/")
            if names.contains(where: { rules.skipsFolder(named: String($0)) })
                || gitIgnored.isIgnored(source, below: root) { continue }
            repos[repo] = root
        }
        let outermost = repos.filter { repo, _ in
            !repos.keys.contains { repo.hasPrefix($0 + "/") }
        }
        return outermost.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// What to read again when FSEvents lost track at `path`: that subtree, or
    /// — when `path` is above the roots, as a dropped-events path can be —
    /// every enabled root under it.
    private func rescanTargets(for path: String) -> [(String, String)] {
        let path = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        if let root = root(containing: path), enabledRoots.contains(root) {
            return [(path, root)]
        }
        return watchedPaths.filter { $0.hasPrefix(path == "/" ? "/" : path + "/") }.map { ($0, $0) }
    }

    private func apply(presentPath path: String, root: String, excluded: inout ExclusionCache) throws {
        let (verdict, scanned) = scan(path, root: root, excluded: &excluded)
        guard let row = scanned else {
            if verdict == .descendWithoutIndexing {
                // A folder git ignores: no row, but a `.env` or a key that
                // came with it has one.
                try reconcile(path, root: root, inTransaction: true)
                return
            }
            // Exists but is not to be indexed — perhaps it just became so,
            // as a folder does when a `.git` appears in it. A Source inside
            // it is the user's choice, and stays.
            pendingWrites += try writer.deleteTree(path, source: root)
            return
        }

        if let existing = try writer.row(atPath: path) {
            try update(existing, to: row)
            return
        }

        if let moved = try movedRow(for: row) {
            if moved.kind == .folder {
                try writer.moveTree(from: moved.path, to: path, source: root)
            } else {
                try writer.move(moved.id, to: path, source: root)
            }
            pendingWrites += 1
            return
        }

        if row.kind == .folder {
            // A folder that is new here — created with contents, moved in
            // from outside, or no longer a repo. Its contents get no events of
            // their own, so it is read whole.
            try reconcile(path, root: root, inTransaction: true)
        } else {
            try insert(row)
        }
    }

    /// The verdict on `path`, judging it *and* every folder between it and
    /// its root by `FileIndexRules` — `.skip` when one of those leaves it out
    /// — and the row for it if it is to have one.
    private func scan(
        _ path: String, root: String, excluded: inout ExclusionCache
    ) -> (verdict: FileIndexRules.Verdict, row: FileIndexRow?) {
        var folder = (path as NSString).deletingLastPathComponent
        var ancestors: [String] = []
        while folder.count > root.count, folder.hasPrefix(root) {
            ancestors.append(folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
        for ancestor in ancestors.reversed() {
            let verdict = excluded.verdict(for: ancestor) {
                rules.verdict(for: entry(atPath: ancestor, root: root), root: root, home: home)
            }
            if verdict != .index, verdict != .descendWithoutIndexing { return (.skip, nil) }
        }

        let judged = entry(atPath: path, root: root)
        let verdict = rules.verdict(for: judged, root: root, home: home)
        switch verdict {
        case .skip, .descendWithoutIndexing: return (verdict, nil)
        case .index, .indexWithoutDescending: return (verdict, Self.row(for: judged, source: root))
        }
    }

    /// `path` as the rules see it: read from disk, and ignored by git if git
    /// has said so, for it or a folder above it.
    private func entry(atPath path: String, root: String) -> FileIndexRules.Entry {
        var entry = FileIndexRules.Entry(url: URL(fileURLWithPath: path))
        entry.isGitIgnored = asksGit && gitIgnored.isIgnored(path, below: root)
        return entry
    }

    // MARK: - Reconcile

    /// Walks `path` — a whole Source, or a subtree of one — and makes the rows
    /// under it match the disk: inserts, updates, moves and deletes. Rows that
    /// belong to a more specific Source are not this walk's to touch.
    func reconcile(_ path: String, root: String) throws {
        try reconcile(path, root: root, inTransaction: false)
    }

    private func reconcile(_ path: String, root: String, inTransaction: Bool) throws {
        var existing: [String: FileIndexRow] = [:]
        for row in try writer.rows(inTree: path) where self.root(containing: row.path) == root {
            existing[row.path] = row
        }
        var seen = Set<String>()

        if path != root { relistGit(around: path, root: root) }

        if !inTransaction { try writer.db.execute("BEGIN IMMEDIATE") }
        do {
            var excluded = ExclusionCache()
            let verdict: FileIndexRules.Verdict = path == root
                ? .index : scan(path, root: root, excluded: &excluded).verdict
            if verdict != .skip {
                try walk(path, root: root, verdict: verdict) { row in
                    seen.insert(row.path)
                    try record(row, existing: &existing)
                    if !inTransaction, pendingWrites >= Self.batchSize {
                        try writer.db.execute("COMMIT; BEGIN IMMEDIATE")
                        flushProgress()
                    }
                }
            }
            for (path, row) in existing where !seen.contains(path) {
                try writer.delete(row.id)
                pendingWrites += 1
            }
            if !inTransaction { try writer.db.execute("COMMIT") }
        } catch {
            if !inTransaction { try? writer.db.execute("ROLLBACK") }
            throw error
        }
        if !inTransaction { flushProgress() }
    }

    /// Before a folder inside a Source is walked: lists again the repo it is
    /// in, so what is in the folder is judged as git sees it now, not as it
    /// was at the last crawl — once a batch. Outside a batch the folder itself
    /// is asked about too; in one, `apply` asked about every new path.
    private func relistGit(around path: String, root: String) {
        guard asksGit else { return }
        if relistedRepos == nil { gitIgnored.ask([path], below: root) }
        guard let repo = GitIgnored.repos(containing: path, below: root).last,
              relistedRepos?.insert(repo).inserted ?? true else { return }
        gitIgnored.load(repo: repo)
    }

    private func record(_ row: FileIndexRow, existing: inout [String: FileIndexRow]) throws {
        if let current = existing[row.path] {
            try update(current, to: row)
            return
        }
        // Files only: a folder that moved during a walk is a new folder row,
        // and each file in it is found as a move on its own.
        if row.kind != .folder, let moved = try movedRow(for: row) {
            try writer.move(moved.id, to: row.path, source: row.source)
            existing[moved.path] = nil
            pendingWrites += 1
            return
        }
        try insert(row)
    }

    private func insert(_ row: FileIndexRow) throws {
        let id = try writer.insert(row)
        pendingWrites += 1
        if row.content != nil { changedFiles?.append(id) }
    }

    /// Writes `row` over `existing` if anything changed. Contents are read
    /// again only when the file did: a row that only changed Source keeps
    /// its Passages.
    private func update(_ existing: FileIndexRow, to row: FileIndexRow) throws {
        let isSameFile = existing.isSameVersion(as: row) && existing.kind == row.kind
        guard !isSameFile || existing.source != row.source else { return }
        try writer.update(existing.id, to: row, keepingContents: isSameFile)
        pendingWrites += 1
        if !isSameFile, row.content != nil { changedFiles?.append(existing.id) }
    }

    /// Calls `body` with a row for `path` and every indexable entry under it.
    /// `verdict` is `path`'s own: a folder git ignores has no row, and is
    /// walked for what keeps to its own switches. Each repo the walk reaches
    /// is listed by git before anything in it is judged.
    private func walk(
        _ path: String, root: String, verdict: FileIndexRules.Verdict, body: (FileIndexRow) throws -> Void
    ) throws {
        let url = URL(fileURLWithPath: path)
        let top = FileIndexRules.Entry(url: url)
        guard top.isDirectory || Self.exists(exactly: path) else { return }
        if verdict != .descendWithoutIndexing { try body(Self.row(for: top, source: root)) }
        guard top.isDirectory, verdict == .index || verdict == .descendWithoutIndexing else { return }
        let asksGit = asksGit
        if asksGit, verdict == .index, top.containsGit { gitIgnored.load(repo: path) }
        // The folder git ignores that the walk is in: everything in it is
        // ignored too. A walk is depth first, so once a path is not inside
        // it, none after will be.
        var ignoredFolder = verdict == .descendWithoutIndexing ? path : nil

        // Hidden files and packages are the rules' to judge, not the
        // enumerator's: either can be switched back in.
        let nested = Set(allRoots.filter { $0 != root && $0.hasPrefix(path + "/") })
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: FileIndexRules.resourceKeys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return }

        var failure: Error?
        while failure == nil, let next = autoreleasepool(invoking: { enumerator.nextObject() as? URL }) {
            autoreleasepool {
                if nested.contains(next.path) {
                    enumerator.skipDescendants()
                    return
                }
                let values = try? next.resourceValues(forKeys: Set(FileIndexRules.resourceKeys))
                var entry = FileIndexRules.Entry(url: next, values: values)
                if let folder = ignoredFolder, !entry.path.hasPrefix(folder + "/") { ignoredFolder = nil }
                entry.isGitIgnored = asksGit && (ignoredFolder != nil || gitIgnored.contains(entry.path, below: root))
                switch rules.verdict(for: entry, root: root, home: home) {
                case .skip:
                    if entry.isDirectory { enumerator.skipDescendants() }
                    return
                case .indexWithoutDescending:
                    enumerator.skipDescendants()
                case .descendWithoutIndexing:
                    if ignoredFolder == nil { ignoredFolder = entry.path }
                    return
                case .index:
                    if asksGit, entry.containsGit { gitIgnored.load(repo: entry.path) }
                }
                do { try body(Self.row(for: entry, source: root)) } catch { failure = error }
            }
        }
        if let failure { throw failure }
    }

    /// The row `row`'s file had before it moved: same device, inode, size and
    /// date, at a path where that file no longer is. A path that differs only
    /// in case is the same file renamed, on a case-insensitive volume.
    private func movedRow(for row: FileIndexRow) throws -> FileIndexRow? {
        try writer.rows(device: row.device, inode: row.inode).first { candidate in
            guard candidate.path != row.path, candidate.isSameVersion(as: row) else { return false }
            if candidate.path.lowercased() == row.path.lowercased() { return true }
            guard Self.exists(exactly: candidate.path) else { return true }
            var info = stat()
            return lstat(candidate.path, &info) == 0 && UInt64(info.st_ino) != row.inode
        }
    }

    private func flushProgress() {
        guard pendingWrites > 0 else { return }
        pendingWrites = 0
        onProgress(.wrote)
    }

    // MARK: - Paths

    /// The most specific Source containing `path` (or equal to it).
    func root(containing path: String) -> String? {
        allRoots.first { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Notes the volume `root` is on now. If its rows were read on the same
    /// volume under another device number — a restart renumbers volumes —
    /// they take the new one, so a walk or a replay still finds each file
    /// unchanged instead of reading it, and embedding it, again. Rows on a
    /// different volume, or with none noted, are left as they are: those are
    /// other files. A root that is not there now keeps what was noted.
    private func adoptVolume(of root: String) throws {
        guard let current = volume(root) else { return }
        let stored = try writer.volume(of: root)
        guard stored != current else { return }
        if let stored, stored.uuid == current.uuid {
            let changed = try writer.renumberDevice(from: stored.device, to: current.device, source: root)
            NSLog("File Index: %@ is on device %llu now, was %llu; %ld rows renumbered",
                  root, current.device, stored.device, changed)
        }
        try writer.setVolume(current, of: root)
    }

    /// Whether something is at exactly `path` — this spelling, not another
    /// case of it. FSEvents reports a case-only rename under both names, and
    /// on a case-insensitive volume both of them `lstat` fine.
    static func exists(exactly path: String) -> Bool {
        guard let resolved = realpath(path, nil) else { return false }
        defer { free(resolved) }
        return String(cString: resolved) == path
    }

    /// The UUID of the FSEvents history kept for the volume `path` is on, or
    /// nil where there is none to replay — a volume FSEvents does not log.
    static func volumeID(of path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0,
              let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The volume `path` is on, by its UUID, and its device number as
    /// `lstat` gives it to rows. Nil where either is missing.
    static func volume(of path: String) -> FileIndexVolume? {
        var info = stat()
        guard lstat(path, &info) == 0,
              let uuid = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        else { return nil }
        return FileIndexVolume(uuid: uuid, device: UInt64(bitPattern: Int64(info.st_dev)))
    }

    /// `path` with symlinks resolved, as FSEvents and the enumerator report it
    /// (`/var` is `/private/var`). Unchanged if it does not exist.
    static func realPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard let resolved = realpath(expanded, nil) else { return expanded }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func row(for entry: FileIndexRules.Entry, source: String) -> FileIndexRow {
        var info = stat()
        _ = lstat(entry.path, &info)
        let kind: FileIndexRow.Kind = entry.isPackage ? .package : entry.isDirectory ? .folder : .file
        return FileIndexRow(
            path: entry.path,
            source: source,
            kind: kind,
            size: kind == .folder ? 0 : Int64(info.st_size),
            mtime: kind == .folder ? 0 : Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9,
            inode: UInt64(info.st_ino),
            device: UInt64(bitPattern: Int64(info.st_dev)),
            content: FileContent.of(entry)
        )
    }
}

/// Folder verdicts within one batch: a burst of events in one folder asks
/// about the same ancestors over and over.
nonisolated private struct ExclusionCache {
    private var verdicts: [String: FileIndexRules.Verdict] = [:]

    mutating func verdict(for path: String, compute: () -> FileIndexRules.Verdict) -> FileIndexRules.Verdict {
        if let known = verdicts[path] { return known }
        let verdict = compute()
        verdicts[path] = verdict
        return verdict
    }
}
