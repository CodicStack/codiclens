import Foundation
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// Ranking in the File Index: FTS5 finds the candidates, `fuzzyScore` on the
/// name orders them. Rows are written straight through `FileIndexWriter`, so
/// nothing here touches a file other than the database.
struct FileIndexSearchTests {
    private static let home = NSHomeDirectory()
    private static let documents = home + "/Documents"
    private static let downloads = home + "/Downloads"

    /// A database in a fresh folder, holding a row for each path, all in
    /// `source` unless the path says otherwise.
    private final class Index {
        let folder: TemporaryFolder
        // Optional so `deinit` can close the database before deleting it.
        var writer: FileIndexWriter!
        var reader: FileIndexReader!

        init(_ paths: [String], source: String = FileIndexSearchTests.documents) throws {
            folder = try TemporaryFolder()
            let url = folder.url.appendingPathComponent("FileIndex.sqlite")
            writer = try FileIndexWriter(url: url)
            reader = FileIndexReader(url: url)
            for (offset, path) in paths.enumerated() {
                let rowSource = path.hasPrefix(FileIndexSearchTests.downloads) ? FileIndexSearchTests.downloads : source
                try writer.insert(FileIndexRow(
                    path: path, source: rowSource, kind: path.hasSuffix("/") ? .folder : .file,
                    size: 1, mtime: 0, inode: UInt64(offset + 1), device: 1
                ))
            }
        }

        deinit {
            (writer, reader) = (nil, nil)
            folder.remove()
        }

        func names(_ query: String, sources: [String] = [FileIndexSearchTests.documents]) -> [String] {
            reader.search(query, limit: 50, sources: sources).map(\.name)
        }
    }

    /// Past `rankingCap` matches the ranked set is an arbitrary slice, so the
    /// names that begin with a one-word Query are fetched on their own.
    @Test func aBroadQueryStillFindsTheNamesThatBeginWithIt() throws {
        let crowd = (0..<(FileIndexReader.rankingCap + 50)).map { Self.documents + "/Archive/x \($0) a.txt" }
        let index = try Index(crowd + [Self.documents + "/a.txt", Self.documents + "/Atlas.pdf"])

        #expect(Array(index.names("a").prefix(2)) == ["a.txt", "Atlas.pdf"])
    }

    @Test func aNameMatchBeatsAFolderMatch() throws {
        let index = try Index([
            Self.documents + "/Invoices/scan-0042.pdf",
            Self.documents + "/Work/Invoice March.pdf"
        ])
        let hits = index.reader.search("invoice", limit: 10, sources: [Self.documents])

        #expect(hits.map(\.name) == ["Invoice March.pdf", "scan-0042.pdf"])
        #expect(hits[1].score == FileHit.folderOnlyScore, "matched on its folder alone")
    }

    @Test func theLastWordIsAPrefixAndTheOthersAreWhole() throws {
        let index = try Index([Self.documents + "/invoice 2024 march.pdf"])

        #expect(index.names("invoice 20") == ["invoice 2024 march.pdf"])
        #expect(index.names("inv") == ["invoice 2024 march.pdf"])
        #expect(index.names("inv 2024").isEmpty, "only the word being typed is a prefix")
    }

