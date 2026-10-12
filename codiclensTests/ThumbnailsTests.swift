import AppKit
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// `Thumbnails`: what is asked of Quick Look, when it is asked again, and what a
/// row is left with when it cannot answer. A stand-in generator counts the asks;
/// the last two tests use Quick Look itself on files written to a temp folder.
@MainActor
struct ThumbnailsTests {

    // MARK: - Fixtures

    /// Answers every request with a solid image exactly the requested pixel
    /// size, or with nothing, and remembers what it was asked.
    private final class StandIn: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [Thumbnails.Request] = []
        let answers: Bool

        init(answers: Bool = true) {
            self.answers = answers
        }

        var requests: [Thumbnails.Request] {
            lock.withLock { asked }
        }

        var generator: Thumbnails.Generator {
            { request in
                self.lock.withLock { self.asked.append(request) }
                guard self.answers else { return nil }
                let pixels = Int(request.side * request.scale)
                return ThumbnailsTests.solidImage(width: pixels, height: pixels)
            }
        }
    }

    nonisolated private static func solidImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-thumbnails-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writePNG(in directory: URL, name: String = "photo.png") throws -> URL {
        let image = try #require(Self.solidImage(width: 400, height: 300))
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func writePDF(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("page.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 100, y: 100, width: 400, height: 500))
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private func setModificationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Size

    /// A request is the slot's side in points and the screen's scale, passed
    /// through untouched, and the image comes back sized in points: a 32pt row
    /// on a 2x screen gets 64 pixels drawn in 32 points.
    @Test(arguments: [
        (PanelLayout.resultIconSize, CGFloat(2)),
        (Style.cardSide, 2),
        (PanelLayout.resultIconSize, 1),
    ])
    func aRequestIsTheSlotAndTheScreensScale(side: CGFloat, scale: CGFloat) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writePNG(in: directory)
        let standIn = StandIn()
        let thumbnails = Thumbnails(generator: standIn.generator)

        let image = try #require(await thumbnails.thumbnail(for: .init(url: url, side: side, scale: scale)))

        #expect(standIn.requests == [.init(url: url, side: side, scale: scale)])
        #expect(image.size == NSSize(width: side, height: side))
    }

    // MARK: - Cache

    @Test func theSameFileUnchangedIsGeneratedOnce() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writePNG(in: directory)
        let standIn = StandIn()
        let thumbnails = Thumbnails(generator: standIn.generator)
        let request = Thumbnails.Request(url: url, side: 32, scale: 2)

        let first = await thumbnails.thumbnail(for: request)
        let second = await thumbnails.thumbnail(for: request)

        #expect(standIn.requests.count == 1)
        #expect(first != nil && first === second)
    }

    /// Rotate writes in place: same URL, new modification date. The URL alone
    /// would keep handing out the unrotated picture.
    @Test func aNewModificationDateMakesANewThumbnail() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writePNG(in: directory)
        try setModificationDate(Date(timeIntervalSince1970: 1_000_000), of: url)
        let standIn = StandIn()
        let thumbnails = Thumbnails(generator: standIn.generator)
        let request = Thumbnails.Request(url: url, side: 32, scale: 2)

        let before = try #require(await thumbnails.thumbnail(for: request))
        try setModificationDate(Date(timeIntervalSince1970: 2_000_000), of: url)

        // What a view draws first is still the last thumbnail made…
        #expect(thumbnails.cached(request) === before)
        // …and asking again finds the file changed.
        let after = try #require(await thumbnails.thumbnail(for: request))
        #expect(standIn.requests.count == 2)
        #expect(after !== before)
        #expect(thumbnails.cached(request) === after)
    }

    @Test func aNewSizeOnDiskMakesANewThumbnail() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writePNG(in: directory)
        let date = Date(timeIntervalSince1970: 1_000_000)
        try setModificationDate(date, of: url)
        let standIn = StandIn()
        let thumbnails = Thumbnails(generator: standIn.generator)
        let request = Thumbnails.Request(url: url, side: 32, scale: 2)

        _ = await thumbnails.thumbnail(for: request)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        try setModificationDate(date, of: url)
        _ = await thumbnails.thumbnail(for: request)

        #expect(standIn.requests.count == 2)
    }

    /// A row and the Card ask for the same file at two sizes, and handing one
    /// out for the other is a soft or an oversized picture.
    @Test func twoSizesAreTwoThumbnails() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writePNG(in: directory)
        let standIn = StandIn()
        let thumbnails = Thumbnails(generator: standIn.generator)

        let row = await thumbnails.thumbnail(for: .init(url: url, side: PanelLayout.resultIconSize, scale: 2))
        let card = await thumbnails.thumbnail(for: .init(url: url, side: Style.cardSide, scale: 2))

        #expect(standIn.requests.map(\.side) == [PanelLayout.resultIconSize, Style.cardSide])
        #expect(row?.size.width == PanelLayout.resultIconSize)
        #expect(card?.size.width == Style.cardSide)
    }

    // MARK: - Falling back to the icon

    /// A file Quick Look cannot draw gives no thumbnail, so `ThumbnailImage`
    /// keeps the icon — and it is asked once, not on every appearance.
    @Test func noThumbnailLeavesTheIconAndIsNotAskedAgain() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writePNG(in: directory)
        let standIn = StandIn(answers: false)
        let thumbnails = Thumbnails(generator: standIn.generator)
        let request = Thumbnails.Request(url: url, side: 32, scale: 2)

        #expect(await thumbnails.thumbnail(for: request) == nil)
        #expect(await thumbnails.thumbnail(for: request) == nil)
        #expect(thumbnails.cached(request) == nil)
        #expect(standIn.requests.count == 1)
    }

    /// A folder or an app is its icon. Quick Look is never asked.
    @Test func aDirectoryIsNeverAskedAbout() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let standIn = StandIn()
        let thumbnails = Thumbnails(generator: standIn.generator)

        #expect(await thumbnails.thumbnail(for: .init(url: directory, side: 32, scale: 2)) == nil)
        #expect(await thumbnails.thumbnail(
            for: .init(url: URL(fileURLWithPath: "/System/Applications/Calculator.app"), side: 32, scale: 2)
        ) == nil)
        #expect(standIn.requests.isEmpty)
    }

    @Test func aFileThatIsGoneDropsItsThumbnail() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writePNG(in: directory)
        let thumbnails = Thumbnails(generator: StandIn().generator)
        let request = Thumbnails.Request(url: url, side: 32, scale: 2)

        #expect(await thumbnails.thumbnail(for: request) != nil)
        try FileManager.default.removeItem(at: url)

        #expect(await thumbnails.thumbnail(for: request) == nil)
        #expect(thumbnails.cached(request) == nil)
    }

    // MARK: - Quick Look itself

    @Test func quickLookDrawsAPNG() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writePNG(in: directory)
        let thumbnails = Thumbnails(generator: Thumbnails.quickLook)

        let image = try #require(await thumbnails.thumbnail(for: .init(url: url, side: 32, scale: 2)))

        // Aspect-fit inside the slot: a 4:3 image is as wide as the slot.
        #expect(image.size.width <= 32 && image.size.height <= 32)
        #expect(max(image.size.width, image.size.height) > 16)
    }

    @Test func quickLookDrawsAPDFsFirstPage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writePDF(in: directory)
        let thumbnails = Thumbnails(generator: Thumbnails.quickLook)

        let image = await thumbnails.thumbnail(for: .init(url: url, side: Style.cardIcon, scale: 2))

        #expect(image != nil)
    }
}

