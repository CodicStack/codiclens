// Schema and name/folder search text adapted from DigUp's IndexStore.swift (https://github.com/ARahim3/DigUp),
// MIT licence — see docs/licenses/digup/LICENSE.
import Foundation
import UniformTypeIdentifiers

/// The File Index on disk: one SQLite file, written by one `FileIndexWriter`
/// and read by any number of `FileIndexReader`s on connections of their own.
///
/// Nothing a reader does depends on the writer being in this process. Today
/// the writer runs on `FileIndex`'s queue; the plan is a helper process that
/// does the writing and the reading of contents, and the database is the only
/// thing the two sides share.
nonisolated enum FileIndexSchema {
    /// An index from any other version is dropped and read again, never
    /// migrated: everything in it comes from the disk, and its vectors from
    /// `VectorCache`, which the drop leaves alone.
    static let version: Int64 = 5

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
                content INTEGER,                         -- FileContent: what is read from it, in reading order; NULL: nothing
                state TEXT NOT NULL DEFAULT 'pending',   -- contents: pending | partial (first step read) | done
                read_to INTEGER NOT NULL DEFAULT 0,      -- pages or chunks read so far
                detail TEXT,                             -- why nothing, or not everything, was read
                indexed_at REAL,
                vec_state TEXT NOT NULL DEFAULT 'done',  -- meaning: pending | partial (first step embedded) | done
                vec_to REAL NOT NULL DEFAULT 0           -- how far: PDF pages, or seconds of a recording or video
            );
            CREATE INDEX files_inode ON files(device, inode);
            CREATE INDEX files_source ON files(source, state);
            -- The background pass's order: unread first, by kind, newest first.
            CREATE INDEX files_reading ON files(state, content, mtime DESC);
            -- The meaning pass's order, the same way.
            CREATE INDEX files_meaning ON files(vec_state, content, mtime DESC);
            -- One row per file, rowid = files.id. The name is weighted over the folder (bm25 3:1).
            CREATE VIRTUAL TABLE names USING fts5(name, folder, tokenize = "\(tokenizer)", prefix = '1 2 3');
            -- Passages: what a file says, shows or sounds like. A Passage's words are in
            -- `passages` (rowid = segments.id); `excerpt` is for one with no words of its own.
            CREATE TABLE segments(
                id INTEGER PRIMARY KEY,
                file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,                      -- FilePassage.Kind: chunk | page | ocr | image | page_image | frame | audio
                loc REAL,                                -- PDF page, chunk offset (UTF-16), or start second
                loc_end REAL,                            -- end second
                excerpt TEXT,
                vec_key BLOB,                            -- its vector's VectorCache.Key; the vector is in VectorCache.sqlite
                later INTEGER NOT NULL DEFAULT 0         -- embedded after a long file's first step: scored, not in the scale
            );
            CREATE INDEX segments_file ON segments(file);
            CREATE VIRTUAL TABLE passages USING fts5(body, tokenize = "\(tokenizer)");
            -- What a launch needs to catch up by replaying FSEvents instead of crawling:
            -- 'event_id', 'rules' (FileIndexRules.fingerprint), and 'root:<path>' = FSEvents volume UUID.
            -- 'device:<path>' = '<volume UUID>|<st_dev>': the volume a root's rows were read on,
            -- so a restart that renumbers it keeps them (FileIndexer.adoptVolume).
            -- Search by meaning's: 'meaning' (MeaningPass.fingerprint, what the vectors were
            -- made with), 'vector_cache' (VectorCache.id, the cache the keys point into) and
            -- 'vector_rows' (rows the vector file should hold, `MeaningVectors`).
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
    /// What is read from it besides its name, if anything.
    var content: FileContent?

    /// Same file as far as a move is concerned: the identity and version a
    /// rename keeps.
    func isSameVersion(as other: FileIndexRow) -> Bool {
        device == other.device && inode == other.inode && size == other.size && abs(mtime - other.mtime) < 0.001
    }
}

/// The volume a folder Source is on: its UUID, which a restart keeps, and the
/// device number (`st_dev`) its rows record, which a restart may change.
nonisolated struct FileIndexVolume: Equatable, Sendable {
    var uuid: String
    var device: UInt64
}

// MARK: - Writer

