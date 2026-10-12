import AppKit
import CoreText
import PDFKit
import UniformTypeIdentifiers
import Testing
@testable import codiclens

/// Finding a Passage again in the file it came from, for the Panel's own
/// preview: the excerpt in the text, its matched words there, and on a PDF
/// the matched page's words as selections on that page.
@MainActor
struct PassagePreviewTests {

    // MARK: - Text

    @Test func theExcerptIsFoundAcrossLineBreaksAndItsMarksMappedIntoTheText() throws {
        let text = "Dear tenant,\n\nPlease pay the\ninvoice   number 42 by Friday.\nThe invoice is attached."
        let passage = SubjectPassage(excerpt: "…pay the invoice number 42…", matches: [9..<16, 24..<26])

        let found = try #require(PassageFind.find(passage, in: text))

        #expect(text[found.focus] == "pay the\ninvoice   number 42")
        #expect(found.marks.map { String(text[$0]) } == ["invoice", "42"])
        let firstInvoice = try #require(text.range(of: "invoice"))
        #expect(found.marks.first == firstInvoice, "the occurrence in the Passage, not a later one")
    }

    @Test func theOffsetPicksTheOccurrenceAtThePassage() throws {
        let filler = String(repeating: "lorem ipsum ", count: 600)
        let text = "the invoice number" + filler + "the invoice number"
        let passage = SubjectPassage(
            excerpt: "the invoice number", matches: [4..<11], textOffset: (text as NSString).length - 18
        )

        let found = try #require(PassageFind.find(passage, in: text))

        #expect(found.marks.first?.lowerBound == text.range(of: "invoice", options: .backwards)?.lowerBound)
    }

    @Test func aPassageNotThereAsCutFallsBackToItsFirstMatchedWord() throws {
        let text = "Nothing like the excerpt, but an INVOICE all the same."
        let passage = SubjectPassage(excerpt: "…the invoice number…", matches: [5..<12])

        let found = try #require(PassageFind.find(passage, in: text))

        #expect(text[found.focus] == "INVOICE")
        #expect(found.marks.map { String(text[$0]) } == ["INVOICE"])
    }

    @Test func aPassageFoundByMeaningIsFoundButMarksNothing() throws {
        let text = "Rent for March, paid late."
        let found = try #require(PassageFind.find(SubjectPassage(excerpt: "Rent for March"), in: text))

        #expect(text[found.focus] == "Rent for March")
        #expect(found.marks.isEmpty)
    }

    @Test func theSnippetsEllipsesAreNotWords() {
        let words = PassageFind.words(of: "…the invoice…")
        #expect(words.map { String($0.text) } == ["the", "invoice"])
        #expect(words.map(\.start) == [1, 5])
        #expect(PassageFind.words(of: "…").isEmpty)
    }

    // MARK: - PDF

    /// Three pages, each a colour of its own, "invoice" on the second and the
    /// third.
    static func writePDF(to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        let pages: [(String, CGColor)] = [
            ("A first page about nothing in particular.", CGColor(red: 1, green: 0.85, blue: 0.85, alpha: 1)),
            ("Please pay the invoice number 42 by Friday.", CGColor(red: 0.8, green: 1, blue: 0.8, alpha: 1)),
            ("Another invoice, on the third page.", CGColor(red: 0.8, green: 0.85, blue: 1, alpha: 1))
        ]
        for (text, colour) in pages {
            context.beginPDFPage(nil)
            context.setFillColor(colour)
            context.fill(box)
            let string = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 30),
                .foregroundColor: NSColor.black
            ])
            let setter = CTFramesetterCreateWithAttributedString(string)
            let frame = CTFramesetterCreateFrame(
                setter, CFRange(), CGPath(rect: CGRect(x: 72, y: 72, width: 468, height: 640), transform: nil), nil
            )
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func pdfFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-passage-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("report.pdf")
        try Self.writePDF(to: url)
        return url
    }

    @Test func thePDFsHighlightIsOnTheMatchedPage() throws {
        let url = try pdfFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(PDFDocument(url: url))
        let passage = SubjectPassage(excerpt: "…pay the invoice number 42…", matches: [9..<16], page: 2)

        let found = try #require(PassageFind.selections(in: document, for: passage))

        let second = try #require(document.page(at: 1))
        #expect(found.page == second)
        #expect(found.marks.count == 1)
        #expect(found.marks.allSatisfy { $0.pages == [second] }, "never the third page's invoice")
        #expect(found.marks.first?.string == "invoice")
        #expect(found.focus?.pages == [second])
    }

    @Test func thePDFViewHighlightsTheMatchedWordsOnTheirPage() throws {
        let url = try pdfFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let view = PassagePDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))

        view.show(url, at: SubjectPassage(excerpt: "…another invoice…", matches: [9..<16], page: 3))

        let third = try #require(view.document?.page(at: 2))
        #expect(view.highlightedSelections?.count == 1)
        #expect(view.highlightedSelections?.first?.pages == [third])
        #expect(view.highlightedSelections?.first?.string == "invoice")
    }

    @Test func aMeaningOnlyPageGoesToThePageWithNothingHighlighted() throws {
        let url = try pdfFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(PDFDocument(url: url))

        let found = try #require(PassageFind.selections(in: document, for: SubjectPassage(excerpt: "…the bill…", page: 2)))

        #expect(found.page == document.page(at: 1))
        #expect(found.marks.isEmpty)
    }

    // MARK: - What gets the own preview

    @Test func whatEachFileIsPreviewedAs() {
        let passage = SubjectPassage(excerpt: "invoice", matches: [0..<7])
        func kind(_ name: String, _ type: UTType, _ passage: SubjectPassage = passage) -> PassagePreview.Kind? {
            PassagePreview(url: URL(fileURLWithPath: "/tmp/" + name), title: name, contentType: type, passage: passage)?.kind
        }
        #expect(kind("notes.md", .plainText) == .text(monospaced: false))
        #expect(kind("letter.docx", .data) == .text(monospaced: false))
        #expect(kind("App.tsx", .data) == .text(monospaced: true))
        #expect(kind("index.ts", .mpeg2TransportStream) == .text(monospaced: true), "TypeScript, not a video")
        #expect(kind("report.pdf", .pdf, SubjectPassage(excerpt: "x", page: 2)) == .pdf(page: 2))
        #expect(kind("talk.mov", .quickTimeMovie, SubjectPassage(excerpt: "x", seconds: 3)) == .media(seconds: 3, isVideo: true))
        #expect(kind("memo.m4a", .mpeg4Audio, SubjectPassage(excerpt: "x", seconds: 3)) == .media(seconds: 3, isVideo: false))
        #expect(kind("talk.mov", .quickTimeMovie) == nil, "no moment yet")
        #expect(kind("Screenshot.png", .png) == nil)
        #expect(kind("Deck.key", .data, SubjectPassage(excerpt: "x", page: 2)) == nil)
    }
}
