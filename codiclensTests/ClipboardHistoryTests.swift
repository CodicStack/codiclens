import AppKit
import Foundation
import Testing
@testable import codiclens

/// History rules, exercised against an in-memory store. None of this was
/// reachable before: the old singleton started a polling timer in `init` and
/// wrote to the real Application Support directory.
struct ClipboardHistoryTests {

    private func makeHistory(maxItems: Int = 100) -> (ClipboardHistory, InMemoryClipboardStore) {
        let store = InMemoryClipboardStore()
        return (ClipboardHistory(store: store, maxItems: maxItems), store)
    }

    // MARK: - Recording text

    @Test func recordingTextPutsItOnTop() {
        let (history, _) = makeHistory()

        history.recordText("first")
        history.recordText("second")

        #expect(history.items.map(\.content) == ["second", "first"])
    }

    @Test func repeatingTheTopEntryIsIgnored() {
        let (history, _) = makeHistory()

        #expect(history.recordText("hello") == true)
        #expect(history.recordText("hello") == false, "same text is already on top")
        #expect(history.items.count == 1)
    }

    @Test func theSameTextIsRecordedAgainOnceSomethingElseIntervenes() {
        let (history, _) = makeHistory()

        history.recordText("hello")
        history.recordText("world")
        #expect(history.recordText("hello") == true)

        #expect(history.items.map(\.content) == ["hello", "world", "hello"])
    }

    @Test(arguments: ["", "   ", "\n\t "])
    func blankTextIsNeverRecorded(blank: String) {
        let (history, _) = makeHistory()

        #expect(history.recordText(blank) == false)
        #expect(history.items.isEmpty)
    }

    // MARK: - Trimming

    @Test func historyIsTrimmedToItsLimit() {
        let (history, _) = makeHistory(maxItems: 3)

        for i in 1...5 {
            history.recordText("item \(i)")
        }

        #expect(history.items.map(\.content) == ["item 5", "item 4", "item 3"])
    }

    @Test func trimmingDeletesTheImagesItDrops() {
        let (history, store) = makeHistory(maxItems: 1)

        history.recordImage(Data([0x01]), timestamp: Date(timeIntervalSince1970: 0))
        #expect(store.images.count == 1)

        history.recordText("pushes the image out")

        #expect(history.items.count == 1)
        #expect(store.images.isEmpty, "the dropped image's file goes too")
    }

    // MARK: - Images

    @Test func recordingAnImageStoresItsData() {
        let (history, _) = makeHistory()
        let png = Data([0x89, 0x50, 0x4E, 0x47])

        #expect(history.recordImage(png) == true)

        let item = try! #require(history.items.first)
        #expect(item.isImage)
        #expect(history.imageData(for: item) == png)
    }

    @Test func repeatingTheTopImageIsIgnored() {
        let (history, _) = makeHistory()
        let png = Data([0x89, 0x50])

        #expect(history.recordImage(png) == true)
        #expect(history.recordImage(png) == false)
        #expect(history.items.count == 1)
    }

    // MARK: - Editing

    @Test func editingTextReplacesTheEntryInPlace() {
        let (history, _) = makeHistory()
        history.recordText("typo")
        let item = try! #require(history.items.first)

        history.updateText(for: item, text: "fixed")

        #expect(history.items.map(\.content) == ["fixed"])
    }

    @Test func editingAnImageEntryIsRefused() {
        let (history, _) = makeHistory()
        history.recordImage(Data([0x01]))

        history.updateText(at: 0, text: "not allowed")

        #expect(history.items[0].isImage)
        #expect(history.items[0].content == "Image")
    }

    @Test func movingToTopReordersWithoutDuplicating() {
        let (history, _) = makeHistory()
        history.recordText("a")
        history.recordText("b")
        history.recordText("c")
        let oldest = try! #require(history.items.last)

        history.moveToTop(oldest)

        #expect(history.items.map(\.content) == ["a", "c", "b"])
    }

    @Test func removingAnImageDeletesItsFile() {
        let (history, store) = makeHistory()
        history.recordImage(Data([0x01]))
        let item = try! #require(history.items.first)

        history.remove(item)

        #expect(history.items.isEmpty)
        #expect(store.images.isEmpty)
    }

    // MARK: - Persistence

    @Test func historyIsReloadedFromTheStore() {
        let store = InMemoryClipboardStore()
        let first = ClipboardHistory(store: store)
        first.recordText("survives")

        let second = ClipboardHistory(store: store)

        #expect(second.items.map(\.content) == ["survives"])
    }

    // MARK: - Naming

    @Test func screenshotsAreNamedByCaptureTime() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let name = ClipboardHistory.imageFileName(timestamp: stamp, originalURL: nil)

        #expect(name.hasPrefix("Screenshot "))
        #expect(name.hasSuffix(".png"))
    }

    @Test func copiedFilesKeepTheirOwnNameAndExtension() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let source = URL(fileURLWithPath: "/tmp/holiday.JPEG")

        let name = ClipboardHistory.imageFileName(timestamp: stamp, originalURL: source)

        #expect(name.hasPrefix("holiday "))
        #expect(name.hasSuffix(".jpeg"), "the extension is normalised to lowercase")
    }

    @Test func rawImageDataIsAlwaysStoredAsPNG() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let source = URL(fileURLWithPath: "/tmp/holiday.tiff")

        let name = ClipboardHistory.imageFileName(
            timestamp: stamp, originalURL: source, extensionOverride: "png"
        )

        #expect(name.hasSuffix(".png"))
    }
}