/// The one connection that writes. Not thread-safe: its owner keeps it on one
/// queue (or, later, in one process).
nonisolated final class FileIndexWriter {
    let db: SQLiteConnection
    /// The index was made here, new or after a drop: it is being read from
    /// the disk again, and the vector cache is not pruned this session
    /// (`VectorCache.pruneIfCaughtUp`).
    private(set) var isNew = false

    /// Opens or makes the index at `url`. One of another version is dropped;
    /// with `cache`, the vectors it holds go there first
    /// (`VectorCache.seed(fromIndex:)`), so the drop costs no embedding.
    init(url: URL, cache: VectorCache? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteConnection(path: url.path)
        try migrate(seeding: cache)
    }

    private func migrate(seeding cache: VectorCache?) throws {
        var version: Int64 = 0
        try db.query("PRAGMA user_version") { version = $0.int(0) }
        if version != 0, version != FileIndexSchema.version, let cache {
            let seeding = try cache.seed(fromIndex: db)
            NSLog("File Index: schema %lld → %lld, %ld text and %ld media vectors kept in the cache, %ld stale",
                  version, FileIndexSchema.version, seeding.texts, seeding.media, seeding.stale)
        }
        let dropped = try db.transaction {
            var version: Int64 = 0
            try db.query("PRAGMA user_version") { version = $0.int(0) }
            guard version != FileIndexSchema.version else { return false }
            if version != 0 { try FileIndexSchema.drop(in: db) }
            try FileIndexSchema.create(in: db)
            isNew = true
            return version != 0
        }
        // Hands back the pages the old rows held. Cheap: the tables are empty.
        if dropped { try? db.execute("VACUUM") }
    }

    private static let columns = "id, path, source, kind, size, mtime, inode, device, content"

    private static func row(_ statement: SQLiteStatement) -> FileIndexRow {
        FileIndexRow(
            id: statement.int(0),
            path: statement.text(1) ?? "",
            source: statement.text(2) ?? "",
            kind: FileIndexRow.Kind(rawValue: statement.text(3) ?? "") ?? .file,
            size: statement.int(4),
            mtime: statement.double(5),
            inode: UInt64(bitPattern: statement.int(6)),
            device: UInt64(bitPattern: statement.int(7)),
            content: statement.isNull(8) ? nil : FileContent(rawValue: Int(statement.int(8)))
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

    /// A new row, with its contents waiting to be read — or, with no words
    /// in it, already as read as it will be — and, with anything in it at
    /// all, waiting for its vectors. Returns its id.
    @discardableResult
    func insert(_ row: FileIndexRow) throws -> Int64 {
        try db.run("""
            INSERT INTO files(path, source, kind, size, mtime, inode, device, content, state, vec_state)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(row.path), .text(row.source), .text(row.kind.rawValue), .int(row.size), .double(row.mtime),
                  .int(Int64(bitPattern: row.inode)), .int(Int64(bitPattern: row.device)), Self.content(row),
                  .text(Self.contentState(row)), .text(row.content == nil ? "done" : "pending")])
        let id = db.lastInsertID
        try db.run("INSERT INTO names(rowid, name, folder) VALUES(?, ?, ?)",
                   [.int(id), .text(FileIndexSchema.nameText(row.path)),
                    .text(FileIndexSchema.folderText(row.path))])
        return id
    }

    /// The file at a known path changed on disk: its Passages go and its
    /// contents are read again. With `keepingContents` — only its Source
    /// changed, as when a Source is added inside another — they stay.
    func update(_ id: Int64, to row: FileIndexRow, keepingContents: Bool = false) throws {
        guard !keepingContents else {
            try db.run("UPDATE files SET source = ? WHERE id = ?", [.text(row.source), .int(id)])
            return
        }
        try deletePassages(ofFile: id)
        try db.run("""
            UPDATE files SET source = ?, kind = ?, size = ?, mtime = ?, inode = ?, device = ?, content = ?,
                state = ?, read_to = 0, detail = NULL, indexed_at = NULL, vec_state = ?, vec_to = 0 WHERE id = ?
            """, [.text(row.source), .text(row.kind.rawValue), .int(row.size), .double(row.mtime),
                  .int(Int64(bitPattern: row.inode)), .int(Int64(bitPattern: row.device)), Self.content(row),
                  .text(Self.contentState(row)), .text(row.content == nil ? "done" : "pending"), .int(id)])
        onVectorsRemoved?([id])
    }

    private static func content(_ row: FileIndexRow) -> SQLiteValue {
        row.content.map { .int(Int64($0.rawValue)) } ?? .null
    }

    /// Pending for the contents pass only where there are words to read.
    private static func contentState(_ row: FileIndexRow) -> String {
        row.content?.hasWords == true ? "pending" : "done"
    }

    /// Told the files whose vectors just went with their rows or Passages,
    /// so the vectors search scores (`MeaningVectors`) can drop them too.
    /// Called on the writer's queue, inside its transaction.
    var onVectorsRemoved: (([Int64]) -> Void)?

    private func deletePassages(ofFile id: Int64) throws {
        try db.run("DELETE FROM passages WHERE rowid IN (SELECT id FROM segments WHERE file = ?)", [.int(id)])
        try db.run("DELETE FROM segments WHERE file = ?", [.int(id)])
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

    /// The row, its name and its Passages; the segments go by cascade.
    func delete(_ id: Int64) throws {
        try db.run("DELETE FROM names WHERE rowid = ?", [.int(id)])
        try db.run("DELETE FROM passages WHERE rowid IN (SELECT id FROM segments WHERE file = ?)", [.int(id)])
        try db.run("DELETE FROM files WHERE id = ?", [.int(id)])
        onVectorsRemoved?([id])
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
            // `+`: not by `files_source`. Without statistics SQLite picks that
            // index for the equality and walks the whole Source per call,
            // which made a prune deleting row by row take ten minutes.
            tree += " AND +source = ?"
            values.append(.text(source))
        }
        if let onVectorsRemoved {
            var files: [Int64] = []
            try db.query("""
                SELECT DISTINCT s.file FROM files JOIN segments s ON s.file = files.id
                WHERE \(tree) AND s.vec_key IS NOT NULL
                """, values) { files.append($0.int(0)) }
            if !files.isEmpty { onVectorsRemoved(files) }
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

    // MARK: Contents

    private static let jobColumns = "id, path, content, size, mtime, read_to"

    private static func job(_ statement: SQLiteStatement) -> FileContentJob? {
        guard let content = FileContent(rawValue: Int(statement.int(2))) else { return nil }
        return FileContentJob(id: statement.int(0), path: statement.text(1) ?? "", content: content,
                              size: statement.int(3), mtime: statement.double(4), readTo: Int(statement.int(5)))
    }

    /// The next files of the background pass in `sources`: every file's first
    /// step before any file's later ones, and within each by `FileContent`'s
    /// order, newest first.
    func contentJobs(limit: Int, sources: [String]) throws -> [FileContentJob] {
        var jobs: [FileContentJob] = []
        let list = FileIndexReader.jsonList(sources)
        for state in ["pending", "partial"] where jobs.count < limit {
            try db.query("""
                SELECT \(Self.jobColumns) FROM files
                WHERE state = ? AND content IS NOT NULL AND source IN (SELECT value FROM json_each(?))
                ORDER BY content, mtime DESC LIMIT ?
                """, [.text(state), .text(list), .int(Int64(limit - jobs.count))]) { row in
                if let job = Self.job(row) { jobs.append(job) }
            }
        }
        return jobs
    }

    /// The files among `ids` that still have contents to read.
    func contentJobs(ids: [Int64]) throws -> [FileContentJob] {
        var jobs: [FileContentJob] = []
        for id in ids {
            try db.query("""
                SELECT \(Self.jobColumns) FROM files WHERE id = ? AND state != 'done' AND content IS NOT NULL
                """, [.int(id)]) { row in
                if let job = Self.job(row) { jobs.append(job) }
            }
        }
        return jobs
    }

    /// Stores what reading a file came to, if the file is still the one that
    /// was read: same size and date, and no other step stored meanwhile.
    /// Otherwise the result is dropped — the file is waiting to be read again,
    /// or is gone. Returns whether it was stored.
    @discardableResult
    func storeContents(_ result: FileContentResult) throws -> Bool {
        let job = result.job
        var isCurrent = false
        try db.query("SELECT size, mtime, read_to, state FROM files WHERE id = ?", [.int(job.id)]) { row in
            isCurrent = row.int(0) == job.size && abs(row.double(1) - job.mtime) < 0.001
                && Int(row.int(2)) == job.readTo && row.text(3) != "done"
        }
        guard isCurrent else { return false }
        if job.readTo == 0 { try deletePassages(ofFile: job.id) }
        for passage in result.passages {
            try db.run("INSERT INTO segments(file, kind, loc) VALUES(?, ?, ?)",
                       [.int(job.id), .text(passage.kind.rawValue), passage.location.map { .double($0) } ?? .null])
            try db.run("INSERT INTO passages(rowid, body) VALUES(?, ?)", [.int(db.lastInsertID), .text(passage.text)])
        }
        try db.run("""
            UPDATE files SET state = ?, read_to = ?, detail = ?, indexed_at = ? WHERE id = ?
            """, [.text(result.isComplete ? "done" : "partial"), .int(Int64(result.readTo)),
                  result.detail.map { .text($0) } ?? .null, .double(Date().timeIntervalSince1970), .int(job.id)])
        // The meaning pass embeds what this read: a later step of a file it
        // had finished gives it more — not a data file's or a log's, whose
        // later Passages get no vectors (`FileContent.isDataOrLog`) — and a
        // file with no words and no pages to look at has nothing for it at all.
        let isMoreToEmbed = !result.passages.isEmpty && (job.readTo == 0 || !FileContent.isDataOrLog(job.path))
        if isMoreToEmbed || (job.content == .pdf && result.readTo > job.readTo) {
            try db.run("UPDATE files SET vec_state = 'partial' WHERE id = ? AND vec_state = 'done'", [.int(job.id)])
        } else if job.readTo == 0, result.isComplete, job.content != .pdf, job.content != .screenshot {
            try db.run("UPDATE files SET vec_state = 'done' WHERE id = ?", [.int(job.id)])
        }
        return true
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

    /// The volume `root`'s rows were read on, if it was noted.
    func volume(of root: String) throws -> FileIndexVolume? {
        guard let value = try meta("device:" + root),
              let bar = value.lastIndex(of: "|"),
              let device = UInt64(value[value.index(after: bar)...]) else { return nil }
        return FileIndexVolume(uuid: String(value[..<bar]), device: device)
    }

    func setVolume(_ volume: FileIndexVolume, of root: String) throws {
        try setMeta("device:" + root, volume.uuid + "|" + String(volume.device))
    }

    /// Forgets the volume of every root not in `keeping`: a Source no longer
    /// listed has no rows left to keep.
    func forgetVolumes(keeping: Set<String>) throws {
        var roots: [String] = []
        try db.query("SELECT key FROM meta WHERE key >= 'device:' AND key < 'device;'") { row in
            roots.append(String((row.text(0) ?? "").dropFirst("device:".count)))
        }
        for root in roots where !keeping.contains(root) {
            try db.run("DELETE FROM meta WHERE key = ?", [.text("device:" + root)])
        }
    }

    /// The rows `source` owns on device `old` say `new` instead: the same
    /// volume under the number a restart gave it. A volume of its own inside
    /// the Source has another number and keeps it. Returns how many changed.
    @discardableResult
    func renumberDevice(from old: UInt64, to new: UInt64, source: String) throws -> Int {
        try db.run("UPDATE files SET device = ? WHERE device = ? AND source = ?",
                   [.int(Int64(bitPattern: new)), .int(Int64(bitPattern: old)), .text(source)])
        return db.changes
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

/// A file the File Index matched, by its name or by what it says: what a
/// File Result or a Finder Target is built from.
nonisolated struct FileHit: Hashable, Sendable {
    /// The part of the file that matched (`GLOSSARY.md`, **Passage**), as a
    /// row shows it.
    struct Passage: Hashable, Sendable {
        /// A few words either side of the match, on one line. Empty for a
        /// page, a frame or a stretch of sound found by meaning: those have
        /// no words.
        let excerpt: String
        /// Where the Query's words are in `excerpt`, in characters.
        let matches: [Range<Int>]
        /// The PDF page it is on, from 1.
        let page: Int?
        /// In a recording or a video, the span it is, in seconds from the
        /// start: what the Card shows as "at 14:02" and plays from
        /// (`SubjectPassage.seconds`).
        var start: Double? = nil
        var end: Double? = nil
        /// What found it by meaning — its text, a picture of it, its sound —
        /// or nil when its words matched the Query's.
        var modality: MeaningModality? = nil

        /// The second line of a File Result found by what it says: the page
        /// or the moment where there is one, then the excerpt — "page 4 ·
        /// …the words…", "at 14:02".
        var subtitle: String {
            let place = page.map { "page \($0)" } ?? start.map { "at " + Self.clock($0) }
            guard let place else { return excerpt }
            return excerpt.isEmpty ? place : place + " · " + excerpt
        }

        /// `seconds` as a clock reads: 0:07, 14:02, 1:02:03.
        static func clock(_ seconds: Double) -> String {
            let total = max(0, Int(seconds.rounded(.down)))
            let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
            return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
        }

        /// `matches`, as places in `subtitle`.
        var subtitleMatches: [Range<Int>] {
            let shift = subtitle.count - excerpt.count
            return matches.map { ($0.lowerBound + shift)..<($0.upperBound + shift) }
        }
    }

    let url: URL
    let name: String
    /// The folder it is in, home abbreviated: `~/Documents/Skat`.
    let folder: String
    let kind: FileIndexRow.Kind
    /// On `fuzzyScore`'s scale — lower is better — so a File Result ranks
    /// against the app's other searches. A name that answers only what its
    /// folders leave of the Query ("code" in `Data Intensive Systems/code`)
    /// is a name match a little below one that answers all of it
    /// (`FileIndexReader.nameAfterFoldersPenalty`). A match on what the file
    /// says is `contentScore` and up, below every match on the name; a match
    /// on the folder alone, where neither the name nor the words have
    /// anything to show for it, is `folderOnlyScore`. In the settled pass the
    /// Kind a Kind Word asks for is `kindScore` and up, below zero, so it
    /// sits above every other name match and every Clipboard Item and Emoji
    /// (`FileIndexReader.fusedSearch`).
    var score: Int
    /// Set when the file is here for what it says. A file whose name matched
    /// has none, whatever its words do; nor does a picture found by meaning,
    /// which matched whole.
    var passage: Passage? = nil
    /// Set when the file is here because its meaning stood out for the Query
    /// (`MeaningRanking.zGate`): what found it.
    var meaning: MeaningModality? = nil

    static let contentScore = 120
    static let folderOnlyScore = 200
    /// Where the Kind block starts: −100 up to −51 for the fifty a list
    /// holds.
    static let kindScore = -100

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
    /// How many keyword matches bm25 ranks, in names and in Passages each.
    /// Ranking costs per match, and a short prefix matches nearly everything —
    /// "a*" is most of the index, "png*" every PNG — so ranking all of them
    /// grew with the index (12 ms for "a" at 22,000 files). Capped, a search
    /// costs the same at any size. Past the cap the ranked set is an arbitrary
    /// slice of the matches, which is why names that *begin* with the Query
    /// are fetched on their own.
    static let rankingCap = 2000

    /// How many of the ranked matches are re-scored by name, and how many
    /// names beginning with the Query join them. `fuzzyScore` decides.
    static let candidateLimit = 200

    /// How long the last word has to be before it is a prefix in Passages.
    /// Names have a prefix index and take any length; Passages have none — it
    /// would grow an already large database — and "a*" over 1.2 million of
    /// them cost 860 ms (7.8 ms as a whole word). A shorter last word matches
    /// whole words only.
    static let contentPrefixMinimum = 3

    /// How many words either side of a match an excerpt shows. A row has one
    /// line; it is cut at its end, and FTS5 centres the match.
    static let excerptWords = 10

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

    /// How the Query's last word is matched in Passages. Names always take
    /// it as a prefix: they have a prefix index.
    enum PassageMatch: Sendable {
        /// On the keystroke: whole words only. A prefix over Passages merges
        /// the posting list of every word that begins with it, and a common
        /// one ("con", "type", "202") cost 20–60 ms on the dev machine's 1.02
        /// million Passages before a single row came back.
        case wholeWords
        /// Once typing pauses: the last word as a prefix too, from
        /// `contentPrefixMinimum` letters, unless a space after it says it is
        /// finished. A function word last ("image of me") is finished, in
        /// names too, and not required (`requiredWords`).
        case lastWordPrefix
    }

    /// Files in `sources` (folder Source paths) whose name or folder, or one
    /// of whose Passages, has every word of `query` it requires
    /// (`requiredWords`: not "folder" or "for"), the last one as a prefix (in
    /// Passages only with `.lastWordPrefix`). Best first, one row per file; a
    /// file that matched on its words carries the best Passage that did.
    ///
    /// A name is scored against the whole Query, and failing that against
    /// what its folders leave of it, so "code folder for data intensive
    /// systems" finds `Data Intensive Systems/code` as a name match. Here a
    /// folder word in the Query wins a folder a tie, and nothing more; the
    /// settled pass puts the folders first (`fusedSearch`).
    func search(_ query: String, limit: Int, sources: [String], passages: PassageMatch = .wholeWords) -> [FileHit] {
        lock.withLock { searchLocked(query, limit: limit, sources: sources, passages: passages) }
    }

    /// `search`, called with the lock held. `foldersFirst`: the folders a
    /// folder word puts first (`leadingFolders`) rank ahead of everything
    /// else, and `kindsFirst`: so do the files of the Kinds a Kind Word asks
    /// for, so the limit keeps them — sixty notes that say "invoice" had
    /// cut every PDF that does from "pdf invoice".
    private func searchLocked(_ query: String, limit: Int, sources: [String], passages: PassageMatch,
                              foldersFirst: Bool = false, kindsFirst: Set<FileContent> = []) -> [FileHit] {
        let allWords = Self.words(query)
        guard !allWords.isEmpty, !sources.isEmpty, limit > 0 else { return [] }
        let (words, endsOnLastWord) = Self.requiredWords(allWords, isSettled: passages == .lastWordPrefix)
        let sourceList = Self.jsonList(sources)
        let match = Self.matchExpression(words, prefixMinimum: endsOnLastWord ? 1 : .max)
        let isLastWordOpen = endsOnLastWord && passages == .lastWordPrefix && query.last?.isWhitespace != true
        let contentMatch = Self.matchExpression(words, prefixMinimum: isLastWordOpen ? Self.contentPrefixMinimum : .max)
        let foldedQuery = Self.fold(query)
        let foldedWords = words.map(Self.fold)
        let asksForFolder = allWords.contains(where: MeaningRanking.folderWords.contains)
        // Once typing pauses the words the search requires may be fewer than
        // the Query's (a Kind Word, "the"), and a name that answers them
        // answers what was asked of a name: `invoice.pdf` for "pdf invoice".
        let requiredQuery = passages == .lastWordPrefix && words.count < allWords.count
            ? foldedWords.joined(separator: " ") : nil
        let kindList = Self.jsonList(kindsFirst.map { String($0.rawValue) })

        do {
            guard let statements = prepared() else { return [] }
            var candidates: [String: Candidate] = [:]
            func collect(_ statement: SQLiteStatement, _ match: String) {
                try? statement.run([.text(match), .text(sourceList), .int(Int64(Self.candidateLimit))]) { row in
                    let path = row.text(0) ?? ""
                    guard candidates[path] == nil else { return }
                    candidates[path] = Candidate(kind: FileIndexRow.Kind(rawValue: row.text(1) ?? "") ?? .file,
                                                 content: row.isNull(2) ? nil : FileContent(rawValue: Int(row.int(2))),
                                                 score: 0, order: candidates.count)
                }
            }
            collect(statements.ranked, match)
            if allWords.count == 1 && endsOnLastWord {
                collect(statements.unranked, Self.namePrefixExpression(words[0]))
            }

            // Scored by name; a `URL` each only for the survivors, since one
            // for four hundred candidates was a third of a search. A name the
            // whole Query missed is scored on the required words, a step
            // below; a folder's words are split only for a name both missed.
            for path in Array(candidates.keys) {
                let name = Self.fold((path as NSString).lastPathComponent)
                candidates[path]?.score = fuzzyScore(name, foldedQuery)
                    ?? requiredQuery.flatMap { fuzzyScore(name, $0) }
                        .map { min($0 + Self.nameAfterFoldersPenalty, FileHit.contentScore - 1) }
                    ?? nameAfterFolders(name, path: path, words: foldedWords, of: allWords.count,
                                        isLastOpen: endsOnLastWord)
                    ?? FileHit.folderOnlyScore
            }

            // What files say, a row per file at its best Passage, ranked
            // below every name: DigUp weighs a name 3:1 over the words in
            // one bm25, and two tables cannot share one, so the name wins by
            // band instead.
            var rank = 0
            try? statements.passages.run([.text(contentMatch), .text(sourceList), .int(Int64(limit)),
                                          .text(kindList)]) { row in
                let path = row.text(0) ?? ""
                let score = FileHit.contentScore + min(rank, FileHit.folderOnlyScore - FileHit.contentScore - 1)
                rank += 1
                if let existing = candidates[path], existing.score <= score { return }
                candidates[path] = Candidate(
                    kind: FileIndexRow.Kind(rawValue: row.text(1) ?? "") ?? .file,
                    content: row.isNull(6) ? nil : FileContent(rawValue: Int(row.int(6))),
                    score: score,
                    order: candidates[path]?.order ?? candidates.count,
                    segment: row.int(2),
                    page: row.text(3) == FilePassage.Kind.page.rawValue && !row.isNull(4) ? Int(row.double(4)) : nil
                )
            }

            // "…folder…" settles a tie for a folder: a nudge, never a filter,
            // unless the folders are to come first.
            func nudge(_ candidate: Candidate) -> Int { asksForFolder && candidate.kind == .folder ? 0 : 1 }
            let leading = foldersFirst
                ? Self.leadingFolders(candidates.filter { $0.value.kind == .folder }.map(\.key), words: foldedWords,
                                      isLastOpen: endsOnLastWord)
                : []
            func ahead(_ path: String, _ candidate: Candidate) -> Int {
                leading.contains(path) || candidate.content.map(kindsFirst.contains) == true ? 0 : 1
            }
            return candidates
                .sorted {
                    (ahead($0.key, $0.value), $0.value.score, nudge($0.value), $0.value.order)
                        < (ahead($1.key, $1.value), $1.value.score, nudge($1.value), $1.value.order)
                }
                .prefix(limit)
                .map { path, candidate in
                    var hit = hit(path: path, kind: candidate.kind, score: candidate.score)
                    if let segment = candidate.segment {
                        hit.passage = passage(segment, page: candidate.page, words: words,
                                              match: contentMatch, statements: statements)
                    }
                    return hit
                }
        }
    }

    /// How well `name` answers what the folders in `path` leave of the
    /// Query's `words` (folded, required): "code" in `Data Intensive
    /// Systems/code` for "code data intensive systems", or "invoice" for "the
    /// invoice", whose "the" is not required. Nil when the folders leave
    /// nothing (a match on the folder alone), when the rest is every one of
    /// the Query's `queryWordCount` words (the whole Query, already asked),
    /// or when the name does not answer the rest either.
    private func nameAfterFolders(_ name: String, path: String, words: [String], of queryWordCount: Int,
                                  isLastOpen: Bool) -> Int? {
        let folders = Self.folderWords(path, home: home)
        let rest = words.enumerated().filter { index, word in
            !Self.covers(folders, word, isPrefix: isLastOpen && index == words.count - 1)
        }.map(\.element)
        guard !rest.isEmpty, rest.count < queryWordCount,
              let score = fuzzyScore(name, rest.joined(separator: " ")) else { return nil }
        return min(score + Self.nameAfterFoldersPenalty, FileHit.contentScore - 1)
    }

    /// What a name that answers only the rest of the Query gives up: enough
    /// that a name answering all of it the same way comes first. On
    /// `fuzzyScore`'s tiers, `Data Intensive Systems/code` (0 + 2) sits below
    /// a file called or beginning with "code data intensive systems" (0, 1)
    /// and above one with the Query further into its name (10 and up).
    static let nameAfterFoldersPenalty = 2

    // MARK: Words and meaning

    /// The settled pass's search: the word search with the last word a
    /// prefix, then fused with `meaning` as DigUp fuses them
    /// (`MeaningRanking`) — files that stand out by meaning join, files with
    /// most of the Query's words rise, and a Kind Word or a Kind Hint lifts
    /// its Kind — and the Kind a Kind Word asks for put first
    /// (`MeaningRanking`, 4). With `meaning` nil (search by meaning off, or no
    /// vectors yet) it is the word search, with the Kind first where it can
    /// be without vectors: the Kind's best guesses need them.
    ///
    /// **The scale it lands on** is the word search's, lower is better, so
    /// the list below the apps ranks it against Clipboard Items and Emoji
    /// (`SourceSearch`):
    ///
    /// - **The Kind block**, when a Kind Word asks for a Kind or a folder word
    ///   for folders: the Kind's name matches in their order, then the rest of
    ///   it — with a topic every candidate of the Kind by the fused score
    ///   (every gated file of it, not only the best 200 of every Kind), names
    ///   that matched the Kind Word alone among them, filled up to
    ///   `MeaningRanking.kindGuesses` with its best z below the gate; for a
    ///   kind-only Query its newest, the whole block at most
    ///   `MeaningRanking.kindOnlyFiles`; for folders, the folders the words
    ///   found by name, or by path below no other such folder
    ///   (`leadingFolders`). At `kindScore + rank` (−100 and up), below zero,
    ///   so above every other name match and every Clipboard Item and Emoji.
    /// - A file whose **name** matched keeps its `fuzzyScore` (0 to ~110) and
    ///   no Passage, as does one whose name answers what its folders leave of
    ///   the Query (`search`): a name match is still above every file found
    ///   by what it says or means.
    /// - Every other candidate — by its words (`contentScore` before), by
    ///   meaning or by both — is ordered by the fused score and placed at
    ///   `contentScore + rank` (120…199): the band content matches had, now
    ///   ordered by meaning and words together. Its words are counted in its
    ///   Passages, its name and its folders, the folders only beside at least
    ///   one word of its own.
    /// - A file found by its **folder** alone and by nothing else keeps
    ///   `folderOnlyScore` (200).
    func fusedSearch(_ query: String, limit: Int, sources: [String], meaning: MeaningScores?) -> [FileHit] {
        lock.withLock {
            let asked = MeaningRanking.askedKinds(query)
            let asksForFolders = MeaningRanking.asksForFolders(query)
            let wordHits = searchLocked(query, limit: limit, sources: sources, passages: .lastWordPrefix,
                                        foldersFirst: asksForFolders, kindsFirst: asked)
            // Nothing to fuse and no Kind to put first: the word search as it is.
            guard let db = connection(), !sources.isEmpty, limit > 0,
                  meaning != nil || !asked.isEmpty || asksForFolders else { return wordHits }
            let terms = MeaningRanking.terms(query)
            let lifted = MeaningRanking.liftedKinds(query)
            let isKindOnly = MeaningRanking.isKindOnly(query)
            let hasTopic = !asked.isEmpty && !isKindOnly
            let isLastOpen = query.last?.isWhitespace != true
            let sourceList = Self.jsonList(sources)
            let kindList = Self.jsonList(asked.map { String($0.rawValue) })

            // Every file in the running, by id: the word search's, the files
            // with any of the Query's words, and the files meaning found.
            var entries: [Int64: Fused] = [:]
            var wordFiles: [(id: Int64, hit: FileHit)] = []
            for (order, hit) in wordHits.enumerated() {
                var id: Int64?
                try? db.query("SELECT id FROM files WHERE path = ?", [.text(hit.url.path)]) { id = $0.int(0) }
                guard let id else { continue }
                wordFiles.append((id, hit))
                let isNameMatch = hit.passage == nil && hit.score < FileHit.folderOnlyScore
                entries[id] = Fused(order: order, hit: hit, isNameMatch: isNameMatch,
                                    coverage: hit.passage != nil ? 1 : nil)
            }
            if let meaning {
                if terms.count >= 2 {
                    let any = terms.enumerated().map { index, term in
                        "\"\(term)\"" + (index == terms.count - 1 && isLastOpen && term.count >= Self.contentPrefixMinimum ? "*" : "")
                    }.joined(separator: " OR ")
                    try? db.query("""
                        SELECT s.file, MIN(matched.rank) AS best FROM (
                            SELECT passages.rowid AS id, bm25(passages) AS rank
                            FROM passages JOIN segments s ON s.id = passages.rowid JOIN files f ON f.id = s.file
                            WHERE passages MATCH ?1 AND f.source IN (SELECT value FROM json_each(?2))
                            LIMIT \(Self.rankingCap)
                        ) matched JOIN segments s ON s.id = matched.id
                        GROUP BY s.file ORDER BY best LIMIT \(Self.anyWordFiles)
                        """, [.text(any), .text(sourceList)]) { row in
                        let id = row.int(0)
                        if entries[id] == nil { entries[id] = Fused(order: Int.max) }
                    }
                }
                for match in meaning.top where entries[match.file] == nil {
                    entries[match.file] = Fused(order: Int.max)
                }
                // Every gated file of the Kind a Kind Word asks for, however
                // far down: the best 200 of every Kind kept 3 of the 36
                // pictures that stood out for "image of me".
                let beyond = meaning.gated.dropFirst(MeaningRanking.meaningCandidates).map { String($0.file) }
                if hasTopic, !beyond.isEmpty {
                    try? db.query("""
                        SELECT id FROM files WHERE id IN (SELECT value FROM json_each(?1))
                            AND content IN (SELECT value FROM json_each(?2)) AND source IN (SELECT value FROM json_each(?3))
                        """, [.text(Self.jsonList(beyond)), .text(kindList), .text(sourceList)]) { row in
                        let id = row.int(0)
                        if entries[id] == nil { entries[id] = Fused(order: Int.max) }
                    }
                }
            }
            // A Query that is only a Kind: its newest files, which neither
            // its words nor its meaning would bring.
            var newest: [Int64] = []
            if isKindOnly {
                try? db.query("""
                    SELECT id FROM files WHERE content IN (SELECT value FROM json_each(?1))
                        AND source IN (SELECT value FROM json_each(?2))
                    ORDER BY mtime DESC LIMIT ?3
                    """, [.text(kindList), .text(sourceList), .int(Int64(MeaningRanking.kindOnlyFiles))]) { row in
                    let id = row.int(0)
                    newest.append(id)
                    if entries[id] == nil { entries[id] = Fused(order: Int.max) }
                }
            }

            // Where each one is and what it is; a file meaning found outside
            // the enabled Sources drops out here.
            var info: [Int64: FileInfo] = [:]
            func lookUp(_ ids: [Int64]) {
                try? db.query("""
                    SELECT id, path, kind, content, mtime FROM files
                    WHERE id IN (SELECT value FROM json_each(?1)) AND source IN (SELECT value FROM json_each(?2))
                    """, [.text(Self.jsonList(ids.map(String.init))), .text(sourceList)]) { row in
                    info[row.int(0)] = FileInfo(path: row.text(1) ?? "",
                                                kind: FileIndexRow.Kind(rawValue: row.text(2) ?? "") ?? .file,
                                                content: row.isNull(3) ? nil : FileContent(rawValue: Int(row.int(3))))
                }
            }
            lookUp(Array(entries.keys))
            entries = entries.filter { info[$0.key] != nil }

            // How many of the Query's words each has, in its Passages, its
            // name or its folders, where the word search did not already say
            // all of them. A folder's words complete a file's own and never
            // stand in for them: a file with none of the words itself
            // measures 0, as the word search leaves a folder-only match at
            // `folderOnlyScore`.
            func measure(_ unmeasured: [Int64]) {
                guard !unmeasured.isEmpty else { return }
                var found: [Int64: Int] = [:]
                var own = Set<Int64>()
                let files = Self.jsonList(unmeasured.map(String.init))
                let folders = Dictionary(uniqueKeysWithValues: unmeasured.map {
                    ($0, Self.folderWords(info[$0]?.path ?? "", home: home))
                })
                for (index, term) in terms.enumerated() {
                    let isPrefix = index == terms.count - 1 && isLastOpen && term.count >= Self.contentPrefixMinimum
                    let phrase = "\"\(term)\"" + (isPrefix ? "*" : "")
                    var has = Set<Int64>()
                    try? db.query("""
                        SELECT DISTINCT s.file FROM segments s WHERE s.file IN (SELECT value FROM json_each(?2))
                            AND s.id IN (SELECT rowid FROM passages WHERE passages MATCH ?1)
                        """, [.text(phrase), .text(files)]) { has.insert($0.int(0)) }
                    try? db.query("""
                        SELECT value FROM json_each(?2) WHERE value IN (SELECT rowid FROM names WHERE names MATCH ?1)
                        """, [.text("{name} : " + phrase), .text(files)]) { has.insert($0.int(0)) }
                    own.formUnion(has)
                    let folded = Self.fold(term)
                    for id in unmeasured where has.contains(id)
                        || Self.covers(folders[id] ?? [], folded, isPrefix: index == terms.count - 1 && isLastOpen) {
                        found[id, default: 0] += 1
                    }
                }
                for id in unmeasured {
                    let words = own.contains(id) ? found[id] ?? 0 : 0
                    entries[id]?.coverage = terms.isEmpty ? 0 : Double(words) / Double(terms.count)
                }
            }
            measure(entries.filter { $0.value.coverage == nil }.map(\.key))

            // The Kind block opens with the word search's name matches of the
            // Kind, in their order — with a topic, those whose name has a
            // word of it; for folders, the ones the folder word puts first
            // (`leadingFolders`) — and, for a kind-only Query, goes on with
            // the Kind's newest.
            func isAsked(_ id: Int64) -> Bool {
                guard let file = info[id] else { return false }
                return asksForFolders ? file.kind == .folder : file.content.map(asked.contains) ?? false
            }
            func namesTheTopic(_ id: Int64) -> Bool {
                let name = Self.words(((info[id]?.path ?? "") as NSString).lastPathComponent).map(Self.fold)
                return terms.enumerated().contains { index, term in
                    Self.covers(name, Self.fold(term), isPrefix: isLastOpen && index == terms.count - 1)
                }
            }
            var leading = Set<String>()
            if asksForFolders {
                let required = Self.requiredWords(Self.words(query), isSettled: true)
                leading = Self.leadingFolders(wordFiles.compactMap { info[$0.id]?.kind == .folder ? info[$0.id]?.path : nil },
                                              words: required.words.map(Self.fold), isLastOpen: required.endsOnLastWord)
            }
            var opening: [Int64] = []
            // "image of me": `image.png` matched the Kind Word and nothing of
            // the topic. It is in the block by its score, not ahead of it.
            var namedForTheKind: [Int64] = []
            for (id, _) in wordFiles where isAsked(id) {
                if asksForFolders {
                    if leading.contains(info[id]?.path ?? "") { opening.append(id) }
                } else if entries[id]?.isNameMatch == true {
                    if hasTopic && !namesTheTopic(id) { namedForTheKind.append(id) } else { opening.append(id) }
                }
            }
            if isKindOnly {
                opening += newest.filter { !opening.contains($0) && info[$0] != nil }
                opening = Array(opening.prefix(MeaningRanking.kindOnlyFiles))
            }
            let opened = Set(opening)

            // The rest by the fused score; the asked Kind's candidates go in
            // the block when the Query has a topic.
            let isLookup = MeaningRanking.isLookup(terms)
            var ranked: [Ranked] = []
            var kindRanked: [Ranked] = []
            func rank(_ id: Int64) -> Ranked {
                Ranked(id: id, score: MeaningRanking.score(z: meaning?.best(id)?.z, coverage: entries[id]?.coverage ?? 0,
                                                           isKindLifted: info[id]?.content.map(lifted.contains) ?? false,
                                                           isLookup: isLookup),
                       order: entries[id]?.order ?? Int.max)
            }
            for (id, entry) in entries where !entry.isNameMatch && !opened.contains(id) {
                guard MeaningRanking.isCandidate(z: meaning?.best(id)?.z, coverage: entry.coverage ?? 0) else { continue }
                if hasTopic && isAsked(id) {
                    kindRanked.append(rank(id))
                } else {
                    ranked.append(rank(id))
                }
            }
            // A Kind Word is a request even when nothing of the Kind stands
            // out: its best guesses, the files of the Kind with the best z
            // below the gate, fill the block up to `kindGuesses`, each scored
            // with its words like any other member.
            let guesses = MeaningRanking.kindGuesses - opening.count - kindRanked.count
            if hasTopic, guesses > 0, let meaning {
                let taken = opened.union(kindRanked.map(\.id)).union(namedForTheKind)
                var best: [(id: Int64, z: Double)] = []
                try? db.query("""
                    SELECT id FROM files WHERE content IN (SELECT value FROM json_each(?1))
                        AND source IN (SELECT value FROM json_each(?2)) AND vec_state != 'pending'
                    """, [.text(kindList), .text(sourceList)]) { row in
                    let id = row.int(0)
                    guard !taken.contains(id), let match = meaning.best(id), match.z > -.infinity else { return }
                    best.append((id, match.z))
                }
                let chosen = best.sorted { ($0.z, -$0.id) > ($1.z, -$1.id) }.prefix(guesses).map(\.id)
                lookUp(chosen.filter { info[$0] == nil })
                for id in chosen where info[id] != nil && entries[id] == nil { entries[id] = Fused(order: Int.max) }
                measure(chosen.filter { entries[$0] != nil && entries[$0]?.coverage == nil })
                for id in chosen where entries[id] != nil { kindRanked.append(rank(id)) }
            }
            kindRanked += namedForTheKind.map(rank)
            func byScore(_ a: Ranked, _ b: Ranked) -> Bool { (a.score, -a.order, -a.id) > (b.score, -b.order, -b.id) }
            ranked.sort(by: byScore)
            kindRanked.sort(by: byScore)

            // A Ranked file as a File Result: pointed at where the words
            // matched, so the row, the Card and the preview can mark them;
            // else at the best segment by meaning where it stands out. A
            // picture found whole borrows the words of its OCR, which
            // describe the same picture.
            func fusedHit(_ id: Int64, score: Int) -> FileHit? {
                guard let file = info[id] else { return nil }
                var hit = self.hit(path: file.path, kind: file.kind, score: score)
                hit.passage = entries[id]?.hit?.passage
                if let match = meaning?.best(id), match.z >= MeaningRanking.zGate,
                   let modality = segmentModality(match.segment, db: db) {
                    hit.meaning = modality
                    if hit.passage?.matches.isEmpty ?? true {
                        hit.passage = meaningPassage(match.segment, db: db) ?? hit.passage
                    }
                }
                return hit
            }

            var block: [FileHit] = []
            for id in opening {
                let score = FileHit.kindScore + min(block.count, -FileHit.kindScore - 1)
                if var hit = entries[id]?.hit, entries[id]?.isNameMatch == true || asksForFolders {
                    hit.score = score
                    block.append(hit)
                } else if let hit = fusedHit(id, score: score) {
                    block.append(hit)
                }
            }
            for candidate in kindRanked {
                if let hit = fusedHit(candidate.id, score: FileHit.kindScore + min(block.count, -FileHit.kindScore - 1)) {
                    block.append(hit)
                }
            }
            // Name matches of the other Kinds keep their score, and a
            // folder-only match stays unless it is ranked or in the block.
            let placed = opened.union(kindRanked.map(\.id)).union(ranked.map(\.id))
            var rest = wordFiles.filter { $0.hit.passage == nil && !placed.contains($0.id) }.map(\.hit)
            for (rank, candidate) in ranked.prefix(limit).enumerated() {
                if let hit = fusedHit(candidate.id,
                                      score: FileHit.contentScore + min(rank, FileHit.folderOnlyScore - FileHit.contentScore - 1)) {
                    rest.append(hit)
                }
            }
            return Array((block + rest.enumerated()
                .sorted { ($0.element.score, $0.offset) < ($1.element.score, $1.offset) }
                .map(\.element))
                .prefix(limit))
        }
    }

    /// Files the any-word query brings into the running.
    static let anyWordFiles = 100

    private struct Fused {
        var order: Int
        var hit: FileHit?
        var isNameMatch = false
        /// The share of the Query's words in the file; nil until measured.
        var coverage: Double?
    }

    private struct FileInfo {
        let path: String
        let kind: FileIndexRow.Kind
        let content: FileContent?
    }

    /// A candidate by its fused score, higher is better; `order` is the
    /// word search's, which breaks a tie.
    private struct Ranked {
        let id: Int64
        let score: Double
        let order: Int
    }

    /// Nil when the segment is gone: its file changed since the vectors were
    /// scored. Called with the lock held.
    private func segmentModality(_ segment: Int64, db: SQLiteConnection) -> MeaningModality? {
        var modality: MeaningModality?
        try? db.query("SELECT kind FROM segments WHERE id = ?", [.int(segment)]) {
            modality = FilePassage.Kind(rawValue: $0.text(0) ?? "")?.modality
        }
        return modality
    }

    /// The Passage a file was found by meaning on: its page, its moment, or
    /// the start of its text. A picture found whole has none. Called with
    /// the lock held.
    private func meaningPassage(_ segment: Int64, db: SQLiteConnection) -> FileHit.Passage? {
        var passage: FileHit.Passage?
        try? db.query("SELECT kind, loc, loc_end FROM segments WHERE id = ?", [.int(segment)]) { row in
            guard let kind = FilePassage.Kind(rawValue: row.text(0) ?? ""), let modality = kind.modality else { return }
            let location = row.isNull(1) ? nil : row.double(1)
            let end = row.isNull(2) ? nil : row.double(2)
            switch kind {
            case .image, .ocr:
                break
            case .page, .pageImage:
                passage = FileHit.Passage(excerpt: "", matches: [], page: location.map { Int($0) }, modality: modality)
            case .chunk:
                passage = FileHit.Passage(excerpt: "", matches: [], page: nil, modality: modality)
            case .frame, .audio:
                passage = FileHit.Passage(excerpt: "", matches: [], page: nil, start: location, end: end, modality: modality)
            }
        }
        guard let found = passage, found.modality == .text else { return passage }
        var body: String?
        try? db.query("SELECT body FROM passages WHERE rowid = ?", [.int(segment)]) { body = $0.text(0) }
        return FileHit.Passage(excerpt: Self.opening(of: body ?? ""), matches: [], page: found.page,
                               modality: found.modality)
    }

    /// The first `openingCharacters` of `text` on one line, cut at a word.
    static func opening(of text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > openingCharacters else { return line }
        let cut = line.prefix(openingCharacters)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }

    static let openingCharacters = 120

    private struct Candidate {
        let kind: FileIndexRow.Kind
        var content: FileContent?
        var score: Int
        let order: Int
        var segment: Int64?
        var page: Int?
    }

    /// The Passage `segment` as a row shows it: FTS5's own snippet, so the
    /// marked words are the ones it matched — stemmed, prefixed, folded.
    /// Called with the lock held.
    ///
    /// A prefix is spelled out first, as the words in this Passage that begin
    /// with it (`expandingPrefix`): FTS5 evaluates the expression again for
    /// every snippet, and a prefix's posting lists with it. "the " cost 23 ms
    /// a row that way, half a second for a list of them.
    private func passage(_ segment: Int64, page: Int?, words: [String], match: String,
                         statements: Statements) -> FileHit.Passage? {
        var expression = match
        if match.hasSuffix("*"), let prefix = words.last {
            var body: String?
            try? statements.body.run([.int(segment)]) { body = $0.text(0) }
            expression = Self.expandingPrefix(prefix, of: words, in: body ?? "") ?? match
        }
        var snippet: String?
        try? statements.snippet.run([.text(expression), .int(segment)]) { snippet = $0.text(0) }
        return snippet.map { Self.passage(snippet: $0, page: page) }
    }

    /// The match expression for `words` with the last, `prefix`, replaced by
    /// the words of `body` that begin with it — `"faktura" AND ("husleje" OR
    /// "huslejen")` — or nil when `body` has none (the match was a stem or a
    /// fold the split here does not make). At most `maxPrefixWords` of them.
    static func expandingPrefix(_ prefix: String, of words: [String], in body: String) -> String? {
        let folded = fold(prefix)
        var found: [String] = []
        var seen = Set<String>()
        for word in body.components(separatedBy: CharacterSet.alphanumerics.inverted) where word.count >= prefix.count {
            let candidate = fold(word.precomposedStringWithCanonicalMapping)
            guard candidate.hasPrefix(folded), seen.insert(candidate).inserted else { continue }
            found.append(candidate)
            if found.count == maxPrefixWords { break }
        }
        guard !found.isEmpty else { return nil }
        let alternatives = "(" + found.map { "\"\($0)\"" }.joined(separator: " OR ") + ")"
        // FTS5 takes no implicit AND before a bracket.
        let before = words.dropLast().map { "\"\($0)\" AND " }.joined()
        return before + alternatives
    }

    static let maxPrefixWords = 16

    /// A snippet with its matches between U+0001 and U+0002, as one line.
    static func passage(snippet: String, page: Int?) -> FileHit.Passage {
        var excerpt = ""
        var matches: [Range<Int>] = []
        var count = 0
        var start: Int?
        var lastWasSpace = false
        for character in snippet {
            switch character {
            case "\u{1}":
                start = count
            case "\u{2}":
                if let begin = start, count > begin { matches.append(begin..<count) }
                start = nil
            case let blank where blank.isWhitespace:
                guard !lastWasSpace, count > 0 else { continue }
                excerpt.append(" ")
                count += 1
                lastWasSpace = true
            default:
                excerpt.append(character)
                count += 1
                lastWasSpace = false
            }
        }
        return FileHit.Passage(excerpt: excerpt.trimmingCharacters(in: .whitespaces), matches: matches, page: page)
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

    /// How much of each folder Source is in the index: every row in it, and
    /// how many of those have their contents read — at least a first step,
    /// or nothing to read.
    func counts() -> [String: SourceCounts] {
        lock.withLock {
            guard let db = connection() else { return [:] }
            var counts: [String: SourceCounts] = [:]
            try? db.query("SELECT source, COUNT(*), SUM(state != 'pending') FROM files GROUP BY source") { row in
                counts[row.text(0) ?? ""] = SourceCounts(indexed: Int(row.int(2)), total: Int(row.int(1)))
            }
            return counts
        }
    }

    /// The rows the vector files should hold (`FileIndexWriter.vectorRows`),
    /// for opening them from a reader: the eval, and measurements.
    func vectorRows() -> Int {
        lock.withLock {
            var rows = 0
            try? connection()?.query("SELECT value FROM meta WHERE key = 'vector_rows'") { rows = Int($0.text(0) ?? "") ?? 0 }
            return rows
        }
    }

    /// What the file at `path` has to read, if it is indexed.
    func content(atPath path: String) -> FileContent? {
        lock.withLock {
            var content: FileContent?
            try? connection()?.query("SELECT content FROM files WHERE path = ?", [.text(path)]) { row in
                content = row.isNull(0) ? nil : FileContent(rawValue: Int(row.int(0)))
            }
            return content
        }
    }

    /// How far the meaning pass has got in `sources`: files with anything to
    /// embed, and how many of those are through.
    func meaningCounts(sources: [String]) -> MeaningCounts {
        lock.withLock {
            guard let db = connection() else { return MeaningCounts() }
            var counts = MeaningCounts()
            try? db.query("""
                SELECT COUNT(*), SUM(vec_state = 'done') FROM files
                WHERE content IS NOT NULL AND source IN (SELECT value FROM json_each(?))
                """, [.text(Self.jsonList(sources))]) { row in
                counts.files = Int(row.int(0))
                counts.embedded = Int(row.int(1))
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

    /// The words of `words` a file must have: not a folder word ("folder",
    /// "mappe"), which asks for a kind of row rather than naming one, and not
    /// a function word ("for", "the", "af", "me"), which a name or a path
    /// seldom has. The whole Query still scores the name, so a name with them
    /// ranks as before. On the keystroke a function word that is the last is
    /// kept: it may be the start of a longer word still being typed ("for" of
    /// "format"). Once typing pauses (`isSettled`) it is a finished word and
    /// never a prefix — "me" does not find "meeting" — so it is dropped like
    /// the others, and so is a Kind Word, which the Kind answers ("pdf
    /// invoice" wants an invoice that is a PDF, not one that says "pdf"),
    /// with the file words beside it ("audio file"), unless a folder word
    /// makes it a word to look for in folder names. When that leaves none,
    /// those are kept ("image of me", "audio file"), and failing them all of
    /// `words`, a function word last then whole.
    /// `endsOnLastWord` says whether the last kept is the Query's last and
    /// may be a prefix.
    static func requiredWords(_ words: [String], isSettled: Bool = false) -> (words: [String], endsOnLastWord: Bool) {
        let dropsKindWords = isSettled && !words.contains(where: MeaningRanking.folderWords.contains)
            && words.contains { MeaningRanking.kindWords[$0] != nil }
        func kept(droppingKindWords: Bool) -> [(offset: Int, element: String)] {
            words.enumerated().filter { index, word in
                !MeaningRanking.folderWords.contains(word)
                    && !((index < words.count - 1 || isSettled) && MeaningRanking.functionWords.contains(word))
                    && !(droppingKindWords
                         && (MeaningRanking.kindWords[word] != nil || MeaningRanking.fileWords.contains(word)))
            }
        }
        let found = dropsKindWords ? kept(droppingKindWords: true) : []
        let chosen = found.isEmpty ? kept(droppingKindWords: false) : found
        guard let last = chosen.last else {
            return (words, !(isSettled && words.last.map(MeaningRanking.functionWords.contains) == true))
        }
        return (chosen.map(\.element), last.offset == words.count - 1)
    }

    /// The folders a folder word puts first, of `folders` (paths) that the
    /// required `words` (folded) found: every one whose own name has one of
    /// the words, and one found by its path alone only where no folder
    /// already first is above it. `koffeelab-video/src` is in the list only
    /// because `koffeelab-video` is, and fifty of those buried the rest of
    /// "video folder".
    static func leadingFolders(_ folders: [String], words: [String], isLastOpen: Bool) -> Set<String> {
        func ownsAWord(_ path: String) -> Bool {
            let name = Self.words((path as NSString).lastPathComponent).map(fold)
            return words.enumerated().contains { index, word in
                covers(name, word, isPrefix: isLastOpen && index == words.count - 1)
            }
        }
        var leading = Set(folders.filter(ownsAWord))
        for path in folders.filter({ !leading.contains($0) }).sorted(by: { $0.count < $1.count })
        where !leading.contains(where: { path.hasPrefix($0 + "/") }) {
            leading.insert(path)
        }
        return leading
    }

    /// The words of the folders `path` is in, as the `names` table's folder
    /// column has them (`FileIndexSchema.folderText`), folded.
    static func folderWords(_ path: String, home: String) -> [String] {
        words(FileIndexSchema.folderText(path, home: home)).map(fold)
    }

    /// Whether one of `folders` is `word` (folded): the same, a plural of it
    /// or it of a plural ("system", "Systems", as FTS5's porter stemmer
    /// matches them), or with `isPrefix`, a word that begins with it.
    static func covers(_ folders: [String], _ word: String, isPrefix: Bool) -> Bool {
        folders.contains { folder in
            folder == word || (isPrefix && folder.hasPrefix(word))
                || isPlural(folder, of: word) || isPlural(word, of: folder)
        }
    }

    /// Whether `plural` is `word` with an English plural ending: "systems",
    /// "classes", "studies". Rougher than porter, which stems the search
    /// itself; a word this misses stays in the rest of the Query, and the
    /// name is scored as it was before folders counted. Prefixes and lengths
    /// only, since it runs for every word of up to `candidateLimit` paths.
    static func isPlural(_ plural: String, of word: String) -> Bool {
        let extra = plural.count - word.count
        if extra == 1 { return plural.hasSuffix("s") && plural.hasPrefix(word) }
        guard extra == 2, plural.hasSuffix("es") else { return false }
        return plural.hasPrefix(word) || (word.hasSuffix("y") && plural.hasSuffix("ies") && plural.hasPrefix(word.dropLast()))
    }

    /// Every word quoted, all of them required, the last a prefix because it
    /// is still being typed — if it has `prefixMinimum` characters.
    static func matchExpression(_ words: [String], prefixMinimum: Int = 1) -> String {
        words.enumerated().map { index, word in
            "\"\(word)\"" + (index == words.count - 1 && word.count >= prefixMinimum ? "*" : "")
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

    /// `values` as a JSON array, for `json_each`: one bound parameter for a
    /// list of any length.
    static func jsonList(_ values: [String]) -> String {
        (try? JSONSerialization.data(withJSONObject: values)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
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
        let passages: SQLiteStatement
        let snippet: SQLiteStatement
        let body: SQLiteStatement
    }

    /// Called with the lock held. Prepared once; preparing fails until the
    /// writer has created the tables, and is tried again next time.
    private func prepared() -> Statements? {
        if let statements { return statements }
        guard let db = connection(),
              let ranked = try? db.prepare("""
                SELECT f.path, f.kind, f.content FROM (
                    SELECT names.rowid AS id, bm25(names, 3.0, 1.0) AS rank
                    FROM names JOIN files f ON f.id = names.rowid
                    WHERE names MATCH ?1 AND f.source IN (SELECT value FROM json_each(?2))
                    LIMIT \(Self.rankingCap)
                ) matched JOIN files f ON f.id = matched.id
                ORDER BY matched.rank LIMIT ?3
                """),
              let unranked = try? db.prepare("""
                SELECT f.path, f.kind, f.content FROM names JOIN files f ON f.id = names.rowid
                WHERE names MATCH ?1 AND f.source IN (SELECT value FROM json_each(?2))
                LIMIT ?3
                """),
              // A file's best Passage: SQLite takes a bare column's value
              // from the row MIN() chose. The Kinds in ?4 first (none on the
              // keystroke), so the limit keeps them.
              let passages = try? db.prepare("""
                SELECT f.path, f.kind, matched.id, s.kind, s.loc, MIN(matched.rank) AS best, f.content FROM (
                    SELECT passages.rowid AS id, bm25(passages) AS rank
                    FROM passages JOIN segments s ON s.id = passages.rowid JOIN files f ON f.id = s.file
                    WHERE passages MATCH ?1 AND f.source IN (SELECT value FROM json_each(?2))
                    LIMIT \(Self.rankingCap)
                ) matched JOIN segments s ON s.id = matched.id JOIN files f ON f.id = s.file
                GROUP BY s.file
                ORDER BY COALESCE(f.content IN (SELECT value FROM json_each(?4)), 0) DESC, best LIMIT ?3
                """),
              let snippet = try? db.prepare("""
                SELECT snippet(passages, 0, char(1), char(2), '…', \(Self.excerptWords))
                FROM passages WHERE passages MATCH ?1 AND rowid = ?2
                """),
              let body = try? db.prepare("SELECT body FROM passages WHERE rowid = ?1")
        else { return nil }
        statements = Statements(ranked: ranked, unranked: unranked, passages: passages, snippet: snippet, body: body)
        return statements
    }
}
