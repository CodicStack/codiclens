import AppKit
import Foundation
import PDFKit
import Testing
import Vision
@testable import codiclens

/// Reading what files say: which files have anything to read (`FileContent`),
/// how text is cut into Passages (`FileChunker`), and what `FileContentReader`
/// gets out of each kind of file. Every file is made in a temporary folder.
struct FileContentReaderTests {

    private static func job(_ path: String, _ content: FileContent, readTo: Int = 0) -> FileContentJob {
        FileContentJob(id: 1, path: path, content: content, size: 0, mtime: 0, readTo: readTo)
    }

    private static func read(_ path: String, _ content: FileContent, readTo: Int = 0) async -> FileContentResult {
        await FileContentReader.read(job(path, content, readTo: readTo))
    }

    private static func entry(_ path: String, isDirectory: Bool = false, isPackage: Bool = false) -> FileIndexRules.Entry {
        FileIndexRules.Entry(path: path, isDirectory: isDirectory, isPackage: isPackage)
    }

    // MARK: - What a file holds

    @Test func everyFileWithoutAKnownBinaryTypeIsReadAsCodeLast() {
        for name in ["App.tsx", "Page.svelte", "Cargo.toml", ".zshrc", "Makefile", "notes.weird", "main.go", "data.json"] {
            #expect(FileContent.of(Self.entry("/x/" + name)) == .code, "\(name)")
        }
        #expect(FileContent.of(Self.entry("/x/README.md")) == .text)
        #expect(FileContent.of(Self.entry("/x/a.pdf")) == .pdf)
        #expect(FileContent.of(Self.entry("/x/a.docx")) == .document)
        #expect(FileContent.of(Self.entry("/x/Letter.pages", isDirectory: true, isPackage: true)) == .document)
        #expect(FileContent.of(Self.entry("/x/Tool.app", isDirectory: true, isPackage: true)) == nil)
        #expect(FileContent.of(Self.entry("/x/folder", isDirectory: true)) == nil)
        for name in ["archive.zip", "font.woff2", "lib.dylib", "voice.ogg", "film.mkv"] {
            #expect(FileContent.of(Self.entry("/x/" + name)) == nil, "\(name)")
        }
        // Nothing to read, and something to see or hear: the meaning pass's.
        #expect(FileContent.of(Self.entry("/x/song.mp3")) == .audio)
        #expect(FileContent.of(Self.entry("/x/clip.mov")) == .video)
        #expect(FileContent.of(Self.entry("/x/photo.heic")) == .image)
        #expect([FileContent.image, .audio, .video].allSatisfy { !$0.hasWords })
        #expect(FileContent.allCases.sorted { $0.rawValue < $1.rawValue }
                == [.screenshot, .image, .pdf, .document, .text, .audio, .video, .code], "the reading order")
    }

    @Test func aKeyFileIsKeynoteOnlyWhenItIsAZip() {
        var keynote = Self.entry("/x/Talk.key")
        keynote.startsWithZipMagic = true
        #expect(FileContent.of(keynote) == .document)
        #expect(FileContent.of(Self.entry("/x/server.key")) == .code, "a private key, and text")
    }

    @Test func screenshotsAreKnownByNameFolderOrFlag() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        for name in ["Screenshot 2025-01-07 at 19.23.15.png", "Skærmbillede 2024-03-01 kl. 10.00.00.png",
                     "Screenshots/IMG_1.png", "CleanShot 2024.png"] {
            try folder.makeFile(name, data: Data([0x89]))
            #expect(FileContent.of(Self.entry(folder.path(name))) == .screenshot, "\(name)")
        }
        try folder.makeFile("holiday.jpg", data: Data([0xFF]))
        #expect(FileContent.of(Self.entry(folder.path("holiday.jpg"))) == .image, "a photo: meaning only")

        try folder.makeFile("capture.png", data: Data([0x89]))
        let flag = Data("bplist00\u{9}\u{8}".utf8)
        _ = flag.withUnsafeBytes { setxattr(folder.path("capture.png"), "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, $0.count, 0, 0) }
        #expect(FileContent.of(Self.entry(folder.path("capture.png"))) == .screenshot)
    }

    // MARK: - Chunking

    @Test func chunksOverlapAndBreakAtWhitespace() {
        let words = (0..<1000).map { "word\($0)" }
        let text = words.joined(separator: " ")
        let (chunks, total) = FileChunker.chunks(text, range: 0..<100, cap: 100)

        #expect(total == chunks.count)
        #expect(total > 3)
        for chunk in chunks {
            #expect(chunk.text.count <= FileChunker.size)
            #expect(!chunk.text.hasPrefix(" ") && !chunk.text.hasSuffix(" "))
            // Whole words only: every piece is one of the words.
            #expect(chunk.text.split(separator: " ").allSatisfy { words.contains(String($0)) })
        }
        for (first, second) in zip(chunks, chunks.dropFirst()) {
            let tail = first.text.split(separator: " ").suffix(5)
            #expect(second.text.contains(tail.joined(separator: " ")), "the next chunk repeats the end of the last")
            #expect(second.offset < first.offset + first.text.utf16.count)
            #expect((text as NSString).substring(from: second.offset).hasPrefix(String(second.text.prefix(20))))
        }
        #expect(chunks.last?.text.hasSuffix("word999") == true, "nothing is lost at the end")
    }

    @Test func chunksAreCutTheSameWayEveryTime() {
        let text = (0..<3000).map { "w\($0)" }.joined(separator: "\n")
        let whole = FileChunker.chunks(text, range: 0..<50, cap: 50).chunks
        let later = FileChunker.chunks(text, range: 3..<6, cap: 50)

        #expect(later.chunks.map(\.offset) == whole[3..<6].map(\.offset))
        #expect(later.total == whole.count)
    }

    @Test func aTextWithNoWhitespaceIsStillCut() {
        let text = String(repeating: "abcdefghij", count: 500)
        let (chunks, total) = FileChunker.chunks(text, range: 0..<10, cap: 10)

        #expect(total == 3)
        #expect(chunks.isEmpty, "unbroken runs of letters carry no words and are dropped")
        let minified = String(repeating: "a=b;", count: 1000)
        #expect(FileChunker.chunks(minified, range: 0..<10, cap: 10).chunks.count == 3)
    }

    // MARK: - Text and code

    @Test func plainTextIsReadInChunksWithOffsets() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let text = (0..<800).map { "linje \($0) med skatteårsopgørelse" }.joined(separator: "\n")
        try folder.makeFile("notes.txt", contents: text)

        let result = await Self.read(folder.path("notes.txt"), .text)

        #expect(result.isComplete)
        #expect(result.passages.count == result.readTo)
        #expect(result.passages.allSatisfy { $0.kind == .chunk })
        #expect(result.passages.first?.location == 0)
        #expect(result.passages.first?.text.hasPrefix("linje 0 med skatteårsopgørelse") == true)
    }

    @Test func anUnknownExtensionIsReadWhenItSniffsAsText() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.makeFile("Button.tsx", contents: "export function Button() { return <button>Gem kontrakt</button> }")
        try folder.makeFile(".zshrc", contents: "export PATH=/opt/homebrew/bin:$PATH")
        try folder.makeFile("Dockerfile", contents: "FROM swift:6\nRUN swift build")

        for name in ["Button.tsx", ".zshrc", "Dockerfile"] {
            let result = await Self.read(folder.path(name), .code)
            #expect(result.passages.count == 1, "\(name)")
            #expect(result.detail == nil)
        }
        #expect(await Self.read(folder.path("Button.tsx"), .code).passages.first?.text.contains("Gem kontrakt") == true)
    }

    @Test func binaryIsNotText() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.makeFile("blob", data: Data([0x63, 0x61, 0x66, 0x00, 0x01, 0x02]))
        try folder.makeFile("latin.weird", data: Data([0x62, 0xF8, 0x6E, 0x6E, 0x65]))   // "bønne" in Latin-1

        for name in ["blob", "latin.weird"] {
            let result = await Self.read(folder.path(name), .code)
            #expect(result.passages.isEmpty, "\(name)")
            #expect(result.detail == "not text")
            #expect(result.isComplete)
        }
        // A note in an older encoding is still a note.
        try folder.makeFile("latin.txt", data: Data([0x62, 0xF8, 0x6E, 0x6E, 0x65]))
        #expect(await Self.read(folder.path("latin.txt"), .text).passages.first?.text == "bønne")
    }

    @Test func codeIsReadToItsFirstMegabyteAndNotesFurther() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let line = String(repeating: "x", count: 99) + "\n"
        let big = String(repeating: line, count: (FileContentReader.maxCodeBytes / 100) + 10)
        try folder.makeFile("dump.json", contents: big)
        try folder.makeFile("dump.txt", contents: big)

        let code = try #require(FileContentReader.sniffedText(folder.url.appendingPathComponent("dump.json"),
                                                              limit: FileContentReader.maxCodeBytes))
        #expect(code.isTruncated)
        #expect(code.text.utf8.count == FileContentReader.maxCodeBytes)
        #expect(FileContentReader.sniffedText(folder.url.appendingPathComponent("dump.txt"))?.isTruncated == false)
    }

    @Test func utf16WithAByteOrderMarkIsText() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.makeFile("export.csv", data: "navn;beløb\nFaktura;100".data(using: .utf16)!)

        #expect(await Self.read(folder.path("export.csv"), .code).passages.first?.text == "navn;beløb\nFaktura;100")
    }

    @Test func aLongFileIsReadAStepAtATime() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let text = (0..<20000).map { "word\($0)" }.joined(separator: " ")
        try folder.makeFile("long.log", contents: text)

        let first = await Self.read(folder.path("long.log"), .code)
        #expect(first.passages.count == FileContentReader.firstStep)
        #expect(!first.isComplete)

        let rest = await Self.read(folder.path("long.log"), .code, readTo: first.readTo)
        #expect(rest.isComplete)
        #expect(rest.passages.first?.location ?? 0 > first.passages.last?.location ?? 0)
        let whole = FileChunker.chunks(text, range: 0..<1000, cap: 1000)
        #expect(rest.readTo == whole.total)
    }

    // MARK: - PDF

    @Test func aPDFIsAPassagePerPageWithText() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let long = String(repeating: "Lejekontrakten gælder fra den første i måneden. ", count: 8)
        try Self.makePDF(at: folder.path("contract.pdf"), pages: [long, "Short page", long + " Side tre."])

        let result = await Self.read(folder.path("contract.pdf"), .pdf)

        #expect(result.passages.map(\.kind) == [.page, .page])
        #expect(result.passages.map(\.location) == [1, 3], "page 2 has too little text, and nothing bogus stands for it")
        #expect(result.passages[1].text.contains("Side tre"))
        #expect(result.readTo == 3)
        #expect(result.isComplete)
    }

    /// One page per string, the text drawn so PDFKit reads it back.
    static func makePDF(at path: String, pages: [String]) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try #require(CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil))
        for text in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
                .draw(in: box.insetBy(dx: 40, dy: 40))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    // MARK: - Documents

    @Test func wordAndRTFDocumentsAreRead() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let text = NSAttributedString(string: "Kære udlejer\nHermed opsigelse af lejekontrakten.")
        let range = NSRange(location: 0, length: text.length)
        try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            .write(to: folder.url.appendingPathComponent("letter.docx"))
        try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            .write(to: folder.url.appendingPathComponent("letter.rtf"))

        for name in ["letter.docx", "letter.rtf"] {
            let result = await Self.read(folder.path(name), .document)
            #expect(result.passages.first?.text.contains("opsigelse af lejekontrakten") == true, "\(name)")
            #expect(result.passages.first?.location == 0)
        }
    }

    @Test func aDocxIsAZipTheReaderOpens() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let text = NSAttributedString(string: "Indhold")
        try text.data(from: NSRange(location: 0, length: text.length),
                      documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            .write(to: folder.url.appendingPathComponent("a.docx"))

        let zip = try #require(ZipArchive(url: folder.url.appendingPathComponent("a.docx")))
        #expect(zip.names.contains("word/document.xml"))
        let xml = try #require(zip.contents(of: "word/document.xml"))
        #expect(FileContentReader.plainText(fromXML: String(decoding: xml, as: UTF8.self)).contains("Indhold"))
    }

    @Test func spreadsheetsAndSlidesAreReadFromTheirXML() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.makeFile("x/xl/sharedStrings.xml", contents: """
            <sst><si><t>Faktura</t></si><si><r><t>Bel</t></r><r><t>øb</t></r></si></sst>
            """)
        try folder.makeFile("y/ppt/slides/slide10.xml", contents: "<p:sld><a:p><a:r><a:t>Tiende</a:t></a:r></a:p></p:sld>")
        try folder.makeFile("y/ppt/slides/slide2.xml", contents: "<p:sld><a:p><a:r><a:t>Anden &amp; sidste</a:t></a:r></a:p></p:sld>")
        try Self.makeZip(folder.path("x"), to: folder.path("book.xlsx"))
        try Self.makeZip(folder.path("y"), to: folder.path("deck.pptx"))

        #expect(await Self.read(folder.path("book.xlsx"), .document).passages.first?.text == "Faktura\nBeløb")
        #expect(await Self.read(folder.path("deck.pptx"), .document).passages.first?.text == "Anden & sidste\n\nTiende",
                "slides in their own order")
    }

    /// The system's `zip`, run in `folder` so the entries are relative.
    private static func makeZip(_ folder: String, to archive: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.arguments = ["-qr", archive, "."]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func htmlIsStrippedOfItsTags() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.makeFile("page.html", contents: """
            <html><head><title>T</title><style>p{}</style></head>
            <body><script>var hidden = 1</script><p>Ferie&nbsp;i Ærø</p><p>&#229;bent</p></body></html>
            """)

        let text = await Self.read(folder.path("page.html"), .document).passages.first?.text
        #expect(text == "Ferie i Ærø\nåbent")
    }

    @Test func mailKeepsWhoAndWhatAndThePlainBody() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.makeFile("message.eml", contents: """
            From: Udlejer <udlejer@example.com>\r
            Subject: =?utf-8?Q?Husleje_for_n=C3=A6ste_m=C3=A5ned?=\r
            Received: from mx.example.com\r
            Content-Type: multipart/alternative; boundary="b1"\r
            \r
            --b1\r
            Content-Type: text/plain; charset=utf-8\r
            Content-Transfer-Encoding: quoted-printable\r
            \r
            Husk at betale f=C3=B8r den f=\r
            =C3=B8rste.\r
            --b1\r
            Content-Type: text/html\r
            \r
            <p>HTML copy</p>\r
            --b1--\r
            """)

        let text = try #require(await Self.read(folder.path("message.eml"), .document).passages.first?.text)
        #expect(text.contains("Husleje for næste måned"))
        #expect(text.contains("Udlejer"))
        #expect(text.contains("Husk at betale før den første."))
        #expect(!text.contains("HTML copy"), "the plain part stands for the alternative")
        #expect(!text.contains("mx.example.com"), "routing headers are noise")
    }

    @Test func aWebArchiveIsItsPage() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let archive: [String: Any] = ["WebMainResource": [
            "WebResourceData": Data("<p>Gemt side om kontrakt</p>".utf8),
            "WebResourceTextEncodingName": "UTF-8",
            "WebResourceMIMEType": "text/html",
            "WebResourceURL": "https://example.com"
        ]]
        try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
            .write(to: folder.url.appendingPathComponent("saved.webarchive"))

        #expect(await Self.read(folder.path("saved.webarchive"), .document).passages.first?.text == "Gemt side om kontrakt")
    }

    @Test func anIWorkFileWithoutAPreviewHasNothingToRead() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.makeFile("Letter.pages/Index.zip", data: Data([0x50, 0x4B]))

        let result = await Self.read(folder.path("Letter.pages"), .document)
        #expect(result.passages.isEmpty)
        #expect(result.detail == "no preview")

        try Self.makePDF(at: folder.path("Letter.pages/QuickLook/Preview.pdf"),
                         pages: [String(repeating: "Ansøgning om orlov fra arbejdet. ", count: 10)])
        let withPreview = await Self.read(folder.path("Letter.pages"), .document)
        #expect(withPreview.passages.first?.kind == .page)
        #expect(withPreview.passages.first?.text.contains("orlov") == true)
    }

    // MARK: - Screenshots

    /// Vision runs in the test host, so this reads a real rendered image.
    @Test func aScreenshotIsReadByOCR() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let path = folder.path("Screenshot 2025-01-07 at 19.23.15.png")
        try Self.renderPNG("Invoice 4471 due Friday", to: path)

        let result = await Self.read(path, .screenshot)

        #expect(result.passages.first?.kind == .ocr)
        #expect(result.passages.first?.location == nil)
        #expect(result.passages.first?.text.localizedCaseInsensitiveContains("invoice 4471") == true)
    }

    /// `OCR`'s configuration — accurate, language detected — has Danish.
    @Test func ocrReadsDanish() {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        #expect(request.supportedRecognitionLanguages.contains { $0.minimalIdentifier == "da" })
    }

    static func renderPNG(_ text: String, to path: String) throws {
        let image = NSImage(size: NSSize(width: 900, height: 200), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 48),
                                                          .foregroundColor: NSColor.black])
                .draw(at: NSPoint(x: 30, y: 70))
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}
