import Foundation
import Synchronization
import Testing
@testable import codiclens

/// The vector cache's daily prune: the day each entry was last used (written,
/// found, or referenced by the index), entries unused for a month taken out
/// once the index has caught up, the space handed back, and the system's
/// scheduler starting it from the File Index. On caches, folders and
/// databases in a temporary folder, on a test's own day.
struct VectorCachePruneTests {
    static let entry = VectorCacheTests.entry

    // MARK: - Last used

    @Test func anEntryIsUsedWhenWrittenFoundOrReferenced() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let day = TestDay(20_000)
        let cache = try Self.cache(in: folder, day: day)
        let (a, b, c) = (Self.entry(1), Self.entry(2), Self.entry(3))
        try cache.store([a, b, c])
        #expect(try Self.used(a.key, in: cache) == 20_000, "written")

        day.advance(by: 5)
        #expect(try Set(cache.vectors(for: [a.key, Self.entry(9).key]).keys) == [a.key])
        #expect(try Self.used(a.key, in: cache) == 20_005, "found")
        #expect(try Self.used(b.key, in: cache) == 20_000)
        #expect(try Self.used(Self.entry(9).key, in: cache) == nil, "a miss is no entry")

        day.advance(by: 5)
        let pruning = try cache.prune(keeping: [b.key])
        #expect(pruning.stamped == 1)
        #expect(try Self.used(b.key, in: cache) == 20_010, "referenced by the index")
        #expect(try Self.used(a.key, in: cache) == 20_005)