struct PasteboardWatcherTests {

    @Test(arguments: ["png", "JPG", "heic", "pdf", "svg"])
    func imageFilesAreRecognised(ext: String) {
        #expect(PasteboardWatcher.isPreviewableImageFile(URL(fileURLWithPath: "/tmp/x.\(ext)")))
    }

    @Test(arguments: ["txt", "swift", "zip", ""])
    func otherFilesAreNot(ext: String) {
        #expect(PasteboardWatcher.isPreviewableImageFile(URL(fileURLWithPath: "/tmp/x.\(ext)")) == false)
    }

    // MARK: - Recording

    /// Counts the conversions, so a test can tell whether the expensive path was
    /// taken at all. Runs inline, which keeps `record()` synchronous here.
    private final class SpyReencoder: ImageReencoder {
        private(set) var conversions = 0

        func reencode(_ convert: @escaping () -> Data?, completion: @escaping (Data?) -> Void) {
            conversions += 1
            completion(convert())
        }
    }

    /// A pasteboard of this test's own, so nothing touches the user's.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("codiclens.tests.\(UUID().uuidString)"))
    }

    private func tiffData() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return try #require(image.tiffRepresentation)
    }

    private static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])

    @Test func tiffIsReencodedAsPNGAwayFromTheCaller() throws {
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        let pasteboard = makePasteboard()
        let spy = SpyReencoder()
        pasteboard.clearContents()
        pasteboard.setData(try tiffData(), forType: .tiff)

        let watcher = PasteboardWatcher(
            history: history, pasteboard: pasteboard, reencoder: spy
        )
        watcher.record()

        #expect(spy.conversions == 1, "the re-encode goes through the seam, not the main thread")
        let item = try #require(history.items.first)
        #expect(item.isImage)
        let stored = try #require(history.imageData(for: item))
        #expect(stored.prefix(4) == Self.pngMagic)
    }

    @Test func pngIsStoredVerbatimWithoutReencoding() throws {
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        let pasteboard = makePasteboard()
        let spy = SpyReencoder()
        let png = Self.pngMagic + Data([0x0D, 0x0A, 0x1A, 0x0A])
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)

        let watcher = PasteboardWatcher(
            history: history, pasteboard: pasteboard, reencoder: spy
        )
        watcher.record()

        #expect(spy.conversions == 0, "nothing to convert, so nothing is dispatched")
        let item = try #require(history.items.first)
        #expect(history.imageData(for: item) == png)
    }

    @Test func textIsRecordedAsText() throws {
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("copied", forType: .string)

        let watcher = PasteboardWatcher(
            history: history, pasteboard: pasteboard, reencoder: InlineImageReencoder()
        )
        watcher.record()

        #expect(history.items.map(\.content) == ["copied"])
    }

    // MARK: - Password managers

    @Test(arguments: PasteboardWatcher.concealedTypes.map(\.rawValue))
    func markedTextIsNeverRecorded(marker: String) {
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(marker))

        let watcher = PasteboardWatcher(
            history: history, pasteboard: pasteboard, reencoder: InlineImageReencoder()
        )
        watcher.record()

        #expect(history.items.isEmpty)
    }

    @Test(arguments: PasteboardWatcher.concealedTypes.map(\.rawValue))
    func markedImagesAreNeverRecordedEither(marker: String) throws {
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        let pasteboard = makePasteboard()
        let spy = SpyReencoder()
        pasteboard.clearContents()
        pasteboard.setData(Self.pngMagic, forType: .png)
        pasteboard.setData(try tiffData(), forType: .tiff)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(marker))

        let watcher = PasteboardWatcher(
            history: history, pasteboard: pasteboard, reencoder: spy
        )
        watcher.record()

        #expect(history.items.isEmpty)
        #expect(spy.conversions == 0, "nothing is decoded on the way to recording nothing")
    }

    @Test func theCopyAfterAPasswordIsRecordedAsUsual() {
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        let pasteboard = makePasteboard()
        let watcher = PasteboardWatcher(
            history: history, pasteboard: pasteboard, reencoder: InlineImageReencoder()
        )

        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setData(Data(), forType: PasteboardWatcher.concealedTypes[0])
        watcher.pollIfChanged()

        pasteboard.clearContents()
        pasteboard.setString("ordinary", forType: .string)
        watcher.pollIfChanged()

        #expect(history.items.map(\.content) == ["ordinary"])
    }

    @Test func undecodableImageDataIsKeptRatherThanDropped() throws {
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        let pasteboard = makePasteboard()
        let junk = Data([0x00, 0x01, 0x02, 0x03])
        pasteboard.clearContents()
        pasteboard.setData(junk, forType: .tiff)

        let watcher = PasteboardWatcher(
            history: history, pasteboard: pasteboard, reencoder: InlineImageReencoder()
        )
        watcher.record()

        let item = try #require(history.items.first)
        #expect(history.imageData(for: item) == junk, "an entry in the wrong format still pastes")
    }
}
