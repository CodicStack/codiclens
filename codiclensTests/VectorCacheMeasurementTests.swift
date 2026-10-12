import Foundation
import Testing
@testable import codiclens

private let measuredIndex = ProcessInfo.processInfo.environment["CODICLENS_MEASURE_VECTOR_CACHE"]

/// The vector cache on a real index of schema 4, in a temporary folder: what
/// seeding brings over and how long it takes (media files are hashed, only
/// read), the opening of that index under today's schema (seeded, dropped,
/// made again), and the disk before and after — schema 4's `segments.vec`
/// beside the vector files, against schema 5's keys, the cache and the same
/// vector files — then the cache's bytes a vector at scale, on 8 KB pages and
/// on 4 KB ones. Off unless asked for; the value is a **copy** of a
/// `FileIndex.sqlite` (the running app writes to the real one):
///
/// ```
/// sqlite3 "file:$HOME/Library/Application Support/codiclens/FileIndex.sqlite?mode=ro" ".backup /tmp/FileIndex-copy.sqlite"
/// TEST_RUNNER_CODICLENS_MEASURE_VECTOR_CACHE=/tmp/FileIndex-copy.sqlite xcodebuild test \
///   -project codiclens.xcodeproj -scheme codiclens -configuration Debug \
///   -parallel-testing-enabled NO -only-testing:codiclensTests/VectorCacheMeasurementTests
/// ```
@Suite(.serialized, .enabled(if: measuredIndex != nil))
struct VectorCacheMeasurementTests {
    @Test func seedingARealIndexAndTheDiskBeforeAndAfter() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = URL(fileURLWithPath: measuredIndex ?? "")
        let before = folder.url.appendingPathComponent("before.sqlite")
        try FileManager.default.copyItem(at: source, to: before)
        let index = try SQLiteConnection(path: before.path)
        try index.execute("VACUUM; PRAGMA wal_checkpoint(TRUNCATE)")
        var vectors = 0
        var version: Int64 = 0
        try index.query("SELECT COUNT(*) FROM segments WHERE vec IS NOT NULL") { vectors = Int($0.int(0)) }
        try index.query("PRAGMA user_version") { version = $0.int(0) }
        let indexBefore = try Self.size(before)

        let cacheURL = folder.url.appendingPathComponent("VectorCache.sqlite")
        var cache: VectorCache? = try VectorCache(url: cacheURL)
        var seeding = VectorCache.Seeding()
        let took = try ContinuousClock().measure { seeding = try cache!.seed(fromIndex: index) }
        let inputs = cache!.count
        // Closing the last connection checkpoints and removes its log.
        cache = nil
        print("schema \(version), \(vectors) vectors: seeded \(seeding.texts) texts and \(seeding.media) media "
              + "in \(took), \(seeding.stale) media stale; \(inputs) distinct inputs")
        var stale: [String] = []
        try index.query("""
            SELECT f.path, COUNT(*) FROM segments s JOIN files f ON f.id = s.file
            WHERE s.vec IS NOT NULL AND s.kind IN ('image', 'page_image', 'frame', 'audio') GROUP BY f.id
            """) { row in
            let path = row.text(0) ?? ""
            guard FileDigest.Stamp(path: path) == nil else { return }
            stale.append("\(path) (\(row.int(1)), gone)")
        }
        print("media of files gone: \(stale.count)" + stale.prefix(5).map { "\n  \($0)" }.joined())

        // Schema 5's shape: a 16-byte key where the vector was.
        try index.execute("""
            ALTER TABLE segments ADD COLUMN vec_key BLOB;
            UPDATE segments SET vec_key = randomblob(16) WHERE vec IS NOT NULL;
            ALTER TABLE segments DROP COLUMN vec;
            VACUUM;
            PRAGMA wal_checkpoint(TRUNCATE);
            """)
        let indexAfter = try Self.size(before)
        let cacheSize = try Self.databaseSize(cacheURL)
        let matrix = vectors * (MeaningVectors.vectorBytes + MeaningVectors.recordBytes)
        let mb = { (bytes: Int) in String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        print("""
            before: index \(mb(indexBefore)) + vector files \(mb(matrix)) = \(mb(indexBefore + matrix))
            after:  index \(mb(indexAfter)) + cache \(mb(cacheSize)) + vector files \(mb(matrix)) \
            = \(mb(indexAfter + cacheSize + matrix))
            a vector: \((indexBefore - indexAfter) / max(1, vectors)) bytes in the index before, \
            \(cacheSize / max(1, inputs)) in the cache after
            """)

        // The app's own path: the index of schema 4 opened under today's.
        let opened = folder.url.appendingPathComponent("FileIndex.sqlite")
        try FileManager.default.copyItem(at: source, to: opened)
        let fresh = try VectorCache(url: VectorCache.url(besideDatabase: opened))
        let writer = try FileIndexWriter(url: opened, cache: fresh)
        var now: Int64 = 0
        try writer.db.query("PRAGMA user_version") { now = $0.int(0) }
        #expect(now == FileIndexSchema.version)
        #expect(fresh.count == inputs)
        print("opened as schema \(now): \(fresh.count) inputs in its cache")
    }

    @Test func bytesAVectorAtScale() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let rows = 100_000
        let cacheURL = folder.url.appendingPathComponent("VectorCache.sqlite")
        var cache: VectorCache? = try VectorCache(url: cacheURL)
        let small = try SQLiteConnection(path: folder.url.appendingPathComponent("small-pages.sqlite").path, pageSize: 4096)
        try small.execute("CREATE TABLE vectors(key BLOB PRIMARY KEY, vec BLOB NOT NULL)")
        for start in stride(from: 0, to: rows, by: 1000) {
            let entries = (start..<start + 1000).map { index in
                (key: VectorCache.Key.text("prompt \(index)"), vector: Data((0..<MeaningVectors.vectorBytes).map { _ in
                    UInt8.random(in: 0...255)
                }))
            }
            try cache!.store(entries)
            try small.transaction {
                for entry in entries {
                    try small.run("INSERT INTO vectors(key, vec) VALUES(?, ?)", [.blob(entry.key.bytes), .blob(entry.vector)])
                }
            }
        }
        try small.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        var lookups = 0
        let keys = (0..<rows).map { VectorCache.Key.text("prompt \($0)") }
        let took = try ContinuousClock().measure {
            for start in stride(from: 0, to: rows, by: 1024) {
                lookups += try cache!.vectors(for: Array(keys[start..<min(start + 1024, rows)])).count
            }
        }
        #expect(lookups == rows)
        print("every vector looked up by key, 1,024 at a time (as the vector files are rebuilt): \(took)")
        cache = nil
        let eight = try Self.databaseSize(cacheURL)
        let four = try Self.size(folder.url.appendingPathComponent("small-pages.sqlite"))
        print("\(rows) vectors: \(eight / rows) bytes a vector on 8 KB pages, \(four / rows) on 4 KB; "
              + "the vector itself \(MeaningVectors.vectorBytes)")
    }

    static func size(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// The file and its write-ahead log.
    static func databaseSize(_ url: URL) throws -> Int {
        try size(url) + ((try? size(URL(fileURLWithPath: url.path + "-wal"))) ?? 0)
    }
}