        try cache.store([c])
        #expect(try Self.used(c.key, in: cache) == 20_010, "written again: the same input came up")
    }

    @Test func aDayAlreadyStampedIsNotWrittenAgain() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let day = TestDay(20_000)
        let cache = try Self.cache(in: folder, day: day)
        let (a, b) = (Self.entry(1), Self.entry(2))
        try cache.store([a, b])
        let writes = try Writes(to: cache.url)

        _ = try cache.vectors(for: [a.key, b.key])
        #expect(!writes.happened(), "found today, used today already")
        try cache.store([a])
        #expect(!writes.happened(), "kept today, used today already")
        #expect(try cache.prune(keeping: [a.key, b.key]).stamped == 0)
        _ = writes.happened()

        day.advance(by: 1)
        _ = try cache.vectors(for: [a.key])
        #expect(writes.happened(), "a new day: written once")
        _ = try cache.vectors(for: [a.key, b.key])
        #expect(writes.happened(), "b's day was old")
        _ = try cache.vectors(for: [a.key, b.key])
        #expect(!writes.happened())
    }

    // MARK: - Prune

    @Test func aPruneTakesOutOnlyWhatWentUnusedForMoreThanAMonth() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let day = TestDay(1_000)
        let cache = try Self.cache(in: folder, day: day)
        let (unused, referenced, monthAndADay, month, fresh) =
            (Self.entry(1), Self.entry(2), Self.entry(3), Self.entry(4), Self.entry(5))
        try cache.store([unused, referenced])
        day.advance(by: 39)
        try cache.store([monthAndADay])
        day.advance(by: 1)
        try cache.store([month])
        day.advance(by: 30)
        try cache.store([fresh])

        let pruning = try cache.prune(keeping: [referenced.key])
        #expect(pruning.removed == 2)
        #expect(pruning.kept == 3)
        let left = try cache.vectors(for: [unused, referenced, monthAndADay, month, fresh].map(\.key))
        #expect(Set(left.keys) == [referenced.key, month.key, fresh.key])
        #expect(left[referenced.key] == referenced.vector)
    }

    @Test func whatTheIndexPointsToIsNeverPrunedHoweverOld() async throws {
        let f = try MeaningFixture()
        try f.make("a.md", contents: "the zebra budget")
        try TestMedia.picture(at: f.path("beach.png"))
        try await f.index()

        // An edit leaves the old text's vector behind.
        try f.make("a.md", contents: "the zebra budget, and a recipe")
        try f.setDate("a.md", Date().addingTimeInterval(60))
        f.contents.filesChanged(try f.events(["a.md"]))
        try await f.readContents()
        try await f.embedAll()
        #expect(f.cache.count == 3)
        // A later launch: the index is not new.
        f.close()
        try f.open()
        let referenced = try f.writer.vectorKeys()
        #expect(referenced.count == 2)

        let stamped = f.day.now
        f.day.advance(by: 100)
        #expect(try referenced.allSatisfy { try Self.used($0, in: f.cache) == stamped }, "nothing used them since")
        guard case .pruned(let pruning) = try f.cache.pruneIfCaughtUp(index: f.writer, sources: [f.root]) else {
            Issue.record("not pruned")
            return
        }
        #expect(pruning.removed == 1, "the text before the edit")
        #expect(pruning.kept == 2)
        #expect(pruning.stamped == 2)
        #expect(try referenced.allSatisfy { try Self.used($0, in: f.cache) == f.day.now })

        // Everything the index points to is still there: a new index embeds
        // nothing, and finds what it found.
        f.close()
        try f.removeIndex()
        try f.open()
        f.embedder.requests.withLock { $0 = [] }
        try await f.index()
        #expect(f.embedder.requests.withLock { $0 } == [])
        #expect(f.search("recipe").first?.name == "a.md")
        #expect(f.search("beach").first?.name == "beach.png")
    }

    @Test func theDailyPruneWaitsForTheIndexToCatchUp() async throws {
        let f = try MeaningFixture()
        try f.make("a.md", contents: "the zebra budget")
        try TestMedia.picture(at: f.path("beach.png"))
        #expect(try f.cache.pruneIfCaughtUp(index: f.writer, sources: [f.root]) == .deferred,
                "the index was made this session")
        f.close()
        try f.open()
        #expect(!f.writer.isNew, "a later launch")

        try f.crawl()
        #expect(try f.cache.pruneIfCaughtUp(index: f.writer, sources: [f.root]) == .deferred, "crawled, not read")
        try await f.readContents()
        #expect(try f.cache.pruneIfCaughtUp(index: f.writer, sources: [f.root]) == .deferred, "read, not embedded")
        try await f.embedAll()
        guard case .pruned = try f.cache.pruneIfCaughtUp(index: f.writer, sources: [f.root]) else {
            Issue.record("caught up, not pruned")
            return
        }
        #expect(try f.cache.pruneIfCaughtUp(index: f.writer, sources: [f.root]) == .done, "once a day")

        // A new fingerprint: every file waits to be embedded again.
        f.day.advance(by: 1)
        try f.writer.adoptMeaningFingerprint("another model")
        #expect(try f.cache.pruneIfCaughtUp(index: f.writer, sources: [f.root]) == .deferred, "the backfill is pending")

        // A schema bump: the index is read again and caught up within the
        // session, which still does not prune.
        try f.writer.db.execute("PRAGMA user_version = \(FileIndexSchema.version + 1)")
        f.close()
        try f.open()
        try await f.index()
        #expect(try f.count("SELECT COUNT(*) FROM files WHERE vec_state != 'done'") == 0)
        #expect(try f.cache.pruneIfCaughtUp(index: f.writer, sources: [f.root]) == .deferred, "rebuilt this session")
        f.close()
        try f.open()
        guard case .pruned = try f.cache.pruneIfCaughtUp(index: f.writer, sources: [f.root]) else {
            Issue.record("the launch after the rebuild did not prune")
            return
        }
    }

    // MARK: - Space

    @Test func aPruneHandsTheSpaceBackOnceATenthHasGone() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let day = TestDay(1_000)
        let cache = try Self.cache(in: folder, day: day)
        let entries = (0..<1_000).map(Self.entry)
        try cache.store(entries)
        // 50 go unused, then 60 more: a tenth of what is left only together.
        day.advance(by: 10)
        _ = try cache.vectors(for: entries[50...].map(\.key))
        day.advance(by: 10)
        _ = try cache.vectors(for: entries[110...].map(\.key))
        day.advance(by: 11)

        let first = try cache.prune(keeping: [])
        #expect(first.removed == 50)
        #expect(!first.vacuumed, "5%: the freed pages are left for new entries")

        day.advance(by: 10)
        let before = Self.diskBytes(cache.url)
        let second = try cache.prune(keeping: [])
        #expect(second.removed == 60)
        #expect(second.vacuumed)
        #expect(second.bytesBefore == before)
        #expect(Self.diskBytes(cache.url) == second.bytesAfter)
        #expect(second.bytesAfter < before * 95 / 100, "\(before) → \(second.bytesAfter) bytes")
        #expect(cache.count == 890)
        #expect(try cache.vectors(for: entries[110...].map(\.key)).count == 890)
        let left = try cache.vectors(for: [entries[500].key])
        #expect(left[entries[500].key] == entries[500].vector)
    }

    // MARK: - Version 1

    @Test func aCacheFromBeforeLastUsedIsKeptEveryEntryUsedToday() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = folder.url.appendingPathComponent("VectorCache.sqlite")
        let entries = (0..<3).map(Self.entry)
        do {
            // As the first cache left it on disk.
            let db = try SQLiteConnection(path: url.path, pageSize: VectorCache.pageSize)
            try db.execute("""
                CREATE TABLE vectors(key BLOB PRIMARY KEY, vec BLOB NOT NULL);
                CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
                PRAGMA user_version = 1;
                """)
            try db.run("INSERT INTO meta(key, value) VALUES('fingerprint', ?), ('id', 'the cache')",
                       [.text(VectorCache.fingerprint)])
            for entry in entries {
                try db.run("INSERT INTO vectors(key, vec) VALUES(?, ?)", [.blob(entry.key.bytes), .blob(entry.vector)])
            }
        }

        let day = TestDay(5_000)
        let cache = try VectorCache(url: url, today: day.clock)
        #expect(cache.id == "the cache", "not emptied: the index's keys still point into it")
        #expect(cache.count == 3)
        #expect(try entries.allSatisfy { try Self.used($0.key, in: cache) == 5_000 })

        day.advance(by: VectorCache.unusedDays)
        #expect(try cache.prune(keeping: []).removed == 0, "a month from the upgrade")
        day.advance(by: 1)
        #expect(try cache.prune(keeping: []).removed == 3)
    }

    // MARK: - Helpers

    private static func cache(in folder: TemporaryFolder, day: TestDay) throws -> VectorCache {
        try VectorCache(url: folder.url.appendingPathComponent("VectorCache.sqlite"), today: day.clock)
    }

    /// The day `key` was last used, read from the file.
    private static func used(_ key: VectorCache.Key, in cache: VectorCache) throws -> Int64? {
        let db = try SQLiteConnection(path: cache.url.path)
        var day: Int64?
        try db.query("SELECT day FROM used WHERE key = ?", [.blob(key.bytes)]) { day = $0.int(0) }
        return day
    }

    /// The database and its log, as the disk has them.
    static func diskBytes(_ url: URL) -> Int64 {
        [url.path, url.path + "-wal"].reduce(0) { bytes, path in
            bytes + (((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
}

/// Whether anything was written to a database since the last call: SQLite's
/// `data_version`, read from a connection of its own, moves when another
/// connection commits a change.
private final class Writes {
    private let db: SQLiteConnection
    private var last: Int64 = 0

    init(to url: URL) throws {
        db = try SQLiteConnection(path: url.path)
        last = version
    }

    private var version: Int64 {
        var version: Int64 = 0
        try? db.query("PRAGMA data_version") { version = $0.int(0) }
        return version
    }

    func happened() -> Bool {
        let now = version
        defer { last = now }
        return now != last
    }
}

/// The prune as the app schedules it: from `FileIndex.start()`, on the File
/// Index's queue, deferred until the index has caught up.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VectorCachePruneScheduleTests {
    @Test func theAppAsksTheSystemForADailyBackgroundSlot() {
        let scheduler = NSBackgroundActivityScheduler.vectorCachePrune()
        #expect(scheduler.repeats)
        #expect(scheduler.interval == 24 * 60 * 60)
        #expect(scheduler.tolerance == 12 * 60 * 60)
        #expect(scheduler.qualityOfService == .background)
        #expect(scheduler.identifier.hasSuffix(".vector-cache-prune"))
    }

    @Test func theFileIndexPrunesFromItsScheduleOnceCaughtUp() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.makeFolder("Source")
        try folder.makeFile("Source/notes.md", contents: "the smoothie")
        let databaseURL = folder.url.appendingPathComponent("FileIndex.sqlite")
        let cacheURL = VectorCache.url(besideDatabase: databaseURL)
        // Left two months ago by a file long gone.
        let today = VectorCache.day(of: Date())
        try VectorCache(url: cacheURL, today: { today - 60 }).store([VectorCachePruneTests.entry(1)])

        // The first launch makes the index: never pruned in that session.
        let first = HeldSchedule()
        do {
            let index = try Self.fileIndex(in: folder, prune: first)
            #expect(first.count == 0, "nothing before start()")
            index.start()
            #expect(first.count == 1)
            #expect(await first.run() == .deferred)
            await Self.waitUntil(index) { index.meaningCounts.files == 1 && index.meaningCounts.embedded == 1 }
            #expect(await first.run() == .deferred, "caught up, but the index is new this session")
            index.stop()
            #expect(first.isInvalidated)
        }
        #expect(try VectorCache(url: cacheURL).count == 2)

        // The next launch prunes once it is caught up.
        let second = HeldSchedule()
        let index = try Self.fileIndex(in: folder, prune: second)
        defer { index.stop() }
        index.start()
        await Self.waitUntil(index) { index.meaningCounts.files == 1 && index.meaningCounts.embedded == 1 }
        #expect(await second.run() == .finished)
        let cache = try VectorCache(url: cacheURL)
        #expect(cache.count == 1, "the old entry went, the note's stayed")
        #expect(try cache.vectors(for: [VectorCachePruneTests.entry(1).key]).isEmpty)
        #expect(await second.run() == .finished, "already today")
    }

    private static func fileIndex(in folder: TemporaryFolder, prune: HeldSchedule) throws -> FileIndex {
        try folder.makeFolder("models")
        for file in StubDownloader.files {
            try StubDownloader.contents[file.name]!.write(to: folder.url.appendingPathComponent("models/\(file.name)"))
        }
        let defaults = ThrowawayDefaults()
        defaults.set([folder.path("Source")], forKey: "codiclens.sources.folders")
        let files = ModelFiles(folder: folder.url.appendingPathComponent("models"), files: StubDownloader.files,
                               downloader: StubDownloader())
        return FileIndex(
            databaseURL: folder.url.appendingPathComponent("FileIndex.sqlite"),
            sources: SourceStore(defaults: defaults),
            meaning: MeaningSettings(files: files, switch: MeaningSettings.Switch(isOn: true, save: { _ in }),
                                     isSupported: true),
            indexEmbedder: KeywordEmbedder(),
            queryEncoder: KeywordEmbedder(),
            prune: prune
        )
    }

    private static func waitUntil(_ index: FileIndex, _ condition: @escaping @MainActor () -> Bool) async {
        while !condition() {
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = index.generation
                    _ = index.meaningCounts
                } onChange: { continuation.resume() }
            }
        }
    }
}

/// A background schedule the test runs by hand, as the system would: the
/// block, and the result it hands back.
private final class HeldSchedule: BackgroundSchedule, @unchecked Sendable {
    private typealias Block = @Sendable (@escaping NSBackgroundActivityScheduler.CompletionHandler) -> Void
    private let blocks = Mutex<[Block]>([])
    private let invalidated = Mutex(false)

    var count: Int { blocks.withLock { $0.count } }
    var isInvalidated: Bool { invalidated.withLock { $0 } }

    func schedule(_ block: @escaping @Sendable (@escaping NSBackgroundActivityScheduler.CompletionHandler) -> Void) {
        blocks.withLock { $0.append(block) }
    }

    func invalidate() {
        invalidated.withLock { $0 = true }
    }

    func run() async -> NSBackgroundActivityScheduler.Result {
        guard let block = blocks.withLock({ $0.first }) else { return .finished }
        return await withCheckedContinuation { continuation in
            block { continuation.resume(returning: $0) }
        }
    }
}
