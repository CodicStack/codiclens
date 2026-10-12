import AppKit
import CoreServices
import Foundation
import Testing
@testable import codiclens

/// The contents layer of the File Index end to end, on a real folder and a
/// real database in a temporary folder: a crawl, the contents pass stepped by
/// hand (`FileContentScheduler.readBatch`), FSEvents batches as `FileIndexer`
/// takes them, and search through `FileIndexReader`.
struct FileContentIndexTests {

    private final class Fixture {
        let folder: TemporaryFolder
        let url: URL
        var writer: FileIndexWriter!
        var reader: FileIndexReader!
        var indexer: FileIndexer!
        var contents: FileContentScheduler!

        init() throws {
            folder = try TemporaryFolder()
            try folder.makeFolder("Source")
            url = folder.url.appendingPathComponent("FileIndex.sqlite")
            try open()
        }

        /// A writer, an indexer and a contents pass on the database, as a
        /// launch makes them.
        func open() throws {
            writer = try FileIndexWriter(url: url)
            reader = FileIndexReader(url: url)
            indexer = FileIndexer(writer: writer)
            contents = FileContentScheduler(writer: writer, queue: DispatchQueue(label: "test.contents"))
            contents.setSources([root])
        }

        func close() {
            (writer, reader, indexer, contents) = (nil, nil, nil, nil)
        }

        deinit {
            close()
            folder.remove()
        }

        var root: String { folder.path("Source") }
        func path(_ relative: String) -> String { root + "/" + relative }

        func make(_ relative: String, contents: String) throws {
            try folder.makeFile("Source/" + relative, contents: contents)
        }

        func crawl() throws {
            for root in try indexer.setSources([(path: root, isEnabled: true)]) { try indexer.crawl(root) }
        }

        /// Steps the pass until it has nothing to do now; returns the files
        /// it read, in order.
        @discardableResult
        func readAll() async throws -> [String] {
            var order: [String] = []
            while true {
                let jobs = try contents.nextBatch()
                guard !jobs.isEmpty else { return order }
                order += jobs.map { ($0.path as NSString).lastPathComponent }
                try contents.store(await FileContentScheduler.readAll(jobs))
            }
        }

        @discardableResult
        func events(_ relatives: [String]) throws -> [Int64] {
            try indexer.handle(relatives.map { FileIndexWatcher.Event(path: path($0)) })
        }

        /// As the settled pass asks: the last word a prefix in Passages too.
        func search(_ query: String, passages: FileIndexReader.PassageMatch = .lastWordPrefix) -> [FileHit] {
            reader.search(query, limit: 50, sources: [root], passages: passages)
        }

        func count(_ table: String) throws -> Int {
            var count = 0
            try writer.db.query("SELECT COUNT(*) FROM \(table)") { count = Int($0.int(0)) }
            return count
        }

