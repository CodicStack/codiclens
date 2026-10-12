// Schema and name/folder search text adapted from DigUp's IndexStore.swift (https://github.com/ARahim3/DigUp),
// MIT licence — see digup-license.txt.
import Foundation
import UniformTypeIdentifiers

/// The File Index on disk: one SQLite file, written by one `FileIndexWriter`
/// and read by any number of `FileIndexReader`s on connections of their own.
///
/// Nothing a reader does depends on the writer being in this process. Today
/// the writer runs on `FileIndex`'s queue; the plan is a helper process that
/// also reads files' contents, and the database is the only thing the two
/// sides share.
nonisolated enum FileIndexSchema {
    /// An index from any other version is dropped and read again, never
    /// migrated: everything in it comes from the disk.
    static let version: Int64 = 2

    /// Porter stemming over Unicode words, with diacritics folded where
    /// Unicode decomposes them: `å` matches `a`, `é` matches `e`. `æ` and `ø`
    /// do not decompose, so they stay letters of their own — "ærø" finds
    /// Ærø, "aero" does not, which is how a Danish user types it anyway.
    ///
    /// Marks (`M*`) count as letters. By default they are separators, and a
    /// name stored decomposed — `a` and a combining ring — would split
    /// "Skatteårsopgørelse" in two at the `å`.
    static let tokenizer = "porter unicode61 remove_diacritics 2 categories 'L* N* Co M*'"

    static func create(in db: SQLiteConnection) throws {
        try db.execute("""
            CREATE TABLE files(
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                source TEXT NOT NULL,                    -- the folder Source the file is in
                kind TEXT NOT NULL,                      -- file | folder | package
                size INTEGER NOT NULL,
                mtime REAL NOT NULL,
                inode INTEGER NOT NULL,
                device INTEGER NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending',   -- contents: pending until a later layer reads them
                detail TEXT,
                indexed_at REAL
            );
            CREATE INDEX files_inode ON files(device, inode);
            CREATE INDEX files_source ON files(source, state);
            -- One row per file, rowid = files.id. The name is weighted over the folder (bm25 3:1).
            CREATE VIRTUAL TABLE names USING fts5(name, folder, tokenize = "\(tokenizer)", prefix = '1 2 3');
            -- Passages: what a file says, shows or sounds like. Unused until contents are read.
            CREATE TABLE segments(
                id INTEGER PRIMARY KEY,
                file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,                      -- page | chunk | ocr | transcript | frame
                loc REAL,                                -- PDF page, or start second
                loc_end REAL,
                excerpt TEXT,
                vec BLOB                                 -- 768 × float16
            );
            CREATE INDEX segments_file ON segments(file);
            CREATE VIRTUAL TABLE passages USING fts5(body, tokenize = "\(tokenizer)");
            -- What a launch needs to catch up by replaying FSEvents instead of crawling:
            -- 'event_id', 'rules' (FileIndexRules.fingerprint), and 'root:<path>' = volume UUID.
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
            PRAGMA user_version = \(version);
            """)
    }

    static func drop(in db: SQLiteConnection) throws {
        try db.execute("""
            DROP TABLE IF EXISTS meta;
            DROP TABLE IF EXISTS passages;
            DROP TABLE IF EXISTS segments;
            DROP TABLE IF EXISTS names;
            DROP TABLE IF EXISTS files;
            """)
    }

    /// The name as keyword search sees it: as written, plus its camel-case
    /// and letter–digit runs as words of their own, so "invoice" finds
    /// `MyInvoice2024.pdf`.
    static func nameText(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
        var split = ""
        var previous: Character?
        for character in name {
            if let previous,
               (previous.isLowercase && character.isUppercase)
                || (previous.isLetter && character.isNumber)
                || (previous.isNumber && character.isLetter) {
                split.append(" ")
            }
            split.append(character)
            previous = character
        }
        return split == name ? name : name + " " + split
    }

    /// The folders a file sits in, relative to the home folder, as low-weight
    /// words: `~/Documents/Skat/2024/x.pdf` is "Documents Skat 2024".
    static func folderText(_ path: String, home: String = NSHomeDirectory()) -> String {
        var folder = (path as NSString).deletingLastPathComponent
        if folder.hasPrefix(home + "/") { folder = String(folder.dropFirst(home.count)) }
        return folder.split(separator: "/").joined(separator: " ").precomposedStringWithCanonicalMapping
    }
}

