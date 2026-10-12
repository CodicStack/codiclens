import Foundation
import Synchronization
import Testing
@testable import codiclens

/// The vector cache: keys are exactly what was embedded, the meaning pass
/// looks there before it asks the helper, and the vectors outlive the index —
/// a schema bump, a Source removed and added again, a fresh database — and
/// come over from an index of the schema before it. On real folders and
/// databases in a temporary folder, with `KeywordEmbedder` counting requests.
struct VectorCacheTests {

    // MARK: - Keys

    @Test func aKeyIsExactlyWhatWasEmbedded() {
        let prompt = EmbeddingPrompt.document(title: "notes", text: "the smoothie we liked")
        #expect(VectorCache.Key.text(prompt) == .text(prompt))
        #expect(VectorCache.Key.text(prompt).bytes.count == 16)
        #expect(VectorCache.Key.text(prompt) != .text(prompt + " "), "one character more is another input")
        #expect(VectorCache.Key.text(prompt) != .text(EmbeddingPrompt.document(title: "recipes", text: "the smoothie we liked")),
                "the title is part of the prompt")

        let file = FileDigest(sha256: "ab12", stamp: .init(size: 10, mtime: 1))
        let edited = FileDigest(sha256: "cd34", stamp: .init(size: 10, mtime: 1))
        let moved = FileDigest(sha256: "ab12", stamp: .init(size: 10, mtime: 99))
        #expect(VectorCache.Key.picture(file, budget: .photo) == .picture(moved, budget: .photo),
                "the bytes, not the file's date or place")
        #expect(VectorCache.Key.picture(file, budget: .photo) != .picture(edited, budget: .photo))
        #expect(VectorCache.Key.picture(file, budget: .photo) != .picture(file, budget: .screenshot))
        #expect(VectorCache.Key.page(file, number: 2) != .page(file, number: 3))
        #expect(VectorCache.Key.page(file, number: 2) != .picture(file, budget: .pdfPage))
        #expect(VectorCache.Key.frame(file, at: 3.5) != .frame(file, at: 6.5))
        #expect(VectorCache.Key.sound(file, from: 0, to: 30) != .sound(file, from: 0, to: 25))
        #expect(VectorCache.Key.sound(file, from: 25, to: 55) == .sound(file, from: 25, to: 55))
    }

    @Test func theSameInputInTwoFilesIsOneKeyAndOneRequest() async throws {
        let f = try MeaningFixture()
        try f.make("A/notes.md", contents: "Blend banana and berries: the smoothie we liked.")
        try f.make("B/notes.md", contents: "Blend banana and berries: the smoothie we liked.")
        try TestMedia.picture(at: f.path("beach.png"))
        try FileManager.default.createDirectory(atPath: f.path("Copy"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: f.path("beach.png"), toPath: f.path("Copy/beach.png"))
        try await f.index()

        let requests = f.embedder.requests.withLock { $0 }
        #expect(requests.filter { $0.hasPrefix("text ") }.count == 1)
        #expect(requests.filter { $0.hasPrefix("image ") }.count == 1)
        #expect(try f.count("SELECT COUNT(DISTINCT vec_key) FROM segments WHERE vec_key IS NOT NULL") == 2)
        #expect(try f.count("SELECT COUNT(*) FROM segments WHERE vec_key IS NOT NULL") == 4)
        #expect(f.cache.count == 2)
        #expect(f.vectors.liveCount == 4, "each file has its vector in the search")
    }

    // MARK: - The cache first

    @Test func theHelperIsAskedOnlyForWhatTheCacheLacks() async throws {
        let f = try MeaningFixture()
        try f.make("a.md", contents: "the zebra budget")
        try TestMedia.picture(at: f.path("zebra.png"))
        try await f.index()
        #expect(f.embedder.requests.withLock { $0 }.count == 2)

        // A new database beside the same cache: everything is read again,
        // nothing is embedded again.
        f.close()
        try f.removeIndex()
        try f.open()
        f.embedder.requests.withLock { $0 = [] }
        try await f.index()
        #expect(f.embedder.requests.withLock { $0 } == [])
        #expect(f.vectors.liveCount == 2)
        #expect(f.search("zebra").map(\.name).sorted() == ["a.md", "zebra.png"])

        try f.make("a.md", contents: "the zebra budget, and a recipe")
        try f.setDate("a.md", Date().addingTimeInterval(60))
        let changed = try f.events(["a.md"])
        f.contents.filesChanged(changed)
        try await f.readContents()
        try await f.embedAll()
        #expect(f.embedder.requests.withLock { $0 } == ["text title: a | text: the zebra budget, and a recipe"])
    }

    @Test func aSchemaBumpRebuildsTheIndexWithoutAskingTheHelper() async throws {
        let f = try MeaningFixture()
        try await f.makeEveryKind()
        try await f.index()
        let vectors = f.vectors.liveCount
        let kinds = try f.vectorKinds()
        let found = try f.answers()
        #expect(kinds == ["audio", "chunk", "frame", "image", "page", "page_image"])
        #expect(f.embedder.requests.withLock { $0 }.count == f.cache.count)

        // An index of another version is dropped and read again.
        try f.writer.db.execute("PRAGMA user_version = \(FileIndexSchema.version + 1)")
        f.close()
        f.embedder.requests.withLock { $0 = [] }
        try f.open()
        #expect(try f.count("SELECT COUNT(*) FROM files") == 0, "dropped")
        try await f.index()

        #expect(f.embedder.requests.withLock { $0 } == [], "every vector came from the cache")
        #expect(f.vectors.liveCount == vectors)
        #expect(try f.vectorKinds() == kinds)
        #expect(try f.answers() == found)
        #expect(try f.count("SELECT COUNT(*) FROM files WHERE vec_state != 'done'") == 0)
    }

    @Test func theCacheOutlivesASourceRemovedAndAddedAgain() async throws {
        let f = try MeaningFixture()
        try f.make("a.md", contents: "the zebra budget")
        try TestMedia.wav(at: f.path("standup.wav"), seconds: 40)
        try await f.index()
        let vectors = f.vectors.liveCount

        _ = try f.indexer.setSources([])
        #expect(try f.count("SELECT COUNT(*) FROM files") == 0)
        #expect(f.vectors.liveCount == 0)

        f.embedder.requests.withLock { $0 = [] }
        try await f.index()
        #expect(f.embedder.requests.withLock { $0 } == [])
        #expect(f.vectors.liveCount == vectors)
    }

    // MARK: - Clearing

    @Test func aNewModelFingerprintClearsTheCacheAndTheIndexEmbedsAgain() async throws {
        let f = try MeaningFixture()
        try f.make("a.md", contents: "the zebra budget")
        try await f.index()
        let id = f.cache.id
        f.close()

        #expect(try VectorCache(url: f.cacheURL).id == id, "the same fingerprint keeps it")
        let other = try VectorCache(url: f.cacheURL, fingerprint: "another model")
        #expect(other.count == 0)
        #expect(other.id != id)
        // And back: the model changed again, so it is emptied again.
        #expect(try VectorCache(url: f.cacheURL).count == 0)

        f.embedder.requests.withLock { $0 = [] }
        try f.open()
        #expect(f.vectors.liveCount == 0, "its keys point into a cache that no longer has them")
        try await f.embedAll()
        #expect(f.embedder.requests.withLock { $0 }.count == 1)
        #expect(f.vectors.liveCount == 1)
        #expect(f.cache.count == 1)
    }

    @Test func aDeletedCacheMakesTheIndexEmbedAgain() async throws {
        let f = try MeaningFixture()
        try f.make("a.md", contents: "the zebra budget")
        try await f.index()
        f.close()
        try f.removeCache()

        f.embedder.requests.withLock { $0 = [] }
        try f.open()
        #expect(f.vectors.liveCount == 0)
        try await f.embedAll()
        #expect(f.embedder.requests.withLock { $0 }.count == 1)
        #expect(f.search("zebra").map(\.name) == ["a.md"])
    }

    @Test func removeEmptiesTheCache() async throws {
        let f = try MeaningFixture()
        try f.make("a.md", contents: "the zebra budget")
        try await f.index()
        let id = f.cache.id
        try f.cache.removeAll()
        #expect(f.cache.count == 0)
        #expect(f.cache.id != id)
    }

    // MARK: - What is kept

    @Test func aPictureThatChangesWhileItIsEmbeddedIsNotKept() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let path = folder.path("beach.png")
        try TestMedia.picture(at: path)
        let cache = try VectorCache(url: folder.url.appendingPathComponent("VectorCache.sqlite"))
        let job = MeaningJob(id: 1, path: path, content: .image, size: 1, mtime: 0, isFirstStep: true, vecTo: 0)

        let editing = RewritingEmbedder(path: path)
        let edited = try await MeaningReader.read(job, with: editing, cache: cache)
        #expect(edited.vectors.count == 1, "the writer drops it: the file is not the one the job was for")
        #expect(cache.count == 0, "whatever the helper read, it was not the bytes the key names")

        let settled = try await MeaningReader.read(job, with: KeywordEmbedder(), cache: cache)
        #expect(settled.vectors.count == 1)
        #expect(cache.count == 1)
    }

    @Test func concurrentWritesAreSafe() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = folder.url.appendingPathComponent("VectorCache.sqlite")
        // Two connections on one file, as two File Indexes or a helper would have.
        let caches = [try VectorCache(url: url), try VectorCache(url: url)]
        let entry = Self.entry

        // Eight writers, each 40 batches of 25, every batch overlapping the
        // writer before it by half, reading back what it wrote as it goes.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for writer in 0..<8 {
                group.addTask {
                    let cache = caches[writer % 2]
                    for batch in 0..<40 {
                        let start = writer * 500 + batch * 25 - (writer > 0 ? 250 : 0)
                        let entries = (start..<start + 25).map(entry)
                        try cache.store(entries)
                        let found = try cache.vectors(for: entries.map(\.key))
                        #expect(found.count == 25)
                    }
                }
            }
            try await group.waitForAll()
        }

        let distinct = Set((0..<8).flatMap { writer in
            (0..<40).flatMap { batch in
                let start = writer * 500 + batch * 25 - (writer > 0 ? 250 : 0)
                return Array(start..<start + 25)
            }
        })
        #expect(caches[0].count == distinct.count)
        let keys = distinct.sorted().map { entry($0).key }
        let found = try caches[1].vectors(for: keys)
        #expect(distinct.allSatisfy { found[entry($0).key] == entry($0).vector })
    }

    static func entry(_ index: Int) -> (key: VectorCache.Key, vector: Data) {
        (.text("prompt \(index)"), EmbeddingVector.float16Data(KeywordEmbedder.vector(for: "budget \(index)")))
    }

    @Test func theSchedulersStepsCanRunSideBySideOnOneCache() async throws {
        let f = try MeaningFixture()
        for index in 0..<12 { try f.make("n\(index).md", contents: "note \(index) about the budget") }
        for index in 0..<6 { try TestMedia.picture(at: f.path("p\(index).png"), hue: CGFloat(index) / 6) }
        try f.crawl()
        try await f.readContents()
        let jobs = try f.writer.meaningJobs(limit: 100, sources: [f.root])
        #expect(jobs.count == 18)

        // Every job at once, each with a cache of its own on the one file.
        let cacheURL = f.cacheURL
        let embedder = f.embedder
        let results = try await withThrowingTaskGroup(of: MeaningResult.self) { group in
            for job in jobs {
                group.addTask { try await MeaningReader.read(job, with: embedder, cache: VectorCache(url: cacheURL)) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.allSatisfy { $0.vectors.count == 1 })
        #expect(f.cache.count == 18)
    }

    // MARK: - Seeding

    @Test func anIndexOfTheOldSchemaHandsItsVectorsToTheCacheBeforeItIsDropped() async throws {
        let f = try MeaningFixture()
        try await f.makeEveryKind()
        try await f.index()
        let vectors = f.vectors.liveCount
        let found = try f.answers()
        let recording = try f.count("""
            SELECT COUNT(*) FROM segments s JOIN files f ON f.id = s.file
            WHERE f.path LIKE '%standup.wav' AND s.vec_key IS NOT NULL
            """)
        #expect(recording == 2)
        let entries = f.cache.count
        try f.makeSchema4()
        // Changed since it was embedded: its vectors cannot be keyed now.
        try f.setDate("standup.wav", Date().addingTimeInterval(120))
        f.close()
        try f.removeCache()

        f.embedder.requests.withLock { $0 = [] }
        try f.open()
        #expect(f.cache.count == entries - recording, "everything but the changed recording")
        try await f.index()

        #expect(f.embedder.requests.withLock { $0 }.sorted() == ["audio standup.wav 0+30", "audio standup.wav 25+15"])
        #expect(f.vectors.liveCount == vectors)
        #expect(try f.answers() == found)
    }

    @Test func seedingWantsTodaysFingerprint() async throws {
        let f = try MeaningFixture()
        try f.make("a.md", contents: "the zebra budget")
        try await f.index()
        try f.makeSchema4()
        try f.writer.db.run("UPDATE meta SET value = 'another model' WHERE key = 'meaning'")
        f.close()
        try f.removeCache()

        try f.open()
        #expect(f.cache.count == 0, "its vectors were made with something else")
    }
}

/// Rewrites the picture it is asked about, as if the user saved over it
/// while the helper was reading it.
private final class RewritingEmbedder: MeaningEmbedder, @unchecked Sendable {
    let path: String

    init(path: String) {
        self.path = path
    }

    func embed(texts: [String]) async throws -> [[Float]] { texts.map(KeywordEmbedder.vector(for:)) }

    func embedImage(at url: URL, budget: ImageBudget) async throws -> [Float] {
        try TestMedia.picture(at: path, hue: 0.9)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: path)
        return KeywordEmbedder.vector(for: url.lastPathComponent)
    }

    func embedImage(data: Data, budget: ImageBudget) async throws -> [Float] { KeywordEmbedder.vector(for: "picture") }

    func embedAudio(at url: URL, from start: TimeInterval, duration: TimeInterval) async throws -> [Float] {
        KeywordEmbedder.vector(for: "sound")
    }

    func setFullSpeed(_ isFullSpeed: Bool) async {}
}

