import AVFoundation
import AppKit
import PDFKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// The Subject Card showing a Passage, and the Panel's own preview, drawn
/// offscreen and read back — the content layer only, as
/// `SubjectCardPictureTests` draws it. Each render is also written to
/// `/tmp/codiclens-step5-*.png` to be looked at.
///
/// Also the thumbnail asked for a Card: large enough to cover it.
@MainActor
struct PassageCardRenderTests {

    private static let scale: CGFloat = 2

    // MARK: - Fixtures

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-passage-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Three seconds of 320×180 video: red, then green, then blue.
    nonisolated static func writeVideo(to url: URL) async throws {
        let width = 320, height = 180
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let colours: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255)]
        let frames = 30
        // Fed as the writer asks, on its queue, never by polling it.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var frame = 0
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "test.passage.video")) {
                while input.isReadyForMoreMediaData && frame < frames {
                    var buffer: CVPixelBuffer?
                    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
                    guard let pixels = buffer else { break }
                    CVPixelBufferLockBaseAddress(pixels, [])
                    let (r, g, b) = colours[frame * colours.count / frames]
                    let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
                    let row = CVPixelBufferGetBytesPerRow(pixels)
                    for y in 0..<height {
                        for x in 0..<width {
                            let i = y * row + x * 4
                            base[i] = b; base[i + 1] = g; base[i + 2] = r; base[i + 3] = 255
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(pixels, [])
                    adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
                    frame += 1
                }
                if frame == frames {
                    frame += 1
                    input.markAsFinished()
                    done.resume()
                }
            }
        }
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
    }

    private func subject(_ url: URL, _ type: UTType, thumbnail: Bool = true, passage: SubjectPassage) -> Subject {
        Subject(
            displayName: url.lastPathComponent, path: url.path, url: url,
            icon: NSWorkspace.shared.icon(forFile: url.path),
            kind: .file(contentType: type), thumbnailURL: thumbnail ? url : nil, passage: passage
        )
    }

    /// What the Card draws on its first frame is the last thumbnail made for
    /// its request, so the test makes it first, as the Card asks for it.
    @discardableResult
    private func warm(_ subject: Subject) async -> NSImage? {
        guard let url = subject.thumbnailURL else { return nil }
        let request = Thumbnails.Request(
            url: url, side: Style.cardSide, scale: Self.scale, fills: true, moment: CardPassage(subject)?.moment
        )
        return await Thumbnails.shared.thumbnail(for: request)
    }

    private struct Card: View {
        let coordinator: CommandCoordinator
        @Namespace private var glass

        var body: some View {
            SubjectCardView(coordinator: coordinator, glassNamespace: glass)
                .frame(width: PanelLayout.cardWidth, height: PanelLayout.cardHeight)
        }
    }

    private func card(_ subject: Subject) -> Card {
        let coordinator = CommandCoordinator.isolated()
        coordinator.subjectVM.results = [subject]
        coordinator.subjectVM.selectedIndex = 0
        return Card(coordinator: coordinator)
    }

    // MARK: - Drawing

    /// The view drawn by an unshown `NSHostingView` (see
    /// `SubjectCardPictureTests.render`), over a mid-grey ground so white
    /// caption text shows in the PNG, and written to `/tmp`.
    private func render<V: View>(_ view: V, size: CGSize, name: String) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.environment(\.displayScale, Self.scale))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return try snapshot(host, name: name)
    }

    private func snapshot(_ view: NSView, name: String) throws -> NSBitmapImageRep {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let ground = NSImage(size: view.bounds.size)
        ground.lockFocus()
        NSColor(white: 0.45, alpha: 1).setFill()
        view.bounds.fill()
        rep.draw(in: view.bounds)
        ground.unlockFocus()
        if let tiff = ground.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/tmp/codiclens-step5-\(name).png"))
        }
        return rep
    }

    /// The colour at a point, in points from the top-left.
    private func colour(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> NSColor? {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        return rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB)
    }

    // MARK: - The Card

    @Test func aTextPassageSitsOverThePictureWithItsWordsUnderlined() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rent notes.txt")
        try "Rent\n\nPlease pay the invoice number 42 by Friday.\n".write(to: url, atomically: true, encoding: .utf8)
        // Through the File Index's own parse of an FTS5 snippet, not ranges typed by hand.
        let passage = SubjectPassage(FileIndexReader.passage(
            snippet: "…Please pay the \u{1}invoice\u{2} number \u{1}42\u{2} by Friday…", page: nil))
        let withPicture = subject(url, .plainText, passage: passage)
        let line = try #require(CardPassage(withPicture)).line
        // `underlined` sets AppKit's key; with SwiftUI imported, `.underlineStyle` reads SwiftUI's.
        let underlinedWords = line.runs.compactMap { run in
            run[AttributeScopes.AppKitAttributes.UnderlineStyleAttribute.self] == nil
                ? nil : String(line[run.range].characters)
        }
        #expect(underlinedWords == ["invoice", "42"])
        await warm(withPicture)

        let rep = try render(card(withPicture), size: CGSize(width: 212, height: 212), name: "card-text")
        #expect(rep.pixelsWide == 424)

        // A file Quick Look cannot draw: the icon layout, the excerpt under the name.
        _ = try render(card(subject(url, .plainText, thumbnail: false, passage: passage)),
                       size: CGSize(width: 212, height: 212), name: "card-text-icon")
    }

    @Test func aPDFPassagePicturesTheMatchedPage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("report.pdf")
        try PassagePreviewTests.writePDF(to: url)
        let pdf = subject(url, .pdf, passage: SubjectPassage(excerpt: "…the invoice number…", matches: [5..<12], page: 2))
        let picture = try #require(await warm(pdf))
        // Covering the Card: the page is portrait, so its width is the Card's.
        #expect(picture.size.width >= Style.cardSide - 1)

        let rep = try render(card(pdf), size: CGSize(width: 212, height: 212), name: "card-pdf")

        // The second page is the green one; a point in its left margin.
        let margin = try #require(colour(rep, Style.cardInset + 8, 60))
        #expect(margin.greenComponent > 0.9 && margin.redComponent < 0.9, "\(margin)")
    }

    @Test func aVideoPassagePicturesTheFrameAtItsSecond() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("talk.mp4")
        try await Self.writeVideo(to: url)
        let video = subject(url, .mpeg4Movie, passage: SubjectPassage(excerpt: "…invoice…", matches: [1..<8], seconds: 2.5))
        let frame = try #require(await warm(video))
        // Filling a 400px Card from a 180px video: the whole frame, never
        // fitted down to a 200×112 one.
        #expect(frame.size.height * Self.scale == 180, "\(frame.size)")

        let rep = try render(card(video), size: CGSize(width: 212, height: 212), name: "card-video")

        let middle = try #require(colour(rep, 106, 70))
        #expect(middle.blueComponent > 0.8 && middle.redComponent < 0.3 && middle.greenComponent < 0.3, "\(middle)")
    }

    // MARK: - Sharpness

    /// A 4:3 photo asked for to fill a square comes back with its short side
    /// at the square's, so filling never upscales it.
    @Test func aFillingThumbnailCoversTheSquare() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("photo.png")
        let context = try #require(CGContext(
            data: nil, width: 1200, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
        let image = try #require(context.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: url)

        let fitted = try #require(await Thumbnails(generator: Thumbnails.system)
            .thumbnail(for: .init(url: url, side: 200, scale: 2)))
        let filling = try #require(await Thumbnails(generator: Thumbnails.system)
            .thumbnail(for: .init(url: url, side: 200, scale: 2, fills: true)))

        #expect(fitted.size.height < 199, "Quick Look fits: \(fitted.size)")
        #expect(filling.size.height >= 199, "covers: \(filling.size)")
        #expect(filling.size.width <= 270, "and no larger than it has to be: \(filling.size)")
    }

    @Test func aFillingRequestAsksForTheLongSide() {
        let request = Thumbnails.Request(url: URL(fileURLWithPath: "/x"), side: 200, scale: 2, fills: true)
        #expect(abs(Thumbnails.fillingSize(request, aspect: 4.0 / 3.0).width - 800.0 / 3) < 0.001)
        #expect(abs(Thumbnails.fillingSize(request, aspect: nil).width - 3200.0 / 9) < 0.001)
        #expect(Thumbnails.fillingSize(request, aspect: 10).width == 800, "capped")
        let row = Thumbnails.Request(url: URL(fileURLWithPath: "/x"), side: 32, scale: 2)
        #expect(Thumbnails.fillingSize(row, aspect: 4.0 / 3.0).width == 32, "a row's icon slot fits")
    }

    // MARK: - The own preview

    @Test func theTextPreviewHighlightsTheMatchedWords() throws {
        var text = (1...60).map { "Line \($0) of a long note about nothing much." }.joined(separator: "\n")
        text += "\nPlease pay the invoice number 42 by Friday.\n"
        text += (61...120).map { "Line \($0) of a long note." }.joined(separator: "\n")
        let passage = SubjectPassage(excerpt: "…pay the invoice number 42…", matches: [9..<16, 24..<26])
        let found = try #require(PassageFind.find(passage, in: text))
        let view = PassageTextView(monospaced: false)
        view.frame = NSRect(x: 0, y: 0, width: 624, height: 320)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view

        view.present(text, found: (NSRange(found.focus, in: text), found.marks.map { NSRange($0, in: text) }))
        view.layoutSubtreeIfNeeded()
        view.layout()

        #expect(view.marks.map { (text as NSString).substring(with: $0) } == ["invoice", "42"])
        #expect(view.contentView.bounds.minY > 300, "scrolled down to the Passage: \(view.contentView.bounds)")
        _ = try snapshot(view, name: "preview-text")
    }

    @Test func thePDFPreviewOpensAtThePage() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("report.pdf")
        try PassagePreviewTests.writePDF(to: url)
        let view = PassagePDFView(frame: NSRect(x: 0, y: 0, width: 624, height: 320))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view

        view.show(url, at: SubjectPassage(excerpt: "…pay the invoice number 42…", matches: [9..<16], page: 2))
        view.layoutSubtreeIfNeeded()

        // Not snapshotted: PDFKit draws its pages in tiled layers, after the
        // fact, and `cacheDisplay` comes back blank.
        #expect(view.currentPage == view.document?.page(at: 1))
    }
}
