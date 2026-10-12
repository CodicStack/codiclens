import CryptoKit
import Darwin
import Foundation

/// Every vector search by meaning has made, kept by what was embedded: the
/// durable store of them, `VectorCache.sqlite` beside the File Index. See
/// `docs/adr/0013-vector-cache-survives-index-rebuilds.md`.
///
/// - **A key is the input**, 16 bytes of SHA-256 over `fingerprint` and a
///   description of exactly what the model was given (`Key`): a text's whole
///   prompt, title included; a picture, a page drawn as one, a video frame or
///   a window of sound by its file's SHA-256, where in the file, and every
///   setting that decides the pixels or the samples. The same input anywhere
///   — two copies of a note, a file moved to another Source — is one key and
///   one vector, embedded once.
/// - **It outlives the index.** A `FileIndexSchema.version` bump drops the
///   index and reads names and contents again (minutes); the meaning pass
///   then finds every unchanged input here and asks the helper for nothing
///   (an embedding backfill is hours). The index's `segments.vec_key` points
///   in, and `FileIndex.vectors` is built from here (`MeaningVectors`).
/// - **Cleared only when `fingerprint` changes**, and by "Remove Model and
///   Vectors…". One whose file changed or went stays, for when those bytes
///   come back, until it has gone `unusedDays` unused: the daily prune
///   (`pruneIfCaughtUp`) takes it out then. Used is written, found, or
///   referenced by the index, kept as a day in `used`.
/// - **Its own format**, `version`, trivial on purpose: one table from key to
///   vector, the day each was last used, and `meta`. Version 1, from before
///   `used`, is brought over in place, every entry used on the day of the
///   upgrade; any other version it does not know is dropped and made again,
///   as the index's is.
///
/// Thread-safe: one connection behind a lock. A second `VectorCache` on the
/// same file (another File Index in a test; later, a helper process) waits on
/// SQLite's own lock.
nonisolated final class VectorCache: @unchecked Sendable {
    static let version: Int64 = 2

    /// What every vector depends on that its key does not spell out: the
    /// model, its prompt scheme, and how the helper prepares a picture or a
    /// recording. Another one clears the cache.
    static let fingerprint = [
        "embeddinggemma-2@\(ModelFiles.revision)",
        "prompts: title|text, search result",
        "inputs \(inputs)",
    ].joined(separator: "; ")

    /// How the helper turns a file into the model's input: `EmbeddingInput`
    /// (upright RGB, 16 kHz mono) and `ImageSizing`. A media key names the
    /// file's bytes, not what the helper made of them, so any change there
    /// bumps this.
    static let inputs = 1

    /// A row is a 16-byte key and 1,536 bytes of vector: a 4 KB page holds
    /// two and wastes a quarter, an 8 KB page holds five.
    static let pageSize = 8192

    /// An entry unused for longer than this goes at the next prune. A
    /// month: an edit undone or a file put back within it costs nothing.
    static let unusedDays: Int64 = 30

    /// The prune hands the space back (`VACUUM`, a rewrite of the whole
    /// file) once the entries it took out since the last time come to this
    /// share of the ones left. Entries go one here and one there, so most of
    /// what they free is part of a page, and only a rewrite gets it back.
    static let vacuumShare: Double = 0.1

    /// Days since 1970, in UTC: the unit `used` is kept in.
    static func day(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// `VectorCache.sqlite`, in the folder the File Index's database is in.
    static func url(besideDatabase databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent("VectorCache.sqlite")
    }

    /// 16 bytes of SHA-256 over `VectorCache.fingerprint` and a description
    /// of one input. Each kind spells out everything that decides its vector.
    struct Key: Hashable, Sendable {
        let bytes: Data

        init(bytes: Data) {
            self.bytes = bytes
        }

        private init(_ input: String) {
            bytes = Data(SHA256.hash(data: Data((VectorCache.fingerprint + "\n" + input).utf8)).prefix(16))
        }

        /// A text: the whole prompt sent, title and all
        /// (`EmbeddingPrompt.document`).
        static func text(_ prompt: String) -> Key {
            Key("text\n" + prompt)
        }

        /// A photo or a screenshot, which the helper reads from the file.
        static func picture(_ file: FileDigest, budget: ImageBudget) -> Key {
            Key("picture \(file.sha256) \(budget.tokens)")
        }

        /// A PDF page drawn as a picture (`MeaningReader.pagePicture`); from 1.
        static func page(_ file: FileDigest, number: Int) -> Key {
            Key("page \(file.sha256) \(number) \(MeaningReader.pagePixels)px png \(ImageBudget.pdfPage.tokens)")
        }

        /// A video frame, by where it stands (`MeaningResult.Vector.location`).
        /// Which frame lands there is decided by the file, the sampling and
        /// the steps (`MeaningReader.frameTimes`, `step`), all spelled out.
        static func frame(_ file: FileDigest, at seconds: Double) -> Key {
            Key("""
                frame \(file.sha256) \(seconds) every \(MeaningPass.frameInterval)s at most \(MeaningPass.maxFrames) \
                steps \(MeaningPass.firstSeconds)/\(MeaningPass.laterSeconds) \(MeaningReader.frameSide)px \
                jpeg \(MeaningReader.jpegQuality) \(ImageBudget.videoFrame.tokens)
                """)
        }

        /// A window of a recording or a soundtrack, from `start` to `end` s.
        static func sound(_ file: FileDigest, from start: Double, to end: Double) -> Key {
            Key("sound \(file.sha256) \(start)-\(end)")
        }
    }

    let url: URL
    private let lock = NSLock()
    private let db: SQLiteConnection
    private let today: @Sendable () -> Int64
    private var currentID = ""

    /// Opens or makes the cache at `url`. Under another `fingerprint` it is
    /// emptied first, and takes a new `id`.
    ///
    /// - Parameter today: the day it is (`day(of:)`); tests pass their own.
    init(
        url: URL,
        fingerprint: String = VectorCache.fingerprint,
        today: @escaping @Sendable () -> Int64 = { VectorCache.day(of: Date()) }
    ) throws {
        self.url = url
        self.today = today
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteConnection(path: url.path, pageSize: Self.pageSize)
        try db.transaction {
            var version: Int64 = 0
            try db.query("PRAGMA user_version") { version = $0.int(0) }
            switch version {
            case Self.version:
                break
            case 1:
                // Before `used`: nobody knows when an entry was last used, so
                // each counts as used today and has its month from here.
                try db.execute("""
                    \(Self.usedTable)
                    INSERT INTO used(key, day) SELECT key, \(today()) FROM vectors;
                    PRAGMA user_version = \(Self.version);
                    """)
            default:
                try db.execute("""
                    DROP TABLE IF EXISTS vectors;
                    DROP TABLE IF EXISTS used;
                    DROP TABLE IF EXISTS meta;
                    CREATE TABLE vectors(key BLOB PRIMARY KEY, vec BLOB NOT NULL);  -- Key, 768 × float16
                    \(Self.usedTable)
                    -- 'fingerprint' (VectorCache.fingerprint), 'id' (new whenever the cache is emptied),
                    -- 'pruned' (the day of the last prune), 'unvacuumed' (entries pruned since the last VACUUM).
                    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
                    PRAGMA user_version = \(Self.version);
                    """)
            }
            var current: String?
            try db.query("SELECT value FROM meta WHERE key = 'fingerprint'") { current = $0.text(0) }
            if current != fingerprint {
                try db.run("DELETE FROM vectors")
                try db.run("DELETE FROM used")
                try setMeta("fingerprint", fingerprint)
                try setMeta("id", UUID().uuidString)
            }
            try db.query("SELECT value FROM meta WHERE key = 'id'") { currentID = $0.text(0) ?? "" }
        }
    }

    /// The day each entry was last written, found, or referenced by the
    /// index. A table of its own, so stamping rewrites pages of small rows,
    /// not the pages the vectors are on.
    private static let usedTable = """
        CREATE TABLE used(key BLOB PRIMARY KEY, day INTEGER NOT NULL) WITHOUT ROWID;  -- VectorCache.day
        """

    /// Who this cache is: new each time it is emptied. The index keeps the
    /// one its `vec_key`s point into (`FileIndexWriter.adoptVectorCache`), so
    /// an index whose cache was cleared or deleted embeds again.
    var id: String {
        lock.withLock { currentID }
    }

    /// The vectors the cache has among `keys`, 768 float16s each. Each one
    /// found is used today; only those stamped another day are written, in
    /// one transaction.
    func vectors(for keys: [Key]) throws -> [Key: Data] {
        guard !keys.isEmpty else { return [:] }
        return try lock.withLock {
            let today = today()
            var found: [Key: Data] = [:]
            var stale: [Key] = []
            for key in keys {
                try db.query("""
                    SELECT v.vec, u.day FROM vectors v LEFT JOIN used u ON u.key = v.key WHERE v.key = ?
                    """, [.blob(key.bytes)]) { row in
                    guard let vector = row.blob(0) else { return }
                    found[key] = vector
                    if row.isNull(1) || row.int(1) != today { stale.append(key) }
                }
            }
            if !stale.isEmpty {
                try db.transaction {
                    for key in stale { try stamp(key, today) }
                }
            }
            return found
        }
    }

    /// Keeps `entries` in one transaction, each used today. A key already
    /// there keeps its vector: the same input made it.
    func store(_ entries: [(key: Key, vector: Data)]) throws {
        guard !entries.isEmpty else { return }
        try lock.withLock {
            let today = today()
            try db.transaction {
                for entry in entries where entry.vector.count == MeaningVectors.vectorBytes {
                    try db.run("INSERT OR IGNORE INTO vectors(key, vec) VALUES(?, ?)",
                               [.blob(entry.key.bytes), .blob(entry.vector)])
                    try stamp(entry.key, today)
                }
            }
        }
    }

    /// `key` used on `day`, written only if it was not already. Inside a
    /// transaction.
    private func stamp(_ key: Key, _ day: Int64) throws {
        try db.run("""
            INSERT INTO used(key, day) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET day = excluded.day
            WHERE day != excluded.day
            """, [.blob(key.bytes), .int(day)])
    }

    var count: Int {
        lock.withLock {
            var count = 0
            try? db.query("SELECT COUNT(*) FROM vectors") { count = Int($0.int(0)) }
            return count
        }
    }

    /// Every vector, and the disk they took: "Remove Model and Vectors…".
    func removeAll() throws {
        try lock.withLock {
            try db.transaction {
                try db.run("DELETE FROM vectors")
                try db.run("DELETE FROM used")
                try setMeta("id", UUID().uuidString)
                try setMeta("unvacuumed", "0")
            }
            try db.query("SELECT value FROM meta WHERE key = 'id'") { currentID = $0.text(0) ?? "" }
            try vacuum()
        }
    }

    /// Rewrites the file without its free space, and hands the disk back:
    /// in WAL mode the rewrite lands in the log, and only a checkpoint
    /// moves it into the file and empties the log. With the lock held.
    private func vacuum() throws {
        try db.execute("VACUUM")
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private func meta(_ key: String) throws -> String? {
        var value: String?
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { value = $0.text(0) }
        return value
    }

    /// Called inside a transaction, or with the lock held.
    private func setMeta(_ key: String, _ value: String) throws {
        try db.run("""
            INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, [.text(key), .text(value)])
    }
}

// MARK: - The daily prune

extension VectorCache {
    /// What a prune did.
    struct Pruning: Equatable, Sendable {
        /// Keys the index points to whose day moved to today.
        var stamped = 0
        /// Entries unused for longer than `unusedDays`, taken out.
        var removed = 0
        /// Entries left.
        var kept = 0
        /// The file and its log on disk, before and after.
        var bytesBefore: Int64 = 0
        var bytesAfter: Int64 = 0
        /// Whether this one handed the space back (`vacuumShare`).
        var vacuumed = false
    }

    /// What `pruneIfCaughtUp` came to.
    enum Upkeep: Equatable, Sendable {
        /// The index is not caught up: not now.
        case deferred
        /// Pruned already today.
        case done
        case pruned(Pruning)
    }

    /// The daily prune, on the File Index's queue (`FileIndex.Worker`), so
    /// no crawl, batch or rebuild of the vector files runs meanwhile. Only
    /// once the index is caught up, because then the keys it points to are
    /// all it will ask for: every file in `sources` read and embedded, so
    /// no backfill waits. And never in a session whose index was made anew
    /// (`FileIndexWriter.isNew`, a schema bump or a deleted database): it
    /// is being read again from the disk to find its vectors here, and
    /// points to few of them yet.
    func pruneIfCaughtUp(index writer: FileIndexWriter, sources: [String]) throws -> Upkeep {
        guard try !isPrunedToday else { return .done }
        guard !writer.isNew, try writer.isCaughtUp(sources: sources) else { return .deferred }
        return .pruned(try prune(keeping: writer.vectorKeys()))
    }

    var isPrunedToday: Bool {
        get throws {
            try lock.withLock { try meta("pruned") == String(today()) }
        }
    }

    /// Stamps each of `referenced` used today, then takes out every entry
    /// unused for longer than `unusedDays`: one the index points to is never
    /// taken out, however long since it was last found. The space comes back
    /// once enough has gone (`vacuumShare`); until then SQLite reuses the
    /// pages that were freed whole.
    @discardableResult
    func prune(keeping referenced: [Key]) throws -> Pruning {
        try lock.withLock {
            let today = today()
            var pruning = Pruning(bytesBefore: diskBytes)
            var unvacuumed = 0
            try db.transaction {
                for key in referenced {
                    try db.run("UPDATE used SET day = ? WHERE key = ? AND day != ?",
                               [.int(today), .blob(key.bytes), .int(today)])
                    pruning.stamped += db.changes
                }
                let cutoff = today - Self.unusedDays
                try db.run("DELETE FROM vectors WHERE key IN (SELECT key FROM used WHERE day < ?)", [.int(cutoff)])
                pruning.removed = db.changes
                try db.run("DELETE FROM used WHERE day < ?", [.int(cutoff)])
                try db.query("SELECT COUNT(*) FROM vectors") { pruning.kept = Int($0.int(0)) }
                unvacuumed = try (meta("unvacuumed").flatMap { Int($0) } ?? 0) + pruning.removed
                try setMeta("unvacuumed", String(unvacuumed))
                try setMeta("pruned", String(today))
            }
            if unvacuumed > 0, Double(unvacuumed) >= Double(pruning.kept) * Self.vacuumShare {
                try vacuum()
                try setMeta("unvacuumed", "0")
                pruning.vacuumed = true
            } else {
                try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            }
            pruning.bytesAfter = diskBytes
            return pruning
        }
    }

    /// The file and its log, as the disk has them.
    private var diskBytes: Int64 {
        [url.path, url.path + "-wal"].reduce(0) { bytes, path in
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
            return bytes + (size?.int64Value ?? 0)
        }
    }
}

// MARK: - A file's contents

/// A file's contents by SHA-256, with the size and date it had while it was
/// read, so whoever keeps a vector made from it can tell it did not change
/// meanwhile.
nonisolated struct FileDigest: Equatable, Sendable {
    /// Size and modification date, as the File Index stats a file.
    struct Stamp: Equatable, Sendable {
        let size: Int64
        let mtime: Double

        init(size: Int64, mtime: Double) {
            self.size = size
            self.mtime = mtime
        }

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            size = Int64(info.st_size)
            mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        }

        /// Within the File Index's own tolerance (`FileIndexRow.isSameVersion`).
        func matches(_ other: Stamp) -> Bool {
            size == other.size && abs(mtime - other.mtime) < 0.001
        }
    }

    let sha256: String
    let stamp: Stamp

    init(sha256: String, stamp: Stamp) {
        self.sha256 = sha256
        self.stamp = stamp
    }

    /// The file at `path` hashed whole; nil when it cannot be read, or
    /// changed while it was. With `expected`, nil too unless the file still
    /// has that size and date — a file changed since then is not hashed.
    init?(path: String, expected: Stamp? = nil) {
        guard let before = Stamp(path: path), expected.map(before.matches) ?? true,
              let sha256 = try? ModelFiles.sha256(of: URL(fileURLWithPath: path)),
              Stamp(path: path) == before
        else { return nil }
        self.init(sha256: sha256, stamp: before)
    }

    /// The file at `path` still has the size and date it was hashed at.
    func isCurrent(at path: String) -> Bool {
        Stamp(path: path) == stamp
    }
}

// MARK: - Seeding from an index being dropped

extension VectorCache {
    /// What `seed(fromIndex:)` brought over.
    struct Seeding: Equatable, Sendable {
        /// Passages, by their prompt: always exactly what was sent.
        var texts = 0
        /// Pictures, pages drawn as pictures, frames and windows of sound,
        /// by their file's SHA-256, hashed now.
        var media = 0
        /// Media whose file changed or went since its vectors were made:
        /// not knowable now, so left for the meaning pass to embed again.
        var stale = 0
    }

    /// Takes in every vector an index about to be dropped holds in
    /// `segments.vec` (schema 4, before this cache existed), under the key
    /// the meaning pass would give it now, so the hours that went into them
    /// survive the drop. Only under today's `MeaningPass.fingerprint`: under
    /// another one the prompts, budgets or steps the keys spell out may not be
    /// the ones the vectors were made with. A newer index keeps its vectors
    /// here already, and has no `vec` to take.
    ///
    /// A text key is exact from the index alone, with one gap: a file renamed
    /// after it was embedded kept its vectors (a move keeps Passages), so its
    /// vectors were made under the old name's title and land under the new
    /// name's key. A media key needs the file's SHA-256, which the index never
    /// had: the file is hashed now if it still has the size and date it was
    /// embedded at, and left out (`stale`) if not.
    @discardableResult
    func seed(fromIndex index: SQLiteConnection) throws -> Seeding {
        var seeding = Seeding()
        var hasVectors = false
        try index.query("SELECT 1 FROM pragma_table_info('segments') WHERE name = 'vec'") { _ in hasVectors = true }
        guard hasVectors else { return seeding }
        var fingerprint: String?
        try index.query("SELECT value FROM meta WHERE key = 'meaning'") { fingerprint = $0.text(0) }
        guard fingerprint == MeaningPass.fingerprint else { return seeding }

        var entries: [(key: Key, vector: Data)] = []
        var file: (id: Int64, digest: FileDigest?) = (0, nil)
        try index.query("""
            SELECT s.kind, s.loc, s.loc_end, s.vec, f.id, f.path, f.content, f.size, f.mtime,
                (SELECT body FROM passages WHERE rowid = s.id)
            FROM segments s JOIN files f ON f.id = s.file WHERE s.vec IS NOT NULL ORDER BY s.file, s.id
            """) { row in
            guard let kind = FilePassage.Kind(rawValue: row.text(0) ?? ""), let vector = row.blob(3),
                  vector.count == MeaningVectors.vectorBytes
            else { return }
            let path = row.text(5) ?? ""
            let key: Key
            switch kind {
            case .chunk, .page:
                guard let body = row.text(9) else { return }
                key = .text(EmbeddingPrompt.document(title: MeaningReader.title(of: path),
                                                     text: String(body.prefix(MeaningPass.maxTextCharacters))))
                seeding.texts += 1
            case .image, .pageImage, .frame, .audio:
                if file.id != row.int(4) {
                    file = (row.int(4), FileDigest(path: path, expected: .init(size: row.int(7), mtime: row.double(8))))
                }
                guard let digest = file.digest else {
                    seeding.stale += 1
                    return
                }
                switch kind {
                case .image:
                    let isScreenshot = FileContent(rawValue: Int(row.int(6))) == .screenshot
                    key = .picture(digest, budget: isScreenshot ? .screenshot : .photo)
                case .pageImage:
                    key = .page(digest, number: Int(row.double(1)))
                case .frame:
                    key = .frame(digest, at: row.double(1))
                default:
                    key = .sound(digest, from: row.double(1), to: row.double(2))
                }
                seeding.media += 1
            case .ocr:
                return
            }
            entries.append((key, vector))
            if entries.count == 1000 {
                try store(entries)
                entries.removeAll(keepingCapacity: true)
            }
        }
        try store(entries)
        return seeding
    }
}
