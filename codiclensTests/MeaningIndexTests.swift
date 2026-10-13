import Foundation
import Synchronization
import Testing
@testable import codiclens

/// Search by meaning's half of the File Index end to end, on a real folder
/// and database with `KeywordEmbedder` standing in for the model: what the
/// meaning pass embeds and in what order, what it stores, the vector files,
/// and the settled search that fuses meaning with words.
struct MeaningIndexTests {

    // MARK: - Scheduling

    @Test func theBackfillEmbedsByKindCodeLastNewestFirst() async throws {
        let f = try MeaningFixture()
        let now = Date()
        try f.make("main.swift", contents: "let budget = 1")
        try f.make("older.md", contents: "an older note")
        try f.make("newer.md", contents: "a newer note")
        try f.make("letter.html", contents: "<p>a letter about the lease</p>")
        try TestMedia.picture(at: f.path("Screenshot 2025-01-01 at 10.00.00.png"))
        try TestMedia.picture(at: f.path("beach.jpg"))
        try FileContentReaderTests.makePDF(at: f.path("a.pdf"), pages: [String(repeating: "The lease runs a year. ", count: 12)])
        try TestMedia.wav(at: f.path("tone.wav"), seconds: 3)
        try await TestMedia.movie(at: f.path("clip.mov"), seconds: 4)
        try f.setDate("older.md", now.addingTimeInterval(-3600))
        try f.setDate("newer.md", now)
        try f.crawl()
        try await f.readContents()

        let batches = try await f.embedAll()

        #expect(batches == [
            ["Screenshot 2025-01-01 at 10.00.00.png", "beach.jpg"],
            ["a.pdf"],
            ["letter.html", "newer.md", "older.md"],
            ["tone.wav"],
            ["clip.mov"],
            ["main.swift"],
        ], "pictures and text eight at a time, a PDF, a recording or a video alone")
        #expect(try f.count("SELECT COUNT(*) FROM files WHERE vec_state != 'done'") == 0)
    }

    @Test func aFileWaitsForTheContentsPassBeforeItsTextIsEmbedded() async throws {
        let f = try MeaningFixture()
        try f.make("note.md", contents: "about the budget")
        try TestMedia.picture(at: f.path("zebra.png"))
        try f.crawl()

        #expect(try await f.embedAll() == [["zebra.png"]], "a picture has no words to wait for")
        try await f.readContents()
        #expect(try await f.embedAll() == [["note.md"]])
    }

    @Test func lowPowerModePausesTheBackfillButNotChangedFiles() async throws {
        let f = try MeaningFixture()
        try TestMedia.picture(at: f.path("old.png"))
        try f.crawl()
        f.meaning.setLowPower(true)
        #expect(try f.meaning.nextBatch().isEmpty)

        try TestMedia.picture(at: f.path("new.png"), hue: 0.8)
        let changed = try f.events(["new.png"])
        f.meaning.filesChanged(changed)
        #expect(try await f.embedAll() == [["new.png"]])

        f.meaning.setLowPower(false)
        #expect(try await f.embedAll() == [["old.png"]])
    }

    @Test func aChangedTextFileGoesFirstOnceItsContentsAreRead() async throws {
        let f = try MeaningFixture()
        for index in 0..<3 { try TestMedia.picture(at: f.path("p\(index).png"), hue: CGFloat(index) / 4) }
        try f.crawl()
        f.meaning.setLowPower(true)

        try f.make("fresh.md", contents: "the meeting moved")
        let changed = try f.events(["fresh.md"])
        f.meaning.filesChanged(changed)
        #expect(try f.meaning.nextBatch().isEmpty, "not read yet: it waits, and the backfill is paused")

        f.contents.filesChanged(changed)
        try await f.readContents()
        #expect(try await f.embedAll() == [["fresh.md"]])
    }

    @Test func aBurstOfChangesIsCapped() async throws {
        let f = try MeaningFixture()
        try f.crawl()
        let names = (0..<(MeaningScheduler.burstCap + 10)).map { "n\($0).txt" }
        for name in names { try f.make(name, contents: "note \(name)") }
        let changed = try f.events(names)
        f.contents.filesChanged(changed)
        f.contents.setLowPower(true)
        f.meaning.setLowPower(true)
        try await f.readContents()
        f.meaning.filesChanged(changed)

        let embedded = try await f.embedAll().joined().count
        #expect(embedded == MeaningScheduler.burstCap, "the rest wait for the backfill")
    }

    @Test func aLongFileIsEmbeddedAStepAtATimeAndItsLaterStepsDoNotSetTheScale() async throws {
        let f = try MeaningFixture()
        let words = (0..<30000).map { "budget\($0 % 7) word\($0)" }.joined(separator: " ")
        try f.make("big.txt", contents: words)
        try f.make("small.txt", contents: "a small note about a recipe")
        try f.setDate("big.txt", Date().addingTimeInterval(-60))
        try f.crawl()
        try await f.readContents()

        let batches = try await f.embedAll()
        #expect(batches.first == ["small.txt", "big.txt"], "every file's first step first")
        #expect(batches.count > 2 && batches.dropFirst().allSatisfy { $0 == ["big.txt"] })
        let first = try f.count("SELECT COUNT(*) FROM segments WHERE vec_key IS NOT NULL AND later = 0")
        let later = try f.count("SELECT COUNT(*) FROM segments WHERE vec_key IS NOT NULL AND later = 1")
        #expect(first == MeaningPass.firstChunks + 1)
        #expect(later > 0)
        #expect(try f.count("SELECT COUNT(*) FROM segments WHERE kind = 'chunk' AND vec_key IS NULL") == 0)
        let snapshot = try #require(f.vectors.snapshot())
        #expect(snapshot.rows.setsScale.filter { $0 }.count == first)
    }

    @Test func passagesWithoutWordsArePassedNotWaitedFor() async throws {
        let f = try MeaningFixture()
        let numbers = (0..<4000).map { String($0 * 7919 % 100_000) }.joined(separator: " ")
        try f.make("table.csv", contents: numbers + String(repeating: " and words about the budget", count: 120))
        try f.crawl()
        try await f.readContents()

        var batches = 0
        while try !f.meaning.nextBatch().isEmpty {
            batches += 1
            try #require(batches < 10, "the same file handed out again and again")
            try await f.meaning.readBatch()
        }
        #expect(try f.count("SELECT COUNT(*) FROM files WHERE vec_state != 'done'") == 0)
        #expect(try f.count("SELECT COUNT(*) FROM segments WHERE vec_key IS NULL") > 0, "digits get no vector")
        #expect(try f.count("SELECT COUNT(*) FROM segments WHERE vec_key IS NOT NULL") >= 1)
    }

    // MARK: - Data and logs

    @Test func dataAndLogsAreRecognisedByName() {
        for path in ["/u/a/data.json", "/u/a/rows.JSONL", "/u/a/x.ndjson", "/u/a/map.geojson", "/u/a/adult.csv",
                     "/u/a/t.tsv", "/u/a/app.log", "/u/a/run.err", "/u/a/run.out", "/u/a/output/logs/log_iter_20.txt",
                     "/u/a/Logs/2024/day.txt", "/u/a/log/notes.txt", "/u/a/train.log.txt", "/u/a/log_run.txt"] {
            #expect(FileContent.isDataOrLog(path), "\(path)")
        }
        for path in ["/u/a/notes.txt", "/u/a/blog/post.txt", "/u/a/catalog.txt", "/u/a/logs/readme.md",
                     "/u/a/logs/main.swift", "/u/a/dialog.txt", "/u/a/json/notes.md", "/u/a/login.txt"] {
            #expect(!FileContent.isDataOrLog(path), "\(path)")
        }
    }

    /// A JSON Lines file of ~520 chunks with one word nowhere else, in
    /// about its 500th.
    private static func jsonLines(rare: String) -> String {
        (0..<13_500).map { line in
            #"{"id": \#(line), "note": "the budget entry for line \#(line) \#(line == 13_000 ? rare : "went fine")"}"#
        }.joined(separator: "\n")
    }

    @Test func dataGetsVectorsForItsFirstFortyChunksAndIsFoundByAnyWord() async throws {
        #expect(FileContentReader.firstStep >= MeaningPass.firstChunks, "the first step holds the first 40 chunks")
        let f = try MeaningFixture()
        try f.make("events.jsonl", contents: Self.jsonLines(rare: "zanzibar"))
        try f.crawl()
        // The first steps of both passes, then the rest of the contents: a
        // later contents step does not hand the file back to the meaning pass.
        try await f.contents.readBatch()
        try await f.embedAll()
        try await f.readContents()
        #expect(try f.meaning.nextBatch().isEmpty)

        let id = try f.id("events.jsonl")
        var chunks: [(id: Int64, hasVector: Bool)] = []
        try f.writer.db.query("SELECT id, vec_key IS NOT NULL FROM segments WHERE file = ? AND kind = 'chunk' ORDER BY id",
                              [.int(id)]) { chunks.append(($0.int(0), $0.int(1) != 0)) }
        #expect(chunks.count > 500)
        #expect(chunks.prefix(MeaningPass.firstChunks).allSatisfy { $0.hasVector })
        #expect(!chunks.dropFirst(MeaningPass.firstChunks).contains { $0.hasVector })

        var rare: Int64 = 0
        try f.writer.db.query("SELECT rowid FROM passages WHERE passages MATCH 'zanzibar'") { rare = $0.int(0) }
        let index = try #require(chunks.firstIndex { $0.id == rare })
        #expect(index > 450, "chunk \(index)")
        let hit = try #require(f.reader.search("zanzibar", limit: 10, sources: [f.root]).first)
        #expect(hit.name == "events.jsonl")
        #expect(hit.passage != nil, "found by the word, in its Passage")
        #expect(f.search("zanzibar").first?.name == "events.jsonl", "and by the settled search")

        #expect(try f.count("SELECT COUNT(*) FROM files WHERE vec_state != 'done' OR state != 'done'") == 0)
        #expect(try f.writer.isCaughtUp(sources: [f.root]))
        let counts = f.reader.meaningCounts(sources: [f.root])
        #expect(counts.files == 1 && counts.embedded == 1)
        #expect(f.reader.counts()[f.root].map { $0.indexed == $0.total } == true)
    }

    @Test func aTextFileInALogsFolderIsALogAndANoteBesideItIsNot() async throws {
        let f = try MeaningFixture()
        let long = (0..<9_000).map { "the budget meeting went fine \($0)" }.joined(separator: "\n")
        try f.make("output/logs/log_iter_20.txt", contents: long)
        try f.make("notes/minutes.txt", contents: long)
        try await f.index()

        func vectors(_ relative: String) throws -> Int {
            var count = 0
            try f.writer.db.query("SELECT COUNT(*) FROM segments WHERE file = ? AND vec_key IS NOT NULL",
                                  [.int(try f.id(relative))]) { count = Int($0.int(0)) }
            return count
        }
        #expect(try vectors("output/logs/log_iter_20.txt") == MeaningPass.firstChunks)
        #expect(try vectors("notes/minutes.txt") > MeaningPass.firstChunks)
        #expect(try f.count("SELECT COUNT(*) FROM files WHERE vec_state != 'done'") == 0)
    }

    @Test func dataEmbeddedPastItsFirstStepBeforeTheCapKeepsItsVectorsAndIsDoneWithoutTheHelper() async throws {
        let f = try MeaningFixture()
        try f.make("events.jsonl", contents: Self.jsonLines(rare: "zanzibar"))
        try await f.index()
        // As an index from before the cap left it: further along, waiting
        // for its next step.
        let id = try f.id("events.jsonl")
        try f.writer.db.run("""
            UPDATE segments SET vec_key = randomblob(16), later = 1 WHERE file = ? AND kind = 'chunk' AND vec_key IS NULL
                AND id IN (SELECT id FROM segments WHERE file = ? AND kind = 'chunk' ORDER BY id LIMIT 60 OFFSET 40)
            """, [.int(id), .int(id)])
        try f.writer.db.run("UPDATE files SET vec_state = 'partial' WHERE id = ?", [.int(id)])
        f.embedder.requests.withLock { $0 = [] }

        #expect(try await f.embedAll() == [["events.jsonl"]])
        #expect(f.embedder.requests.withLock { $0 }.isEmpty)
        #expect(try f.count("SELECT COUNT(*) FROM files WHERE vec_state != 'done'") == 0)
        #expect(try f.count("SELECT COUNT(*) FROM segments WHERE later = 1") == 60, "kept")
    }

    @Test func aBatchsTextsGoToTheHelperTogether() async throws {
        let f = try MeaningFixture()
        for name in ["a", "b", "c"] { try f.make("\(name).md", contents: "the \(name) budget") }
        try await f.index()

        #expect(f.embedder.textCalls.withLock { $0 } == [3])
        #expect(try f.count("SELECT COUNT(*) FROM segments WHERE vec_key IS NOT NULL") == 3)
    }

    @Test func aFileThatCrashesTheHelperIsGivenUpNotRetried() async throws {
        let f = try MeaningFixture()
        try f.make("bad.md", contents: "this one says \(KeywordEmbedder.crash) and takes the helper down")
        try f.make("good.md", contents: "budget")
        try await f.index()

        #expect(try f.count("SELECT COUNT(*) FROM files WHERE vec_state != 'done'") == 0)
        var detail: String?
        try f.writer.db.query("SELECT detail FROM files WHERE path LIKE '%bad.md'") { detail = $0.text(0) }
        #expect(detail == "stopped the embedding helper")
        #expect(f.search("budget").map(\.name) == ["good.md"])
    }

    // MARK: - What is stored

    @Test func vectorsAreKeptInTheCacheAsNormalizedFloat16() async throws {
        let f = try MeaningFixture()
        try f.make("note.md", contents: "the zebra budget")
        try await f.index()

        var keys: [VectorCache.Key] = []
        try f.writer.db.query("SELECT vec_key FROM segments WHERE vec_key IS NOT NULL") {
            keys.append(VectorCache.Key(bytes: $0.blob(0)!))
        }
        #expect(keys.count == 1)
        let blobs = try keys.map { try #require(f.cache.vectors(for: [$0])[$0]) }
        #expect(blobs[0].count == EmbeddingVector.dimension * 2)
        let floats = try #require(EmbeddingVector.floats(float16Data: blobs[0]))
        let length = floats.reduce(0) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(length - 1) < 0.002)
        let expected = KeywordEmbedder.vector(for: "the zebra budget")
        #expect(zip(floats, expected).allSatisfy { abs($0 - $1) < 0.001 })
    }

    @Test func aScreenshotIsEmbeddedAsAPictureAndItsWordsStayKeywordOnly() async throws {
        let f = try MeaningFixture()
        try TestMedia.picture(at: f.path("Screenshot 2025-02-02 at 09.00.00.png"))
        try TestMedia.picture(at: f.path("beach.png"), hue: 0.7)
        try TestMedia.picture(at: f.path("icon.png"), width: 64, height: 64)
        try await f.index()

        #expect(f.embedder.requests.withLock { $0 }.sorted() == [
            "image Screenshot 2025-02-02 at 09.00.00.png 280", "image beach.png 140",
        ], "a screenshot at 280 soft tokens, a photo at 140, an icon not at all")
        #expect(try f.count("SELECT COUNT(*) FROM segments WHERE kind = 'image' AND vec_key IS NOT NULL") == 2)
        #expect(try f.count("SELECT COUNT(*) FROM segments WHERE kind = 'ocr' AND vec_key IS NOT NULL") == 0)
        var detail: String?
        try f.writer.db.query("SELECT detail FROM files WHERE path LIKE '%icon.png'") { detail = $0.text(0) }
        #expect(detail == "too small to embed")
    }

    @Test func aPDFPageWithLittleTextIsEmbeddedAsAPicture() async throws {
        let f = try MeaningFixture()
        let full = String(repeating: "The lease runs a year and the rent is paid monthly. ", count: 6)
        try FileContentReaderTests.makePDF(at: f.path("lease.pdf"), pages: [full, "Scan", full])
        try f.makeFillers()
        try await f.index()

        var segments: [String] = []
        try f.writer.db.query("""
            SELECT s.kind, s.loc, s.vec_key IS NOT NULL FROM segments s JOIN files f ON f.id = s.file
            WHERE f.path LIKE '%lease.pdf' ORDER BY s.loc
            """) { row in
            segments.append("\(row.text(0)!) \(Int(row.double(1))) \(row.int(2) == 1 ? "vector" : "none")")
        }
        #expect(segments == ["page 1 vector", "page_image 2 vector", "page 3 vector"])
        #expect(f.embedder.requests.withLock { $0 }.filter { $0.hasPrefix("data") } == ["data 280"])

        let hit = try #require(f.search("picture").first { $0.name == "lease.pdf" })
        #expect(hit.passage?.page == 2)
        #expect(hit.passage?.modality == .image)
        #expect(hit.passage?.subtitle == "page 2")
    }

    @Test func aRecordingIsWindowsOfSoundEachWithItsSpan() async throws {
        let f = try MeaningFixture()
        try TestMedia.wav(at: f.path("standup.wav"), seconds: 60)
        try TestMedia.wav(at: f.path("quiet.wav"), seconds: 40, silent: true)
        try f.makeFillers()
        try await f.index()

        var spans: [String] = []
        try f.writer.db.query("""
            SELECT s.loc, s.loc_end FROM segments s JOIN files f ON f.id = s.file
            WHERE f.path LIKE '%standup.wav' ORDER BY s.loc
            """) { spans.append("\(Int($0.double(0)))-\(Int($0.double(1)))") }
        #expect(spans == ["0-30", "25-55", "50-60"], "30 s windows every 25 s; the tail adds 5 s past the last")
        // The fake answers for silence too; the helper refuses it.
        #expect(try f.count("SELECT COUNT(*) FROM files WHERE vec_state = 'done' AND path LIKE '%quiet.wav'") == 1)

        let hit = try #require(f.search("meeting").first { $0.name == "standup.wav" })
        #expect(hit.meaning == .audio)
        #expect(hit.passage?.start != nil && hit.passage?.end != nil)
        #expect(hit.passage?.subtitle.hasPrefix("at 0:") == true)
    }

    @Test func aVideoIsItsFramesAndItsSoundtrackEachWithItsSpan() async throws {
        let f = try MeaningFixture()
        let tone = f.folder.path("tone.wav")
        try TestMedia.wav(at: tone, seconds: 20)
        try await TestMedia.movie(at: f.path("beach.mov"), seconds: 20, shot: 6, audio: URL(fileURLWithPath: tone))
        try await f.index()

        var frames: [(Double, Double)] = []
        var sound: [(Double, Double)] = []
        try f.writer.db.query("SELECT kind, loc, loc_end FROM segments ORDER BY loc") { row in
            let span = (row.double(1), row.double(2))
            if row.text(0) == "frame" { frames.append(span) } else if row.text(0) == "audio" { sound.append(span) }
        }
        #expect(frames.count >= 3 && frames.count <= 7, "one per shot of 6 s, not one per 3 s: \(frames)")
        #expect(frames.first?.0 ?? 99 < 1)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.1 == $1.0 }, "each frame stands until the next")
        #expect(abs((frames.last?.1 ?? 0) - 20) < 0.6)
        #expect(sound.count == 1 && sound[0].0 == 0 && abs(sound[0].1 - 20) < 0.6)
        #expect(f.embedder.requests.withLock { $0 }.filter { $0.hasPrefix("data") }.allSatisfy { $0 == "data 70" })
    }

    // MARK: - The vector files

    @Test func theVectorFilesGrowAsVectorsLandAndNeverReloadWhole() async throws {
        let f = try MeaningFixture()
        try f.make("a.md", contents: "budget")
        try await f.index()
        let first = try #require(f.vectors.snapshot())
        #expect(first.count == 1)

        try f.make("b.md", contents: "zebra")
        try f.make("c.md", contents: "recipe")
        let changed = try f.events(["b.md", "c.md"])
        f.contents.filesChanged(changed)
        try await f.readContents()
        try await f.embedAll()

        let second = try #require(f.vectors.snapshot())
        #expect(second.count == 3)
        #expect(first.count == 1, "a snapshot a search holds does not change under it")
        #expect(Array(second.rows.segment.prefix(1)) == first.rows.segment, "appended, nothing moved")
        let rowsFile = try FileManager.default.attributesOfItem(atPath: f.vectors.rowsURL.path)[.size] as? Int
        #expect(rowsFile == 3 * MeaningVectors.recordBytes)
        #expect(try f.writer.vectorRows() == 3)
    }

    @Test func aChangedOrDeletedFileTakesItsVectorsOutOfTheSearch() async throws {
        let f = try MeaningFixture()
        try f.make("a.md", contents: "budget")
        try f.make("b.md", contents: "zebra")
        try await f.index()
        #expect(f.vectors.liveCount == 2)

        try f.make("a.md", contents: "the smoothie recipe, longer now")
        try f.setDate("a.md", Date().addingTimeInterval(60))
        try FileManager.default.removeItem(atPath: f.path("b.md"))
        try f.events(["a.md", "b.md"])

        #expect(f.vectors.liveCount == 0)
        #expect(f.search("zebra").isEmpty)
        #expect(f.search("budget").isEmpty)
    }

    @Test func vectorFilesThatDoNotMatchTheDatabaseAreRebuiltFromIt() async throws {
        let f = try MeaningFixture()
        try f.make("a.md", contents: "budget")
        try f.make("b.md", contents: "zebra")
        try await f.index()
        f.close()
        // As if the app quit between the database's commit and the append.
        let rows = try Data(contentsOf: MeaningVectors(databaseURL: f.url).rowsURL)
        try rows.prefix(MeaningVectors.recordBytes).write(to: MeaningVectors(databaseURL: f.url).rowsURL)

        try f.open()

        #expect(f.vectors.liveCount == 2)
        #expect(f.search("zebra").first?.name == "b.md")
    }

    @Test func scoresAreTheCosineOfEveryRow() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let vectors = MeaningVectors(databaseURL: folder.url.appendingPathComponent("x.sqlite"))
        try vectors.rebuild { _ in }
        var expected: [Float] = []
        let query = KeywordEmbedder.vector(for: "zebra budget")
        var items: [(row: MeaningVectors.Row, vector: Data)] = []
        for index in 0..<2500 {
            var vector = (0..<EmbeddingVector.dimension).map { Float(($0 * 31 + index * 17) % 97) - 48 }
            vector = EmbeddingVector.normalized(vector)
            let stored = EmbeddingVector.floats(float16Data: EmbeddingVector.float16Data(vector))!
            expected.append(zip(stored, query).reduce(0) { $0 + $1.0 * $1.1 })
            items.append((MeaningVectors.Row(segment: Int64(index + 1), file: Int64(index + 1), modality: .text,
                                             setsScale: true), EmbeddingVector.float16Data(vector)))
        }
        try vectors.append(items)

        let scores = try #require(vectors.snapshot()).scores(query)
        #expect(scores.count == 2500)
        #expect(zip(scores, expected).allSatisfy { abs($0 - $1) < 1e-4 })
    }

    // MARK: - Fingerprint

    @Test func aNewFingerprintDropsEveryVectorAndEmbedsAgain() async throws {
        let f = try MeaningFixture()
        try f.make("a.md", contents: "budget")
        try TestMedia.picture(at: f.path("zebra.png"))
        try await f.index()
        #expect(try f.count("SELECT COUNT(*) FROM segments WHERE vec_key IS NOT NULL") == 2)

        #expect(try f.writer.adoptMeaningFingerprint("another model"))
        #expect(try f.count("SELECT COUNT(*) FROM segments WHERE vec_key IS NOT NULL") == 0)
        #expect(try f.count("SELECT COUNT(*) FROM segments WHERE kind = 'image'") == 0)
        #expect(try f.count("SELECT COUNT(*) FROM files WHERE vec_state = 'pending'") == 2)

        // The next launch, under the app's own fingerprint again.
        f.close()
        try f.open()
        #expect(f.vectors.liveCount == 0)
        try await f.embedAll()
        #expect(try f.count("SELECT COUNT(*) FROM segments WHERE vec_key IS NOT NULL") == 2)
        #expect(f.vectors.liveCount == 2)
        #expect(try !f.writer.adoptMeaningFingerprint(), "the same one changes nothing")
    }

    @Test func turningItOffFreesTheVectorsAndKeepsThemOnDisk() async throws {
        let f = try MeaningFixture()
        try f.make("a.md", contents: "budget")
        try await f.index()
        #expect(f.vectors.snapshot() != nil)

        f.meaning.disable()
        #expect(f.vectors.snapshot() == nil)
        #expect(!f.vectors.isOpen)
        #expect(try f.meaning.nextBatch().isEmpty)
        #expect(try f.count("SELECT COUNT(*) FROM segments WHERE vec_key IS NOT NULL") == 1)

        try f.meaning.enable()
        #expect(f.vectors.liveCount == 1, "opened again, not embedded again")
    }

    // MARK: - The settled search

    @Test func meaningFindsAFileThatSharesNoWordWithTheQuery() async throws {
        let f = try MeaningFixture()
        try f.make("notes.md", contents: "Blend banana and berries: the smoothie we liked.")
        try f.make("other.md", contents: "Nothing in common here.")
        try f.makeFillers()
        try await f.index()

        let hits = f.search("smoothies opskrift")
        #expect(hits.map(\.name) == ["notes.md"])
        #expect(hits[0].meaning == .text)
        #expect(hits[0].passage?.excerpt.hasPrefix("Blend banana") == true)
    }

    /// Found by its words and by meaning both: the Passage stays where the
    /// words matched, so the row, the Card and the preview can mark them.
    @Test func aFileTheWordsMatchedKeepsItsMarkedPassage() async throws {
        let f = try MeaningFixture()
        try f.make("notes.md", contents: "Blend banana and berries: the smoothie we liked.")
        try f.makeFillers()
        try await f.index()

        let hits = f.search("smoothie")
        #expect(hits.first?.name == "notes.md")
        #expect(hits.first?.meaning == .text)
        let passage = try #require(hits.first?.passage)
        #expect(!passage.matches.isEmpty)
        #expect(passage.matches.map { Array(passage.excerpt)[$0].map(String.init).joined().lowercased() } == ["smoothie"])
    }

    @Test func nameMatchesStayAboveMeaningAndMeaningLandsInTheContentBand() async throws {
        let f = try MeaningFixture()
        try f.make("zebra list.txt", contents: "unrelated words")
        try f.make("stripes.md", contents: "a zebra at the zoo")
        try f.make("savanna.md", contents: "zebra")
        try f.makeFillers()
        try await f.index()

        let hits = f.search("zebra")
        #expect(hits.first?.name == "zebra list.txt")
        #expect(hits.first?.passage == nil && hits.first!.score < FileHit.contentScore)
        let rest = hits.dropFirst()
        #expect(Set(rest.map(\.name)) == ["stripes.md", "savanna.md"])
        #expect(rest.allSatisfy { $0.score >= FileHit.contentScore && $0.score < FileHit.folderOnlyScore })
        #expect(rest.map(\.score) == [FileHit.contentScore, FileHit.contentScore + 1], "ranked within the band")
    }

    @Test func aFolderOnlyMatchStaysBelowEverythingElse() async throws {
        let f = try MeaningFixture()
        try f.make("Budget/plan.txt", contents: "nothing relevant")
        try f.make("money.md", contents: "the budget for the year")
        try f.makeFillers()
        try await f.index()

        let hits = f.search("budget")
        #expect(hits.map(\.name) == ["Budget", "money.md", "plan.txt"])
        #expect(hits.last?.score == FileHit.folderOnlyScore)
    }

    @Test func withoutMeaningTheSettledSearchIsTheWordSearchWithAPrefix() async throws {
        let f = try MeaningFixture()
        try f.make("a.md", contents: "faktura for huslejen")
        try await f.index()

        let words = f.reader.fusedSearch("husl", limit: 50, sources: [f.root], meaning: .none)
        #expect(words.map(\.name) == ["a.md"])
        #expect(f.reader.search("husl", limit: 50, sources: [f.root]).isEmpty, "the keystroke's whole words")
    }

    @Test func aFileWithMostOfTheWordsIsACandidateEvenWithoutMeaning() async throws {
        let f = try MeaningFixture()
        try f.make("a.md", contents: "alpha beta in one place")
        try f.make("b.md", contents: "alpha only")
        try await f.index()

        let words = f.reader.search("alpha beta gamma", limit: 50, sources: [f.root], passages: .lastWordPrefix)
        #expect(words.isEmpty, "the word search wants every word")
        let fused = f.reader.fusedSearch("alpha beta gamma", limit: 50, sources: [f.root], meaning: .none)
        #expect(fused.map(\.name) == ["a.md"], "two of three words pass the 50% gate, one does not")
        #expect(fused.first?.passage == nil && fused.first?.meaning == nil)
    }

    @Test func theKindWordLiftsItsKind() async throws {
        let f = try MeaningFixture()
        // The same meaning, and no word of the Query in either: a tie but for
        // the kind the Query asks for.
        try f.make("trip.md", contents: "a day on the strand")
        try TestMedia.picture(at: f.path("seaside.png"))
        try f.makeFillers()
        try await f.index()

        let plain = f.search("beach").map(\.name)
        #expect(Set(plain) == ["trip.md", "seaside.png"])
        #expect(f.search("beach billede").map(\.name) == ["seaside.png", "trip.md"], "\"billede\" asks for a picture")
        #expect(f.search("beach dokument").map(\.name) == ["trip.md", "seaside.png"], "\"dokument\" for a note")
    }
}