    @Test func everyWordMustMatchSomewhere() throws {
        let index = try Index([
            Self.documents + "/Skat/2024/Årsopgørelse.pdf",
            Self.documents + "/Skat/2023/Årsopgørelse.pdf"
        ])

        #expect(index.reader.search("skat 2024", limit: 10, sources: [Self.documents]).map(\.folder)
            == ["~/Documents/Skat/2024"])
    }

    @Test func fuzzyScoreOrdersTheCandidates() throws {
        let index = try Index([
            Self.documents + "/My invoice.pdf",
            Self.documents + "/invoice.pdf",
            Self.documents + "/Invoices for 2024.pdf"
        ])

        #expect(index.names("invoice") == ["invoice.pdf", "Invoices for 2024.pdf", "My invoice.pdf"])
    }

    // MARK: - Danish

    @Test func aDanishCompoundIsFoundByItsFirstWord() throws {
        let index = try Index([Self.documents + "/Skatteårsopgørelse 2024.pdf"])

        #expect(index.names("skat") == ["Skatteårsopgørelse 2024.pdf"])
        #expect(index.names("skatteårs") == ["Skatteårsopgørelse 2024.pdf"])
        #expect(index.names("opgørelse").isEmpty, "a word inside a compound is not a word of its own")
    }

    /// `remove_diacritics 2` folds what Unicode decomposes: `å` is `a` with a
    /// ring. `æ` and `ø` are letters of their own and stay so.
    @Test func åFoldsToAButÆAndØStayLetters() throws {
        let index = try Index([
            Self.documents + "/Årsrapport.pdf",
            Self.documents + "/Ærø ferie.jpg",
            Self.documents + "/Brev fra Øresund.docx"
        ])

        #expect(index.names("årsrapport") == ["Årsrapport.pdf"])
        #expect(index.names("arsrapport") == ["Årsrapport.pdf"])
        #expect(index.names("ærø") == ["Ærø ferie.jpg"])
        #expect(index.names("aero").isEmpty)
        #expect(index.names("øresund") == ["Brev fra Øresund.docx"])
        #expect(index.names("oresund").isEmpty)
    }

    /// A name stored decomposed — `a` and a combining ring, as older volumes
    /// and some copies leave it — is the same word as one stored composed.
    @Test func aDecomposedNameIsFoundLikeAComposedOne() throws {
        let index = try Index([Self.documents + "/Ga\u{030A}rdhave.pdf"])

        #expect(index.names("gårdhave").count == 1)
        #expect(index.names("gard").count == 1)
    }

    @Test func camelCaseAndDigitsSplitIntoWords() throws {
        let index = try Index([Self.documents + "/MyInvoice2024.pdf"])

        #expect(index.names("invoice") == ["MyInvoice2024.pdf"])
        #expect(index.names("2024") == ["MyInvoice2024.pdf"])
    }

    // MARK: - Scope and lookups

    @Test func onlyTheGivenSourcesAreSearched() throws {
        let index = try Index([Self.documents + "/report.pdf", Self.downloads + "/report (1).pdf"])

        #expect(index.names("report") == ["report.pdf"])
        #expect(index.names("report", sources: [Self.downloads]) == ["report (1).pdf"])
        #expect(index.names("report", sources: []).isEmpty)
    }

    @Test func aHitCarriesItsFolderHomeAbbreviatedAndItsType() throws {
        let index = try Index([Self.documents + "/Taxes/return.pdf", Self.documents + "/Taxes/"])
        let hits = index.reader.search("return", limit: 10, sources: [Self.documents])

        let hit = try #require(hits.first)
        #expect(hit.folder == "~/Documents/Taxes")
        #expect(hit.url.path == Self.documents + "/Taxes/return.pdf")
        #expect(hit.contentType == .pdf)
        #expect(index.reader.file(atPath: Self.documents + "/Taxes/return.pdf")?.name == "return.pdf")
        #expect(index.reader.file(atPath: Self.documents + "/Taxes/missing.pdf") == nil)
    }

    @Test func aQueryWithNoWordsFindsNothing() throws {
        let index = try Index([Self.documents + "/report.pdf"])

        #expect(index.names("").isEmpty)
        #expect(index.names("..").isEmpty)
        #expect(index.names("\"").isEmpty)
    }

    @Test func aReaderBeforeTheDatabaseExistsAnswersEmpty() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let reader = FileIndexReader(url: folder.url.appendingPathComponent("FileIndex.sqlite"))

        #expect(reader.search("report", limit: 10, sources: [Self.documents]).isEmpty)
        #expect(reader.counts().isEmpty)
    }

    @Test func countsAreKeptPerSource() throws {
        let index = try Index([
            Self.documents + "/a.pdf", Self.documents + "/b.pdf", Self.downloads + "/c.pdf"
        ])

        #expect(index.reader.counts() == [Self.documents: 2, Self.downloads: 1])
    }
}