extension MeaningFixture {
    /// One of everything the meaning pass embeds: a note, a photo, a
    /// screenshot, a PDF with a page drawn as a picture, a recording, a video
    /// with a soundtrack, and notes to give a Query's scale something to
    /// stand out from.
    func makeEveryKind() async throws {
        try make("notes.md", contents: "Blend banana and berries: the smoothie we liked.")
        try TestMedia.picture(at: path("beach.jpg"))
        try TestMedia.picture(at: path("Screenshot 2025-01-01 at 10.00.00.png"), hue: 0.6)
        let full = String(repeating: "The lease runs a year and the rent is paid monthly. ", count: 6)
        try FileContentReaderTests.makePDF(at: path("lease.pdf"), pages: [full, "Scan", full])
        try TestMedia.wav(at: path("standup.wav"), seconds: 40)
        let tone = folder.path("tone.wav")
        try TestMedia.wav(at: tone, seconds: 12)
        try await TestMedia.movie(at: path("music.mov"), seconds: 12, shot: 4, audio: URL(fileURLWithPath: tone))
        try makeFillers()
    }

    /// The kinds of segment that have a vector.
    func vectorKinds() throws -> [String] {
        var kinds: [String] = []
        try writer.db.query("SELECT DISTINCT kind FROM segments WHERE vec_key IS NOT NULL ORDER BY kind") {
            kinds.append($0.text(0) ?? "")
        }
        return kinds
    }