        func setDate(_ relative: String, _ date: Date) throws {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(relative))
        }
    }

    // MARK: - Search

    @Test func searchFindsWordsInsideFilesBelowNameMatches() async throws {
        let f = try Fixture()
        try f.make("kontrakt.txt", contents: "nothing to see")
        try f.make("notes.md", contents: "Husk at underskrive kontrakten med udlejer inden fredag.")
        try f.make("other.txt", contents: "ingenting her")
        try f.crawl()
        try await f.readAll()

        let hits = f.search("kontrakt")

        #expect(hits.map(\.name) == ["kontrakt.txt", "notes.md"])
        #expect(hits[0].passage == nil, "a name match keeps its folder line")
        #expect(hits[0].score < FileHit.contentScore)
        #expect(hits[1].score >= FileHit.contentScore && hits[1].score < FileHit.folderOnlyScore)
        let passage = try #require(hits[1].passage)
        #expect(passage.excerpt.contains("kontrakten med udlejer"))
        #expect(passage.page == nil)
        let marked = passage.matches.map { String(Array(passage.excerpt)[$0]) }
        #expect(marked == ["kontrakten"], "the word FTS5 matched, by prefix")
    }

    @Test func everyWordIsRequiredAndTheLastIsAPrefix() async throws {
        let f = try Fixture()
        try f.make("a.txt", contents: "Faktura for husleje i marts")
        try f.make("b.txt", contents: "Faktura for el")
        try f.crawl()
        try await f.readAll()

        #expect(f.search("faktura husl").map(\.name) == ["a.txt"])
        #expect(f.search("faktura").map(\.name).sorted() == ["a.txt", "b.txt"])
        #expect(f.search("fakt husleje").isEmpty, "only the word being typed is a prefix")
    }

    @Test func onTheKeystrokePassagesMatchWholeWordsAndASpaceEndsTheWord() async throws {
        let f = try Fixture()
        try f.make("a.txt", contents: "Faktura for husleje i marts")
        try f.make("b.txt", contents: "Faktura for huslejen i april")
        try f.crawl()
        try await f.readAll()

        #expect(f.search("husl", passages: .wholeWords).isEmpty, "a prefix over Passages waits for the pause")
        #expect(f.search("husleje", passages: .wholeWords).map(\.name) == ["a.txt"])
        #expect(f.search("husleje").map(\.name).sorted() == ["a.txt", "b.txt"])
        #expect(f.search("husleje ").map(\.name) == ["a.txt"], "a space after the word says it is finished")
    }

    @Test func aPrefixIsMarkedAsTheWordsItMatched() async throws {
        let f = try Fixture()
        try f.make("a.txt", contents: "Faktura for huslejen, og husleje igen. Husk hus.")
        try f.crawl()
        try await f.readAll()

        let passage = try #require(f.search("faktura husl").first?.passage)
        let marked = Set(passage.matches.map { String(Array(passage.excerpt)[$0]).lowercased() })
        #expect(marked == ["faktura", "huslejen", "husleje"], "not hus or husk")
        #expect(FileIndexReader.expandingPrefix("husl", of: ["faktura", "husl"], in: "Huslejen og HUSLEJE og hus")
                == #""faktura" AND ("huslejen" OR "husleje")"#)
        #expect(FileIndexReader.expandingPrefix("zz", of: ["zz"], in: "nothing here") == nil)
    }

    @Test func aShortLastWordMatchesWholeWordsInPassages() async throws {
        let f = try Fixture()
        try f.make("a.txt", contents: "ok go")
        try f.make("b.txt", contents: "gopher")
        try f.crawl()
        try await f.readAll()

        #expect(f.search("go").map(\.name) == ["a.txt"], "no prefix index on Passages, so two letters are a word")
        #expect(f.search("gop").map(\.name) == ["b.txt"])
    }

    @Test func aFileMatchedOnceByNameAndByWordsIsOneRowAtItsNameScore() async throws {
        let f = try Fixture()
        try f.make("invoice.txt", contents: "invoice number 7")
        try f.crawl()
        try await f.readAll()

        let hits = f.search("invoice")
        #expect(hits.count == 1)
        #expect(hits.first?.passage == nil)
    }

    @Test func aPDFHitNamesItsPage() async throws {
        let f = try Fixture()
        let filler = String(repeating: "Almindelige betingelser for lejemålet. ", count: 8)
        try FileContentReaderTests.makePDF(at: f.path("lease.pdf"), pages: [filler, filler, filler + " Depositum tilbagebetales."])
        try f.crawl()
        try await f.readAll()

        let hit = try #require(f.search("depositum").first)
        #expect(hit.passage?.page == 3)
        #expect(hit.passage?.subtitle.hasPrefix("page 3 · ") == true)
    }

    @Test func aRowShowsThePassageWithItsWordsUnderlined() throws {
        let passage = FileIndexReader.passage(snippet: "…betale \u{1}husleje\u{2}\n senest", page: 4)
        #expect(passage.excerpt == "…betale husleje senest", "on one line")
        let hit = FileHit(url: URL(fileURLWithPath: "/x/a.pdf"), name: "a.pdf", folder: "~/x", kind: .file,
                          score: FileHit.contentScore, passage: passage)

        let item = ResultDisplayItem(file: hit, icon: NSImage())
        #expect(item.id == "file:/x/a.pdf", "the row is the file's, whatever matched")
        #expect(item.subtitle == "page 4 · …betale husleje senest")
        let underlined = item.attributedSubtitle(query: "huslej").runs
            .filter { $0.underlineStyle != nil }
            .map { String(item.attributedSubtitle(query: "huslej")[$0.range].characters) }
        #expect(underlined == ["husleje"])
    }

    // MARK: - Keeping up with the disk

    @Test func aChangedFileIsReadAgain() async throws {
        let f = try Fixture()
        try f.make("todo.txt", contents: "ring til tandlægen")
        try f.crawl()
        try await f.readAll()
        #expect(f.search("tandlægen").count == 1)

        try f.make("todo.txt", contents: "køb mælk og ost")
        try f.setDate("todo.txt", Date().addingTimeInterval(60))
        let changed = try f.events(["todo.txt"])
        #expect(changed == [try #require(f.writer.row(atPath: f.path("todo.txt"))?.id)])
        #expect(f.search("tandlægen").isEmpty, "old words go with the change")

        f.contents.filesChanged(changed)
        #expect(try await f.readAll() == ["todo.txt"])
        #expect(f.search("mælk").count == 1)
        #expect(try f.count("segments") == 1)
    }

    @Test func aMoveKeepsWhatWasRead() async throws {
        let f = try Fixture()
        try f.make("draft.txt", contents: "ansøgning om barsel")
        try f.crawl()
        try await f.readAll()

        try FileManager.default.createDirectory(atPath: f.path("Arkiv"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: f.path("draft.txt"), toPath: f.path("Arkiv/final.txt"))
        let changed = try f.events(["draft.txt", "Arkiv", "Arkiv/final.txt"])

        #expect(changed.isEmpty, "nothing to read again")
        #expect(try f.contents.nextBatch().isEmpty)
        let hit = try #require(f.search("barsel").first)
        #expect(hit.name == "final.txt")
        #expect(hit.passage != nil)
    }

    @Test func aDeleteTakesItsPassagesWithIt() async throws {
        let f = try Fixture()
        try f.make("a.txt", contents: "første")
        try f.make("sub/b.txt", contents: "anden")
        try f.crawl()
        try await f.readAll()
        #expect(try f.count("segments") == 2)
        #expect(try f.count("passages") == 2)

        try FileManager.default.removeItem(atPath: f.path("a.txt"))
        try FileManager.default.removeItem(atPath: f.path("sub"))
        try f.events(["a.txt", "sub"])

        #expect(try f.count("segments") == 0)
        #expect(try f.count("passages") == 0)
    }

    @Test func aResultForAFileThatChangedWhileItWasReadIsDropped() async throws {
        let f = try Fixture()
        try f.make("a.txt", contents: "gammel tekst")
        try f.crawl()
        let jobs = try f.contents.nextBatch()
        let results = await FileContentScheduler.readAll(jobs)

        try f.make("a.txt", contents: "ny tekst, længere end før")
        try f.events(["a.txt"])
        try f.contents.store(results)

        #expect(f.search("gammel").isEmpty)
        #expect(try await f.readAll() == ["a.txt"])
        #expect(f.search("længere").count == 1)
    }

    // MARK: - Scheduling

    @Test func theBackfillReadsByKindCodeLastNewestFirst() async throws {
        let f = try Fixture()
        let now = Date()
        try f.make("main.swift", contents: "let x = 1")
        try f.make("older.md", contents: "note")
        try f.make("newer.md", contents: "note")
        try f.make("letter.html", contents: "<p>hi</p>")
        try f.make("Screenshot 2025-01-01 at 10.00.00.png", contents: "not really a png")
        try f.make("photo.jpg", contents: "no contents to read")
        try FileContentReaderTests.makePDF(at: f.path("a.pdf"), pages: ["x"])
        try f.setDate("older.md", now.addingTimeInterval(-3600))
        try f.setDate("newer.md", now)
        try f.crawl()

        let order = try await f.readAll()
        #expect(order == ["Screenshot 2025-01-01 at 10.00.00.png", "a.pdf", "letter.html", "newer.md", "older.md",
                          "main.swift"])
    }

    @Test func lowPowerModePausesTheBackfillButNotChangedFiles() async throws {
        let f = try Fixture()
        try f.make("old.txt", contents: "gammel")
        try f.crawl()
        f.contents.setLowPower(true)
        #expect(try f.contents.nextBatch().isEmpty)

        try f.make("new.txt", contents: "ny fil")
        f.contents.filesChanged(try f.events(["new.txt"]))
        #expect(try await f.readAll() == ["new.txt"])

        f.contents.setLowPower(false)
        #expect(try await f.readAll() == ["old.txt"])
    }

    @Test func aBurstOfChangesIsCapped() throws {
        let f = try Fixture()
        try f.crawl()
        let names = (0..<(FileContentScheduler.burstCap + 20)).map { "f\($0).txt" }
        for name in names { try f.make(name, contents: name) }
        f.contents.setLowPower(true)
        f.contents.filesChanged(try f.events(names))

        var read = 0
        while true {
            let jobs = try f.contents.nextBatch()
            if jobs.isEmpty { break }
            read += jobs.count
        }
        #expect(read == FileContentScheduler.burstCap, "the rest wait for the backfill")
    }

    @Test func countsMoveAsContentsAreRead() async throws {
        let f = try Fixture()
        try f.make("a.txt", contents: "en")
        try f.make("b.txt", contents: "to")
        try f.make("photo.jpg", contents: "nothing to read")
        try f.crawl()

        // The Source, two notes and a photo: the folder and the photo have
        // nothing to read and count as read.
        #expect(f.reader.counts()[f.root] == SourceCounts(indexed: 2, total: 4))
        try await f.readAll()
        #expect(f.reader.counts()[f.root] == SourceCounts(indexed: 4, total: 4))
    }

    @Test func aRestartCarriesOnWhereItStopped() async throws {
        let f = try Fixture()
        for index in 0..<(FileContentScheduler.batchSize + 3) { try f.make("n\(index).txt", contents: "note \(index)") }
        try f.crawl()
        try await f.contents.readBatch()

        f.close()
        try f.open()

        #expect(try await f.readAll().count == 3)
        #expect(f.reader.counts()[f.root]?.indexed == FileContentScheduler.batchSize + 4)
    }

    @Test func aLongFileIsSearchableAfterItsFirstStepAndFinishedAfterEverythingElse() async throws {
        let f = try Fixture()
        let words = (0..<20000).map { "ord\($0)" }.joined(separator: " ")
        try f.make("big.log", contents: words + " sidsteord")
        try f.make("small.txt", contents: "lille")
        try f.crawl()

        let order = try await f.readAll()
        #expect(order == ["small.txt", "big.log", "big.log"], "first steps of every file, then the rest")
        #expect(f.search("sidsteord").count == 1)
        #expect(f.reader.counts()[f.root] == SourceCounts(indexed: 3, total: 3))
    }
}
