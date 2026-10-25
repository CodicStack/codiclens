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

        let words = f.reader.fusedSearch("husl", limit: 50, sources: [f.root], meaning: nil)
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
        let fused = f.reader.fusedSearch("alpha beta gamma", limit: 50, sources: [f.root], meaning: .empty)
        #expect(fused.map(\.name) == ["a.md"], "two of three words pass the 50% gate, one does not")
        #expect(fused.first?.passage == nil && fused.first?.meaning == nil)
    }

    @Test func aKindWordPutsItsKindFirstAndAKindHintLiftsIt() async throws {
        let f = try MeaningFixture()
        // The same meaning, and no word of the Query in either: a tie but for
        // the Kind the Query asks for.
        try f.make("trip.md", contents: "a day on the strand")
        try TestMedia.picture(at: f.path("seaside.png"))
        try f.makeFillers()
        try await f.index()

        let plain = f.search("beach").map(\.name)
        #expect(Set(plain) == ["trip.md", "seaside.png"])
        let picture = f.search("beach billede")
        #expect(picture.map(\.name) == ["seaside.png", "trip.md"], "\"billede\" asks for a picture")
        #expect(picture[0].score == FileHit.kindScore && picture[1].score >= FileHit.contentScore)
        let note = f.search("beach dokument")
        #expect(note.map(\.name) == ["trip.md", "seaside.png"], "\"dokument\" lifts a note")
        #expect(note.allSatisfy { $0.score >= FileHit.contentScore }, "a Kind Hint puts nothing first")
    }

    /// "video of the standup": a text with every word of the Query and the
    /// same meaning outscores the video, which only its soundtrack finds, by
    /// its words, yet the video comes first: the Query asked for one.
    @Test func aKindWordWithATopicPutsTheKindAboveATextWithAllTheWords() async throws {
        let f = try MeaningFixture()
        let tone = f.folder.path("tone.wav")
        try TestMedia.wav(at: tone, seconds: 4)
        try await TestMedia.movie(at: f.path("meeting.mov"), seconds: 4, audio: URL(fileURLWithPath: tone))
        try f.make("standup notes.md", contents: "the video of the standup is on the drive")
        try f.makeFillers()
        try await f.index()

        let query = "video of the standup"
        let scores = try #require(f.vectors.snapshot().map { MeaningScores($0, query: KeywordEmbedder.vector(for: query)) })
        let video = try #require(scores.best(try f.id("meeting.mov"))?.z)
        let text = try #require(scores.best(try f.id("standup notes.md"))?.z)
        #expect(video >= MeaningRanking.zGate, "\(video)")
        #expect(MeaningRanking.score(z: text, coverage: 1, isKindLifted: false, isLookup: false)
                > MeaningRanking.score(z: video, coverage: 0, isKindLifted: true, isLookup: false),
                "fused alone, the text would win")

        for query in [query, "video af mig til standup"] {
            let hits = f.search(query)
            #expect(Array(hits.map(\.name).prefix(2)) == ["meeting.mov", "standup notes.md"], "\(query)")
            #expect(hits.first?.score == FileHit.kindScore, "\(query)")
            #expect(hits.first?.meaning == .audio, "\(query): found by its soundtrack")
        }
    }

    /// A Kind Word is a request even when nothing of the Kind stands out:
    /// its best guesses fill the block up to ten, ranked with the one that
    /// does, and the rest of the Kind stays out.
    @Test func theKindsBestGuessesFillTheBlockToTen() async throws {
        let f = try MeaningFixture()
        try TestMedia.picture(at: f.path("seaside.png"))
        for index in 0..<12 { try TestMedia.picture(at: f.path("p\(index).png"), hue: CGFloat(index) / 12) }
        try f.make("beach.md", contents: "a beach day")
        try f.makeFillers()
        try await f.index()

        let hits = f.search("photo of the beach")
        let block = hits.filter { $0.score < 0 }
        #expect(block.count == MeaningRanking.kindGuesses)
        #expect(block.first?.name == "seaside.png")
        #expect(block.allSatisfy { $0.name.hasSuffix(".png") })
        #expect(block.map(\.score) == (0..<10).map { FileHit.kindScore + $0 })
        #expect(hits.filter { $0.name.hasSuffix(".png") }.count == 10, "the other two are no guess")
        #expect(hits.dropFirst(10).first?.name == "beach.md")
        // Without meaning there is nothing to guess by: the note's name
        // answers "beach", and nothing is first.
        let words = f.reader.fusedSearch("photo of the beach", limit: 50, sources: [f.root], meaning: nil)
        #expect(words.map(\.name) == ["beach.md"])
        #expect(words.allSatisfy { $0.score >= 0 })
    }

    /// "photo", "image" and "billede" ask for photos and screenshots alike;
    /// "screenshot" for screenshots alone.
    @Test func pictureWordsAskForPhotosAndScreenshots() async throws {
        let f = try MeaningFixture()
        try TestMedia.picture(at: f.path("seaside.png"))
        try TestMedia.picture(at: f.path("Screenshot strand.png"), hue: 0.7)
        try f.make("trip.md", contents: "a day at the beach")
        try f.makeFillers()
        try await f.index()
        #expect(f.reader.content(atPath: f.path("Screenshot strand.png")) == .screenshot)

        for query in ["photo of the beach", "image of the beach", "billede af stranden"] {
            let hits = f.search(query)
            #expect(Set(hits.prefix(2).map(\.name)) == ["seaside.png", "Screenshot strand.png"], "\(query)")
            #expect(hits.prefix(2).allSatisfy { $0.score < 0 }, "\(query)")
            #expect(hits.dropFirst(2).allSatisfy { $0.score >= 0 }, "\(query)")
        }
        let screenshots = f.search("screenshot of the beach")
        #expect(screenshots.first?.name == "Screenshot strand.png")
        #expect(screenshots.filter { $0.score < 0 }.map(\.name) == ["Screenshot strand.png"])
        #expect(screenshots.contains { $0.name == "seaside.png" }, "still found by meaning, below the block")
    }

    /// Two Kind Words share one block, ranked together.
    @Test func twoKindWordsShareOneBlock() async throws {
        let f = try MeaningFixture()
        try TestMedia.picture(at: f.path("seaside.png"))
        try TestMedia.wav(at: f.path("strand.wav"), seconds: 5)
        try f.make("trip.md", contents: "a day at the beach")
        try f.makeFillers()
        try await f.index()

        let hits = f.search("photo or recording of the beach")
        #expect(Set(hits.prefix(2).map(\.name)) == ["seaside.png", "strand.wav"])
        #expect(hits.prefix(2).map(\.score) == [FileHit.kindScore, FileHit.kindScore + 1])
        #expect(hits.dropFirst(2).first?.name == "trip.md")
    }

    /// "audio file" is only a Kind and means nothing past it, which the
    /// per-modality scale centres away: no recording reaches the gate. The
    /// newest recordings come first, ahead of a note the words found.
    @Test func aQueryOfOnlyAKindListsTheNewestOfThatKindFirst() async throws {
        let f = try MeaningFixture()
        for (name, year) in [("old.wav", 2020), ("new.wav", 2024), ("mid.wav", 2022)] {
            try TestMedia.wav(at: f.path(name), seconds: 5)
            try f.setDate(name, try #require(Calendar.current.date(from: DateComponents(year: year, month: 6, day: 1))))
        }
        try f.make("notes.md", contents: "the audio file is ready")
        try f.make("playlist.md", contents: "music for the drive")
        try f.makeFillers()
        try await f.index()

        #expect(f.reader.fusedSearch("audio file", limit: 50, sources: [f.root], meaning: nil).map(\.name)
                == ["new.wav", "mid.wav", "old.wav", "notes.md"], "without meaning too")
        let hits = f.search("audio file")
        #expect(hits.map(\.name) == ["new.wav", "mid.wav", "old.wav", "notes.md"])
        #expect(hits.map(\.score) == [FileHit.kindScore, FileHit.kindScore + 1, FileHit.kindScore + 2, FileHit.contentScore])
        #expect(hits.prefix(3).allSatisfy { $0.meaning == nil }, "found by its Kind, not by meaning")
        #expect(f.search("lydfil").map(\.name) == ["new.wav", "mid.wav", "old.wav"])
        #expect(f.search("my recordings").map(\.name) == ["new.wav", "mid.wav", "old.wav"])
        #expect(f.search("music").map(\.name) == ["playlist.md"], "a Kind Hint lists nothing")
        #expect(f.search("video").isEmpty, "no file of the Kind: nothing")
    }

    /// A kind-only Query's block is the Kind's name matches, then its
    /// newest, 25 in all; name matches of other Kinds come after it.
    @Test func aKindOnlyBlockIsCappedAndOtherKindsNameMatchesFollow() async throws {
        let f = try MeaningFixture()
        for index in 0..<30 {
            try TestMedia.picture(at: f.path("shot \(index).png"), hue: CGFloat(index % 5) / 5)
            try f.setDate("shot \(index).png", Date(timeIntervalSince1970: 1_600_000_000 + Double(index) * 1000))
        }
        try TestMedia.picture(at: f.path("photo.png"))
        try f.setDate("photo.png", Date(timeIntervalSince1970: 1_500_000_000))
        try f.make("photo booth.md", contents: "a booth")
        try await f.index()

        for hits in [f.search("photo"), f.reader.fusedSearch("photo", limit: 50, sources: [f.root], meaning: nil)] {
            #expect(hits.first?.name == "photo.png", "the Kind's own name match first")
            #expect(hits[1].name == "shot 29.png", "then the newest")
            #expect(hits.prefix(MeaningRanking.kindOnlyFiles).allSatisfy { $0.name.hasSuffix(".png") && $0.score < 0 })
            #expect(hits.filter { $0.name.hasSuffix(".png") }.count == MeaningRanking.kindOnlyFiles)
            #expect(hits[MeaningRanking.kindOnlyFiles].name == "photo booth.md")
            #expect(hits[MeaningRanking.kindOnlyFiles].score >= 0 && hits[MeaningRanking.kindOnlyFiles].score < FileHit.contentScore)
        }
    }

    /// "video": a file named video is not a video. The videos come first, the
    /// one named video ahead of them, and `VideoSlide.tsx` after.
    @Test func aKindWordPutsRealVideosAboveFilesNamedLikeIt() async throws {
        let f = try MeaningFixture()
        try await TestMedia.movie(at: f.path("clip.mov"), seconds: 2)
        try await TestMedia.movie(at: f.path("video.mov"), seconds: 2)
        try f.make("VideoSlide.tsx", contents: "export const VideoSlide = () => null")
        try f.make("video notes.md", contents: "notes")
        try f.makeFillers()
        try await f.index()

        for hits in [f.search("video"), f.search("my video"),
                     f.reader.fusedSearch("video", limit: 50, sources: [f.root], meaning: nil)] {
            #expect(Array(hits.map(\.name).prefix(2)) == ["video.mov", "clip.mov"])
            #expect(Set(hits.dropFirst(2).prefix(2).map(\.name)) == ["VideoSlide.tsx", "video notes.md"])
        }
        let keystroke = f.reader.search("video", limit: 50, sources: [f.root])
        #expect(keystroke.first?.name != "clip.mov", "the keystroke is as it was")
    }

    /// The Kind block sits above name matches of every other Kind.
    @Test func theKindBlockIsAboveOtherKindsNameMatches() async throws {
        let f = try MeaningFixture()
        try TestMedia.wav(at: f.path("take.wav"), seconds: 5)
        try f.make("audio file list.txt", contents: "nothing here")
        try f.makeFillers()
        try await f.index()

        let hits = f.search("audio file")
        #expect(hits.map(\.name) == ["take.wav", "audio file list.txt"])
        #expect(hits[0].score == FileHit.kindScore)
        #expect(hits[1].passage == nil && hits[1].score >= 0 && hits[1].score < FileHit.contentScore)
    }

    /// "music meeting recording": the recording means only half of it (z
    /// between 1 and 2), below the gate, yet "recording" asks for one, so it
    /// is the best guess and comes first. With "music meeting", whose
    /// "music" is only a Kind Hint, it stays out.
    @Test func aKindWordBringsItsBestGuessAndAKindHintDoesNot() async throws {
        let f = try MeaningFixture()
        try TestMedia.wav(at: f.path("standup.wav"), seconds: 5)
        try f.make("concert.md", contents: "music for the meeting")
        try f.makeFillers()
        try await f.index()

        let query = "music meeting recording"
        let scores = try #require(f.vectors.snapshot().map { MeaningScores($0, query: KeywordEmbedder.vector(for: query)) })
        let recording = try #require(scores.best(try f.id("standup.wav"))?.z)
        #expect(recording >= 1 && recording < MeaningRanking.zGate, "\(recording)")

        #expect(f.search(query).map(\.name) == ["standup.wav", "concert.md"])
        #expect(f.search("music meeting").map(\.name) == ["concert.md"])
    }

    /// "release notes" is not a request for notes: a Kind Hint reorders
    /// nothing, and a name match of another Kind stays first.
    @Test func aKindHintDoesNotPutItsKindFirst() async throws {
        let f = try MeaningFixture()
        try f.make("release notes.swift", contents: "let version = 2")
        try f.make("changes.md", contents: "the release notes for 2.0")
        try f.makeFillers()
        try await f.index()

        let hits = f.search("release notes")
        #expect(hits.map(\.name) == ["release notes.swift", "changes.md"])
        #expect(hits.allSatisfy { $0.score >= 0 })
        #expect(f.search("documents").allSatisfy { $0.score >= 0 })
    }

    /// A folder word beside something to look for puts the folders whose
    /// name or path match first, by their words alone; it does not put the
    /// Kind of a Kind Word beside it first. "folder" alone does nothing.
    @Test func aFolderWordPutsMatchingFoldersFirst() async throws {
        let f = try MeaningFixture()
        try f.make("Video/a.txt", contents: "first")
        try f.make("Old/video stuff/b.txt", contents: "second")
        try await TestMedia.movie(at: f.path("clip video.mov"), seconds: 2)
        try f.make("video.md", contents: "notes")
        try f.makeFillers()
        try await f.index()

        for hits in [f.search("video folder"), f.search("mappe med video"),
                     f.reader.fusedSearch("video folder", limit: 50, sources: [f.root], meaning: nil)] {
            #expect(Array(hits.map(\.name).prefix(2)) == ["Video", "video stuff"])
            #expect(hits.prefix(2).allSatisfy { $0.kind == .folder && $0.score < 0 })
            #expect(hits.dropFirst(2).allSatisfy { $0.score >= 0 }, "no video first")
            #expect(hits.contains { $0.name == "clip video.mov" })
        }
        #expect(f.search("folder").allSatisfy { $0.score >= 0 })
        #expect(f.search("my folders").allSatisfy { $0.score >= 0 })
    }

    // MARK: - The Kind block at scale

    /// Meaning scores made by hand for the fixture's files, by name: what
    /// each stands out by, and files that do not exist standing in for the
    /// rest of a large index.
    private func scores(_ f: MeaningFixture, _ z: [String: Double], others: [Double] = []) throws -> MeaningScores {
        var byID: [Int64: Double] = [:]
        for (name, value) in z { byID[try f.id(name)] = value }
        let made = byID
        let stand = others.enumerated().map { MeaningScores.Match(file: 9_000_000 + Int64($0.offset), z: $0.element, segment: 0) }
        let gated = (stand + made.filter { $0.value >= MeaningRanking.zGate }
            .map { MeaningScores.Match(file: $0.key, z: $0.value, segment: 0) })
            .sorted { $0.z > $1.z }
        return MeaningScores(gated: gated, best: { id in made[id].map { MeaningScores.Match(file: id, z: $0, segment: 0) } })
    }

    /// The 200 best files by meaning across every Kind are no measure of
    /// the asked Kind: on the user's index "image of me" had 36 pictures
    /// over the gate and the cut kept 3. Every gated file of the Kind comes
    /// in, however far down, and the Kind's other files stay out.
    @Test func everyGatedFileOfTheAskedKindComesInPastTheTop200() async throws {
        let f = try MeaningFixture()
        for index in 0..<15 { try TestMedia.picture(at: f.path("portrait\(index).png"), hue: CGFloat(index) / 15) }
        try await f.index()

        var z: [String: Double] = [:]
        for index in 0..<12 { z["portrait\(index).png"] = 3.0 }
        for index in 12..<15 { z["portrait\(index).png"] = 1.0 }
        let meaning = try scores(f, z, others: .init(repeating: 5.0, count: MeaningRanking.meaningCandidates))
        #expect(meaning.top.allSatisfy { $0.file >= 9_000_000 }, "the cut keeps none of them")

        let hits = f.reader.fusedSearch("photo of me", limit: 50, sources: [f.root], meaning: meaning)
        let block = hits.filter { $0.score < 0 }.map(\.name)
        #expect(Set(block) == Set((0..<12).map { "portrait\($0).png" }), "\(block)")
    }

    /// A best guess is scored with its words like any member of the block:
    /// one of three words in its name lifts it above guesses with a little
    /// more meaning and none of the words.
    @Test func aBestGuessScoresWithItsWords() async throws {
        let f = try MeaningFixture()
        for index in 0..<9 { try TestMedia.picture(at: f.path("p\(index).png"), hue: CGFloat(index) / 9) }
        try TestMedia.picture(at: f.path("march.png"), hue: 0.95)
        try await f.index()

        var z: [String: Double] = ["march.png": 1.0]
        for index in 0..<9 { z["p\(index).png"] = 1.2 }
        let query = "photo of the invoice from march 2024"
        #expect(MeaningRanking.terms(query) == ["invoice", "march", "2024"])
        let hits = f.reader.fusedSearch(query, limit: 50, sources: [f.root], meaning: try scores(f, z))
        #expect(hits.filter { $0.score < 0 }.count == MeaningRanking.kindGuesses)
        #expect(hits.first?.name == "march.png", "1.0 + 2 × (1/3)^1.5 beats 1.2")
    }

    /// Once typing pauses a Kind Word is answered by the Kind, not looked
    /// for in the words: a receipt PDF that never says "pdf" is found by
    /// "invoice" and leads, as an invoice note does not.
    @Test func aKindWordIsNotRequiredInTheSettledWordSearch() async throws {
        let f = try MeaningFixture()
        try FileContentReaderTests.makePDF(at: f.path("Receipt-2851-2040.pdf"),
                                           pages: [String(repeating: "Invoice for the consulting work in March. ", count: 8)])
        try f.make("invoice.md", contents: "an invoice to send")
        try f.makeFillers()
        try await f.index()

        #expect(f.reader.search("pdf invoice", limit: 50, sources: [f.root]).isEmpty, "the keystroke is as it was")
        for hits in [f.search("pdf invoice"), f.reader.fusedSearch("pdf invoice", limit: 50, sources: [f.root], meaning: nil)] {
            #expect(hits.first?.name == "Receipt-2851-2040.pdf")
            #expect(hits.first.map { $0.score < 0 && $0.passage != nil } == true)
            #expect(hits.contains { $0.name == "invoice.md" && $0.score >= 0 })
        }
    }

    /// "image of me": `image.png` and `image001.png` match only the Kind
    /// Word. They take their place in the block by their score and leave the
    /// ten to what stands out and the best guesses; a name match on a topic
    /// word still leads.
    @Test func aNameMatchOnTheKindWordAloneRanksByItsScore() async throws {
        let f = try MeaningFixture()
        for index in 0..<12 { try TestMedia.picture(at: f.path("portrait\(index).png"), hue: CGFloat(index) / 12) }
        try TestMedia.picture(at: f.path("image.png"), hue: 0.31)
        try TestMedia.picture(at: f.path("image001.png"), hue: 0.62)
        try TestMedia.picture(at: f.path("beach.png"), hue: 0.93)
        try await f.index()

        var z: [String: Double] = ["image.png": 1.9, "image001.png": -0.6, "beach.png": 0]
        for index in 0..<3 { z["portrait\(index).png"] = 3.0 }
        for index in 3..<12 { z["portrait\(index).png"] = 1.5 - Double(index) / 100 }
        let meaning = try scores(f, z)

        let hits = f.reader.fusedSearch("image of me", limit: 50, sources: [f.root], meaning: meaning)
        let block = hits.filter { $0.score < 0 }.map(\.name)
        #expect(Set(block.prefix(3)) == ["portrait0.png", "portrait1.png", "portrait2.png"], "\(block)")
        #expect(block[3] == "image.png", "\(block)")
        #expect(block.dropFirst(4).prefix(7) == ArraySlice((3..<10).map { "portrait\($0).png" }), "seven guesses: \(block)")
        #expect(block.last == "image001.png", "\(block)")
        #expect(!block.contains("beach.png"))

        let beach = f.reader.fusedSearch("image of the beach", limit: 50, sources: [f.root], meaning: meaning)
        #expect(beach.first?.name == "beach.png", "a name match on the topic leads")
    }

    /// "video folder": a folder found only because a folder above it is
    /// called video stays out of the block, so its subfolders do not bury
    /// the rest. The folders that match by their own name lead.
    @Test func aFolderInsideALeadingFolderDoesNotJoinTheBlock() async throws {
        let f = try MeaningFixture()
        for index in 0..<55 { try f.make("Projects/koffeelab-video/sub\(index)/a.txt", contents: "x") }
        try f.make("Projects/koffeelab-video/src/video-player/b.txt", contents: "x")
        try f.make("Other/video stuff/c.txt", contents: "x")
        try f.make("video notes.md", contents: "notes")
        try f.makeFillers()
        try await f.index()

        for hits in [f.search("video folder"), f.reader.fusedSearch("video folder", limit: 50, sources: [f.root], meaning: nil)] {
            let block = hits.filter { $0.score < 0 }.map(\.name)
            #expect(Set(block) == ["koffeelab-video", "video stuff", "video-player"], "\(block)")
            #expect(hits.contains { $0.name == "video notes.md" }, "the files are not cut")
        }
    }

    /// "pdf invoice" on the real index: `Broken Invoice/invoice.pdf` has no
    /// words and no vectors, and its folder says "invoice". Its own name
    /// answers the topic, so it is a name match on it and leads the block,
    /// however many files say "invoice"; it fell to a folder-only match
    /// below the 50-row cut once "pdf" was no longer required.
    @Test func aNameOfTheKindThatAnswersTheTopicLeadsPastTheCut() async throws {
        let f = try MeaningFixture()
        try f.folder.makeFile("Source/Broken Invoice/invoice.pdf", contents: "not a pdf at all")
        for index in 0..<60 { try f.make("Mail/m\(index).md", contents: "invoice invoice \(index)") }
        try await f.index()
        #expect(try f.count("SELECT COUNT(*) FROM segments s JOIN files f ON f.id = s.file WHERE f.path LIKE '%invoice.pdf'") == 0)

        for hits in [f.search("pdf invoice"), f.reader.fusedSearch("pdf invoice", limit: 50, sources: [f.root], meaning: nil)] {
            #expect(hits.first?.name == "invoice.pdf", "\(hits.prefix(3).map(\.name))")
            #expect(hits.first.map { $0.score < 0 } == true)
        }
    }

    /// A PDF that says the topic comes in however many other files say it
    /// louder: the word search keeps the asked Kind's files ahead of its cut.
    @Test func aFileOfTheKindThatSaysTheTopicIsNotLostToTheCut() async throws {
        let f = try MeaningFixture()
        try FileContentReaderTests.makePDF(at: f.path("Receipt-2851-2040.pdf"),
                                           pages: [String(repeating: "Thank you for the consulting work this spring. ", count: 6)
                                                   + "Invoice attached."])
        for index in 0..<60 { try f.make("Mail/m\(index).md", contents: "invoice invoice invoice") }
        try await f.index()

        let hits = f.reader.fusedSearch("pdf invoice", limit: 50, sources: [f.root], meaning: nil)
        #expect(hits.first?.name == "Receipt-2851-2040.pdf", "\(hits.prefix(3).map(\.name))")
        #expect(hits.first.map { $0.score < 0 } == true)
        #expect(f.reader.search("invoice", limit: 50, sources: [f.root]).allSatisfy { $0.name != "Receipt-2851-2040.pdf" },
                "the keystroke's cut is as it was")
    }
}