    /// What a few Queries find, by name and where.
    func answers() throws -> [String] {
        ["smoothie", "lease picture", "beach", "music sound", "meeting"].flatMap { query in
            search(query).map { "\(query): \($0.name) \($0.passage?.subtitle ?? "")" }
        }
    }

    /// The database files and the vector files; the cache stays.
    func removeIndex() throws {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        let vectors = MeaningVectors(databaseURL: url)
        try FileManager.default.removeItem(at: vectors.vectorsURL)
        try FileManager.default.removeItem(at: vectors.rowsURL)
    }

    func removeCache() throws {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: cacheURL.path + suffix) }
    }

    /// Turns the index into one of schema 4, as an installed app left it:
    /// each vector in `segments.vec`, no keys, no cache recorded.
    func makeSchema4() throws {
        var keys: [(segment: Int64, key: VectorCache.Key)] = []
        try writer.db.query("SELECT id, vec_key FROM segments WHERE vec_key IS NOT NULL") {
            keys.append(($0.int(0), VectorCache.Key(bytes: $0.blob(1)!)))
        }
        let vectors = try cache.vectors(for: keys.map(\.key))
        try writer.db.transaction {
            try writer.db.execute("ALTER TABLE segments ADD COLUMN vec BLOB")
            for (segment, key) in keys {
                try writer.db.run("UPDATE segments SET vec = ? WHERE id = ?", [.blob(try #require(vectors[key])), .int(segment)])
            }
            try writer.db.execute("""
                ALTER TABLE segments DROP COLUMN vec_key;
                DELETE FROM meta WHERE key = 'vector_cache';
                PRAGMA user_version = 4;
                """)
        }
    }
}