/// One file as the index records it.
nonisolated struct FileIndexRow: Equatable, Sendable {
    enum Kind: String, Sendable { case file, folder, package }

    var id: Int64 = 0
    var path: String
    var source: String
    var kind: Kind
    var size: Int64
    var mtime: Double
    var inode: UInt64
    var device: UInt64

    /// Same file as far as a move is concerned: the identity and version a
    /// rename keeps.
    func isSameVersion(as other: FileIndexRow) -> Bool {
        device == other.device && inode == other.inode && size == other.size && abs(mtime - other.mtime) < 0.001
    }
}

// MARK: - Writer

/// The one connection that writes. Not thread-safe: its owner keeps it on one
/// queue (or, later, in one process).
nonisolated final class FileIndexWriter {
    let db: SQLiteConnection

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteConnection(path: url.path)
        try migrate()
    }

    private func migrate() throws {
        let dropped = try db.transaction {
            var version: Int64 = 0
            try db.query("PRAGMA user_version") { version = $0.int(0) }
            guard version != FileIndexSchema.version else { return false }
            if version != 0 { try FileIndexSchema.drop(in: db) }
            try FileIndexSchema.create(in: db)
            return version != 0
        }
        // Hands back the pages the old rows held. Cheap: the tables are empty.
        if dropped { try? db.execute("VACUUM") }
    }

    private static let columns = "id, path, source, kind, size, mtime, inode, device"

    private static func row(_ statement: SQLiteStatement) -> FileIndexRow {
        FileIndexRow(
            id: statement.int(0),
            path: statement.text(1) ?? "",
            source: statement.text(2) ?? "",
            kind: FileIndexRow.Kind(rawValue: statement.text(3) ?? "") ?? .file,
            size: statement.int(4),
            mtime: statement.double(5),
            inode: UInt64(bitPattern: statement.int(6)),
            device: UInt64(bitPattern: statement.int(7))
        )
    }

    func row(atPath path: String) throws -> FileIndexRow? {
        var found: FileIndexRow?
        try db.query("SELECT \(Self.columns) FROM files WHERE path = ?", [.text(path)]) { found = Self.row($0) }
        return found
    }

    /// The row at `path` and every row inside it.
    func rows(inTree path: String) throws -> [FileIndexRow] {
        var rows: [FileIndexRow] = []
        let (low, high) = Self.treeRange(path)
        try db.query("SELECT \(Self.columns) FROM files WHERE path = ? OR (path >= ? AND path < ?)",
                     [.text(path), .text(low), .text(high)]) { rows.append(Self.row($0)) }
        return rows
    }

    func rows(device: UInt64, inode: UInt64) throws -> [FileIndexRow] {
        var rows: [FileIndexRow] = []
        try db.query("SELECT \(Self.columns) FROM files WHERE device = ? AND inode = ?",
                     [.int(Int64(bitPattern: device)), .int(Int64(bitPattern: inode))]) { rows.append(Self.row($0)) }
        return rows
    }

    func insert(_ row: FileIndexRow) throws {
        try db.run("""
            INSERT INTO files(path, source, kind, size, mtime, inode, device) VALUES(?, ?, ?, ?, ?, ?, ?)
            """, [.text(row.path), .text(row.source), .text(row.kind.rawValue), .int(row.size), .double(row.mtime),
                  .int(Int64(bitPattern: row.inode)), .int(Int64(bitPattern: row.device))])
        try db.run("INSERT INTO names(rowid, name, folder) VALUES(?, ?, ?)",
                   [.int(db.lastInsertID), .text(FileIndexSchema.nameText(row.path)),
                    .text(FileIndexSchema.folderText(row.path))])
    }

    /// The file at a known path changed on disk. Its contents are read again.
    func update(_ id: Int64, to row: FileIndexRow) throws {
        try db.run("""
            UPDATE files SET source = ?, kind = ?, size = ?, mtime = ?, inode = ?, device = ?,
                state = 'pending', detail = NULL, indexed_at = NULL WHERE id = ?
            """, [.text(row.source), .text(row.kind.rawValue), .int(row.size), .double(row.mtime),
                  .int(Int64(bitPattern: row.inode)), .int(Int64(bitPattern: row.device)), .int(id)])
    }

    /// Same file at a new path: a move or a rename. Only the path changes, so
    /// whatever was read from the file stays.
    func move(_ id: Int64, to path: String, source: String) throws {
        try db.run("UPDATE files SET path = ?, source = ? WHERE id = ?", [.text(path), .text(source), .int(id)])
        try db.run("UPDATE names SET name = ?, folder = ? WHERE rowid = ?",
                   [.text(FileIndexSchema.nameText(path)), .text(FileIndexSchema.folderText(path)), .int(id)])
    }

    /// A folder moved: it and everything inside it take the new path, in one
    /// pass over the rows rather than a delete and a crawl.
    func moveTree(from old: String, to new: String, source: String) throws {
        for row in try rows(inTree: old) {
            try move(row.id, to: new + row.path.dropFirst(old.count), source: source)
        }
    }

    func delete(_ id: Int64) throws {
        try db.run("DELETE FROM names WHERE rowid = ?", [.int(id)])
        try db.run("DELETE FROM passages WHERE rowid IN (SELECT id FROM segments WHERE file = ?)", [.int(id)])
        try db.run("DELETE FROM files WHERE id = ?", [.int(id)])
    }

    /// The row at `path` and every row inside it, or with `keepingRoot` only
    /// what is inside; with `source`, only the rows that Source owns, so a
    /// nested Source survives. Returns how many went. One statement per
    /// table, not three per row: a folder switched out can be a quarter of a
    /// million rows.
    @discardableResult
    func deleteTree(_ path: String, keepingRoot: Bool = false, source: String? = nil) throws -> Int {
        let (low, high) = Self.treeRange(path)
        var tree = keepingRoot ? "(path >= ? AND path < ?)" : "(path = ? OR (path >= ? AND path < ?))"
        var values: [SQLiteValue] = keepingRoot ? [.text(low), .text(high)] : [.text(path), .text(low), .text(high)]
        if let source {
            tree += " AND source = ?"
            values.append(.text(source))
        }
        try db.run("DELETE FROM names WHERE rowid IN (SELECT id FROM files WHERE \(tree))", values)
        try db.run("""
            DELETE FROM passages WHERE rowid IN
                (SELECT segments.id FROM segments JOIN files ON segments.file = files.id WHERE \(tree))
            """, values)
        try db.run("DELETE FROM files WHERE \(tree)", values)
        return db.changes
    }

    /// Every row a folder Source owns. Returns how many went.
    @discardableResult
    func deleteSource(_ source: String) throws -> Int {
        var ids: [Int64] = []
        try db.query("SELECT id FROM files WHERE source = ?", [.text(source)]) { ids.append($0.int(0)) }
        for id in ids { try delete(id) }
        return ids.count
    }

    /// The distinct Sources that own rows.
    func sources() throws -> Set<String> {
        var sources = Set<String>()
        try db.query("SELECT DISTINCT source FROM files") { sources.insert($0.text(0) ?? "") }
        return sources
    }

    // MARK: Catch-up

    /// The FSEvents event the index has caught up to: every change before it
    /// is in the rows of every caught-up root. Nil until the index was first
    /// watched.
    func eventID() throws -> UInt64? {
        try meta("event_id").flatMap(UInt64.init)
    }

    func setEventID(_ id: UInt64) throws {
        try setMeta("event_id", String(id))
    }

    /// `FileIndexRules.fingerprint` of the rules the rows were read under.
    func rulesFingerprint() throws -> String? {
        try meta("rules")
    }

    func setRulesFingerprint(_ fingerprint: String) throws {
        try setMeta("rules", fingerprint)
    }

    /// The roots whose rows are whole up to `eventID`, each with the FSEvents
    /// volume UUID it was read on.
    func caughtUpRoots() throws -> [String: String] {
        var roots: [String: String] = [:]
        try db.query("SELECT key, value FROM meta WHERE key >= 'root:' AND key < 'root;'") { row in
            roots[String((row.text(0) ?? "").dropFirst("root:".count))] = row.text(1) ?? ""
        }
        return roots
    }

    /// Notes `root` as whole on `volume`, or with nil, as needing a crawl.
    func setCaughtUp(_ root: String, volume: String?) throws {
        if let volume {
            try setMeta("root:" + root, volume)
        } else {
            try db.run("DELETE FROM meta WHERE key = ?", [.text("root:" + root)])
        }
    }

    /// Every root needs a crawl again, except those in `keeping`.
    func forgetCaughtUpRoots(keeping: Set<String> = []) throws {
        for root in try caughtUpRoots().keys where !keeping.contains(root) {
            try setCaughtUp(root, volume: nil)
        }
    }

    private func meta(_ key: String) throws -> String? {
        var value: String?
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { value = $0.text(0) }
        return value
    }

    private func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(key), .text(value)])
    }

    /// Everything strictly inside `path`, as a range on the UNIQUE path index.
    static func treeRange(_ path: String) -> (String, String) {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return (prefix, prefix + "\u{10FFFF}")
    }
}

