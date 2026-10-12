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
nonisolated final class FileIndexer: @unchecked Sendable {
    /// What a caller is told as work happens. Called on the indexer's queue.
    enum Progress {
        /// A crawl of `source` started or finished.
        case reading(source: String, isReading: Bool)
        /// Rows were written; counts are worth reading again.
        case wrote
    }

    /// How many rows a crawl writes per transaction, and so how often counts
    /// move during one.
    static let batchSize = 500

    private let writer: FileIndexWriter
    private let home: String
    private let onProgress: (Progress) -> Void

    /// What is left out. Changed with `setRules`.
    private(set) var rules: FileIndexRules

    /// Every folder Source, enabled or not, as real paths, longest first so
    /// the first prefix match is the most specific.
    private var allRoots: [String] = []
    private var enabledRoots: Set<String> = []
    private var hasSources = false

    private var pendingWrites = 0

    init(
        writer: FileIndexWriter,
        rules: FileIndexRules = .defaults,
        home: String = NSHomeDirectory(),
        onProgress: @escaping (Progress) -> Void = { _ in }
    ) {
        self.writer = writer
        self.rules = rules
        self.home = home
        self.onProgress = onProgress
    }

    // MARK: - Sources

    /// Brings the index in line with the folder Sources and returns the
    /// roots to `crawl`: every enabled one the first time, and after that the
    /// ones that are new or switched back on. The caller crawls them once its
    /// watcher covers them, so nothing that changes during a crawl is missed.
    ///
    /// A crawl of a folder already indexed is a reconcile — new files added,
    /// changed ones updated, moved ones re-pathed, vanished ones removed — so
    /// the first one is also what catches up on whatever changed while the
    /// app was not running.
    ///
    /// The rows of a folder no longer listed go. A disabled Source keeps its
    /// rows but is neither crawled nor watched; search leaves it out.
    func setSources(_ folders: [(path: String, isEnabled: Bool)]) throws -> [String] {
        let isFirst = !hasSources
        hasSources = true
        let previouslyEnabled = enabledRoots
        let resolved = folders.map { (path: Self.realPath($0.path), isEnabled: $0.isEnabled) }
        allRoots = Set(resolved.map(\.path)).sorted { $0.count > $1.count }
        enabledRoots = Set(resolved.filter(\.isEnabled).map(\.path))

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

        return allRoots.reversed().filter { root in
            enabledRoots.contains(root) && (isFirst || !previouslyEnabled.contains(root))
        }
    }

    /// The enabled roots, for the watcher.
    var watchedPaths: [String] {
        allRoots.filter(enabledRoots.contains).sorted()
    }

    // MARK: - Rules

    /// Adopts new skip rules and returns the roots to `crawl` under them.
    ///
    /// Rules that only skip more need no crawl: what they leave out is
    /// already in the index, and goes from there. Rules that let in anything
    /// the old ones kept out return every enabled root, because only a walk
    /// can find what was never read — and since a crawl is a reconcile, it
    /// deletes whatever the new rules leave out on the same pass. Rows nothing
    /// changed for are not written either way.
    func setRules(_ rules: FileIndexRules) throws -> [String] {
        let old = self.rules
        self.rules = rules
        guard hasSources, rules != old else { return [] }
        if rules.skipsAtLeast(old) {
            try prune()
            return []
        }
        return allRoots.reversed().filter(enabledRoots.contains)
    }

    /// Deletes the rows `rules` leave out, judged from the index: a row's
    /// path and kind, and the disk only where a rule has to look. Parents
    /// sort before their contents, so a folder is judged before what is in
    /// it, and what is in a skipped folder goes with it, unjudged.
    private func prune() throws {
        try writer.db.transaction {
            for root in allRoots where enabledRoots.contains(root) {
                // Folders whose contents are gone: skipped, or no longer descended into.
                var emptied = Set<String>()
                for row in try writer.rows(inTree: root).sorted(by: { $0.path < $1.path })
                where row.path != root && self.root(containing: row.path) == root
                    && !Self.isInside(row.path, anyOf: emptied, below: root) {
                    switch rules.verdict(for: FileIndexRules.Entry(row: row), root: root, home: home) {
                    case .skip:
                        pendingWrites += try writer.deleteTree(row.path, source: root)
                        if row.kind != .file { emptied.insert(row.path) }
                    case .indexWithoutDescending:
                        pendingWrites += try writer.deleteTree(row.path, keepingRoot: true, source: root)
                        emptied.insert(row.path)
                    case .index:
                        break
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

    /// Reads a whole folder Source again.
    func crawl(_ root: String) throws {
        onProgress(.reading(source: root, isReading: true))
        defer { onProgress(.reading(source: root, isReading: false)) }
        try reconcile(root, root: root)
    }

    // MARK: - FSEvents

    /// Applies one batch from `FileIndexWatcher`.
    ///
    /// Each path is looked at on disk; the flags are only trusted to say that
    /// FSEvents lost track. A path that exists is added or updated — or, if a
    /// file with its inode, size and date just vanished from another path,
    /// moved. A path that does not exist is removed with everything under it.
    /// Present paths go first, so a rename's new name claims the row before
    /// its old name is deleted.
    func handle(_ events: [FileIndexWatcher.Event]) throws {
        let events = events.filter { !$0.isBookkeeping }
        if events.contains(where: \.droppedEvents) {
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

        for (path, root) in rescans { try reconcile(path, root: root) }

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
        guard let row = scan(path, root: root, excluded: &excluded) else {
            // Exists but is not to be indexed — perhaps it just became so,
            // as a folder does when a `.git` appears in it. A Source inside
            // it is the user's choice, and stays.
            pendingWrites += try writer.deleteTree(path, source: root)
            return
        }

        if let existing = try writer.row(atPath: path) {
            if !existing.isSameVersion(as: row) || existing.kind != row.kind || existing.source != row.source {
                try writer.update(existing.id, to: row)
                pendingWrites += 1
            }
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
            try writer.insert(row)
            pendingWrites += 1
        }
    }

    /// The row for `path` if it is to be indexed, judging it *and* every folder
    /// between it and its root by `FileIndexRules`.
    private func scan(_ path: String, root: String, excluded: inout ExclusionCache) -> FileIndexRow? {
        var folder = (path as NSString).deletingLastPathComponent
        var ancestors: [String] = []
        while folder.count > root.count, folder.hasPrefix(root) {
            ancestors.append(folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
        for ancestor in ancestors.reversed() {
            let verdict = excluded.verdict(for: ancestor) {
                rules.verdict(for: FileIndexRules.Entry(url: URL(fileURLWithPath: ancestor)), root: root, home: home)
            }
            if verdict != .index { return nil }
        }

        let entry = FileIndexRules.Entry(url: URL(fileURLWithPath: path))
        guard rules.verdict(for: entry, root: root, home: home) != .skip else { return nil }
        return Self.row(for: entry, source: root)
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

        if !inTransaction { try writer.db.execute("BEGIN IMMEDIATE") }
        do {
            var excluded = ExclusionCache()
            if path == root || scan(path, root: root, excluded: &excluded) != nil {
                try walk(path, root: root) { row in
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

    private func record(_ row: FileIndexRow, existing: inout [String: FileIndexRow]) throws {
        if let current = existing[row.path] {
            if !current.isSameVersion(as: row) || current.kind != row.kind || current.source != row.source {
                try writer.update(current.id, to: row)
                pendingWrites += 1
            }
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
        try writer.insert(row)
        pendingWrites += 1
    }

    /// Calls `body` with a row for `path` and every indexable entry under it.
    private func walk(_ path: String, root: String, body: (FileIndexRow) throws -> Void) throws {
        let url = URL(fileURLWithPath: path)
        let top = FileIndexRules.Entry(url: url)
        guard top.isDirectory || Self.exists(exactly: path) else { return }
        try body(Self.row(for: top, source: root))
        guard top.isDirectory, rules.verdict(for: top, root: root, home: home) == .index else { return }

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
                let entry = FileIndexRules.Entry(url: next, values: values)
                switch rules.verdict(for: entry, root: root, home: home) {
                case .skip:
                    if entry.isDirectory { enumerator.skipDescendants() }
                    return
                case .indexWithoutDescending:
                    enumerator.skipDescendants()
                case .index:
                    break
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

    /// Whether something is at exactly `path` — this spelling, not another
    /// case of it. FSEvents reports a case-only rename under both names, and
    /// on a case-insensitive volume both of them `lstat` fine.
    static func exists(exactly path: String) -> Bool {
        guard let resolved = realpath(path, nil) else { return false }
        defer { free(resolved) }
        return String(cString: resolved) == path
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
            device: UInt64(bitPattern: Int64(info.st_dev))
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