/// Which things carry a file to be thumbnailed, and which are their icon.
@MainActor
struct ThumbnailSourceTests {

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-thumbnail-sources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func aFileSubjectIsThumbnailedFromItselfAndAFolderIsNot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        #expect(PathSubject.subject(for: file)?.thumbnailURL == file.standardizedFileURL)
        #expect(PathSubject.subject(for: directory)?.thumbnailURL == nil)
        #expect(
            PathSubject.subject(for: URL(fileURLWithPath: "/System/Applications/Calculator.app"))?.thumbnailURL == nil
        )
    }

    /// A Clipboard Image's row and Subject are drawn from its stored PNG — the
    /// snapshot — never from the file it was copied from.
    @Test func aClipboardImageIsThumbnailedFromItsStoredPNG() throws {
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        history.recordImage(
            Data([0x89, 0x50, 0x4E, 0x47]),
            originalURL: URL(fileURLWithPath: "/tmp/original.png"),
            timestamp: Date(timeIntervalSince1970: 1)
        )
        history.recordText("words", timestamp: Date(timeIntervalSince1970: 2))
        let coordinator = CommandCoordinator.isolated(
            runner: RecordingEffectRunner(),
            history: history,
            index: inertAppIndex
        )
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()

        let rows = coordinator.clipboardVM.displayResults
        let image = try #require(history.items.first { $0.isImage })
        let storedPNG = try #require(history.imageURL(for: image))
        #expect(rows.first { $0.id == image.id.uuidString }?.thumbnailURL == storedPNG)
        #expect(rows.first { $0.name == "words" }?.thumbnailURL == nil)

        coordinator.clipboardVM.selectedIndex = try #require(
            coordinator.clipboardVM.filteredItems.firstIndex { $0.id == image.id }
        )
        coordinator.advancePhase()
        #expect(coordinator.selectedSubject?.thumbnailURL == storedPNG)
    }

    @Test func aFinderTargetCarriesItsFile() {
        let targets = FileTargetSearch.targets(from: ["/tmp/report.pdf"], query: "report")

        #expect(targets.map(\.thumbnailURL) == [URL(fileURLWithPath: "/tmp/report.pdf")])
        #expect(ResultDisplayItem(from: targets[0]).thumbnailURL == URL(fileURLWithPath: "/tmp/report.pdf"))
    }

    /// Rotate answers with a fresh Subject, which is what makes the Card look
    /// at the file again — and the fresh one has to still point at it.
    @Test func aRotatedFileSubjectKeepsItsThumbnailFile() throws {
        let coordinator = CommandCoordinator.isolated(
            runner: RecordingEffectRunner(),
            history: ClipboardHistory(store: InMemoryClipboardStore()),
            index: inertAppIndex
        )
        let url = URL(fileURLWithPath: "/tmp/photo.png")
        let subject = Subject(
            displayName: "photo.png",
            path: url.path,
            url: url,
            icon: NSImage(),
            kind: .file(contentType: .png),
            thumbnailURL: url
        )
        coordinator.subjectVM.results = [subject]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.advancePhase()
        coordinator.actionVM.selectedIndex = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == "Rotate Left" }
        )
        guard case .rotateImage(_, direction: _, generation: let generation) = try #require(coordinator.submit().first) else {
            Issue.record("expected Rotate effect")
            return
        }

        coordinator.receiveImageRotation(succeeded: true, generation: generation)

        #expect(coordinator.selectedSubject?.id != subject.id)
        #expect(coordinator.selectedSubject?.thumbnailURL == url)
    }
}