// MARK: - Reader

/// A file the File Index matched by name: what a File Result or a Finder
/// Target is built from.
nonisolated struct FileHit: Hashable, Sendable {
    let url: URL
    let name: String
    /// The folder it is in, home abbreviated: `~/Documents/Skat`.
    let folder: String
    let kind: FileIndexRow.Kind
    /// On `fuzzyScore`'s scale — lower is better — so a File Result ranks
    /// against the app's other searches. A match on the folder alone, where
    /// the name has nothing to show for it, is `folderOnlyScore`.
    let score: Int

    static let folderOnlyScore = 200

    var contentType: UTType {
        switch kind {
        case .folder: .folder
        case .file, .package: UTType(filenameExtension: url.pathExtension) ?? (kind == .package ? .package : .data)
        }
    }
}

/// A read-only connection to the File Index, safe from any thread: the main
/// thread's search path and a background queue can share one.
///
/// The database may not exist yet, or have no tables yet, when a reader
/// first asks — the writer creates them. Every query then answers empty and
/// tries again next time.
nonisolated final class FileIndexReader: @unchecked Sendable {
    /// How many keyword matches bm25 ranks. Ranking costs per match, and a
    /// short prefix matches nearly everything — "a*" is most of the index,
    /// "png*" every PNG — so ranking all of them grew with the index (12 ms
    /// for "a" at 22,000 files). Capped, a search costs the same at any size.
    /// Past the cap the ranked set is an arbitrary slice of the matches, which
    /// is why names that *begin* with the Query are fetched on their own.
    static let rankingCap = 2000

    /// How many of the ranked matches are re-scored by name, and how many
    /// names beginning with the Query join them. `fuzzyScore` decides.
    static let candidateLimit = 200

    private let url: URL
    private let home: String
    private let lock = NSLock()
    private var db: SQLiteConnection?
    private var statements: Statements?

    init(url: URL, home: String = NSHomeDirectory()) {
        self.url = url
        self.home = home
    }

    /// The statements before the connection they belong to — see
    /// `SQLiteConnection.deinit`.
    deinit {
        statements = nil
    }

    /// Files whose name — or failing that, folder — has every word of
    /// `query`, the last one as a prefix, best first. Only files in `sources`
    /// (folder Source paths) are returned.
    func search(_ query: String, limit: Int, sources: [String]) -> [FileHit] {
        let words = Self.words(query)
        guard !words.isEmpty, !sources.isEmpty, limit > 0 else { return [] }
        let sourceList = (try? JSONSerialization.data(withJSONObject: sources))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        var candidates: [String: (kind: FileIndexRow.Kind, order: Int)] = [:]
        lock.withLock {
            guard let statements = prepared() else { return }
            func collect(_ statement: SQLiteStatement, _ match: String) {
                try? statement.run([.text(match), .text(sourceList), .int(Int64(Self.candidateLimit))]) { row in
                    let path = row.text(0) ?? ""
                    guard candidates[path] == nil else { return }
                    let kind = FileIndexRow.Kind(rawValue: row.text(1) ?? "") ?? .file
                    candidates[path] = (kind, candidates.count)
                }
            }
            collect(statements.ranked, Self.matchExpression(words))
            if words.count == 1 { collect(statements.unranked, Self.namePrefixExpression(words[0])) }
        }

        // Scored by name, and only the survivors become hits: a `URL` each
        // for four hundred candidates was a third of a search.
        let foldedQuery = Self.fold(query)
        return candidates
            .map { path, candidate in
                let name = (path as NSString).lastPathComponent
                let score = fuzzyScore(Self.fold(name), foldedQuery) ?? FileHit.folderOnlyScore
                return (path: path, kind: candidate.kind, score: score, order: candidate.order)
            }
            .sorted { ($0.score, $0.order) < ($1.score, $1.order) }
            .prefix(limit)
            .map { hit(path: $0.path, kind: $0.kind, score: $0.score) }
    }

    /// The indexed file at exactly `path`, if there is one.
    func file(atPath path: String) -> FileHit? {
        lock.withLock {
            guard let db = connection() else { return nil }
            var found: FileHit?
            try? db.query("SELECT kind FROM files WHERE path = ?", [.text(path)]) { row in
                found = hit(path: path, kind: FileIndexRow.Kind(rawValue: row.text(0) ?? "") ?? .file, score: 0)
            }
            return found
        }
    }

    /// How many files each folder Source has in the index.
    func counts() -> [String: Int] {
        lock.withLock {
            guard let db = connection() else { return [:] }
            var counts: [String: Int] = [:]
            try? db.query("SELECT source, COUNT(*) FROM files GROUP BY source") { row in
                counts[row.text(0) ?? ""] = Int(row.int(1))
            }
            return counts
        }
    }

    private func hit(path: String, kind: FileIndexRow.Kind, score: Int) -> FileHit {
        let folder = (path as NSString).deletingLastPathComponent
        return FileHit(
            url: URL(fileURLWithPath: path, isDirectory: kind != .file),
            name: (path as NSString).lastPathComponent,
            folder: folder == home || folder.hasPrefix(home + "/") ? "~" + folder.dropFirst(home.count) : folder,
            kind: kind,
            score: score
        )
    }

    // MARK: Query text

    /// The Query's words as the tokenizer will see them.
    static func words(_ query: String) -> [String] {
        query.precomposedStringWithCanonicalMapping.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Every word quoted, all of them required, the last a prefix because it
    /// is still being typed.
    static func matchExpression(_ words: [String]) -> String {
        words.enumerated().map { index, word in
            "\"\(word)\"" + (index == words.count - 1 ? "*" : "")
        }.joined(separator: " ")
    }

    /// Names whose first word begins with `word`: `fuzzyScore`'s prefix tier.
    static func namePrefixExpression(_ word: String) -> String {
        "{name} : ^\"\(word)\"*"
    }

    /// Case and diacritics folded the way the tokenizer folds them, so the
    /// re-score agrees with the match: `å` → `a`, `ø` stays `ø`.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: Connection

    /// Called with the lock held.
    private func connection() -> SQLiteConnection? {
        if let db { return db }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        db = try? SQLiteConnection(path: url.path)
        try? db?.execute("PRAGMA query_only = 1")
        return db
    }

    private struct Statements {
        let ranked: SQLiteStatement
        let unranked: SQLiteStatement
    }

    /// Called with the lock held. Prepared once; preparing fails until the
    /// writer has created the tables, and is tried again next time.
    private func prepared() -> Statements? {
        if let statements { return statements }
        guard let db = connection(),
              let ranked = try? db.prepare("""
                SELECT f.path, f.kind FROM (
                    SELECT names.rowid AS id, bm25(names, 3.0, 1.0) AS rank
                    FROM names JOIN files f ON f.id = names.rowid
                    WHERE names MATCH ?1 AND f.source IN (SELECT value FROM json_each(?2))
                    LIMIT \(Self.rankingCap)
                ) matched JOIN files f ON f.id = matched.id
                ORDER BY matched.rank LIMIT ?3
                """),
              let unranked = try? db.prepare("""
                SELECT f.path, f.kind FROM names JOIN files f ON f.id = names.rowid
                WHERE names MATCH ?1 AND f.source IN (SELECT value FROM json_each(?2))
                LIMIT ?3
                """)
        else { return nil }
        statements = Statements(ranked: ranked, unranked: unranked)
        return statements
    }
}
