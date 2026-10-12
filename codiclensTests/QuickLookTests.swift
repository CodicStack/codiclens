import Foundation
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// Shift+Space and the Quick Look Action: what Quick Look is handed in each
/// Phase, and the `.txt` copy a file gets when Quick Look has no previewer for
/// its type but it holds text.
///
/// Clipboard History is kept by a `FileClipboardStore` in a temp folder, so a
/// text Clipboard Item has a written-out preview to hand over, as in the app.
@MainActor
struct QuickLookTests {

    private struct Fixture {
        let coordinator: CommandCoordinator
        let runner: RecordingEffectRunner
        let history: ClipboardHistory
        let schedule: HeldSearchSchedule
        let root: URL
    }

    /// A temp folder holding the store and `clip notes.txt`. Removed by the
    /// caller.
    private func makeFixture(
        files: [String] = [],
        clipboard: [String] = [],
        disabling disabled: [Source.Kind] = []
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-quicklook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("clip notes.txt"), atomically: true, encoding: .utf8)

        let history = ClipboardHistory(store: FileClipboardStore(root: root.appendingPathComponent("store")))
        for text in clipboard.reversed() { history.recordText(text) }
        let sources = SourceStore(defaults: ThrowawayDefaults())
        for kind in disabled {
            sources.setEnabled(false, for: Source(kind: kind, isEnabled: true).id)
        }
        let hits = files.map { name in
            let url = root.appendingPathComponent(name)
            return FileHit(url: url, name: name, folder: root.path, kind: .file, score: 1)
        }
        let runner = RecordingEffectRunner()
        let schedule = HeldSearchSchedule()
        let coordinator = CommandCoordinator.isolated(
            runner: runner,
            history: history,
            emojiVM: throwawayEmojiVM(index: try EmojiIndex.bundled()),
            sources: sources,
            searchFiles: { _ in hits },
            searchSchedule: schedule
        )
        return Fixture(coordinator: coordinator, runner: runner, history: history, schedule: schedule, root: root)
    }

    private func quickLook(_ url: URL) -> Effect {
        .quickLook(QuickLookContext(items: [QuickLookPreviewItem(url: url)], selectedIndex: 0))
    }

    private func selectAction(_ name: String, in coordinator: CommandCoordinator) throws {
        let index = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == name },
            "no action named \(name)"
        )
        coordinator.actionVM.selectedIndex = index
    }

    // MARK: - Subject search

    @Test func shiftSpaceOnAFileResultPreviewsTheFile() async throws {
        let fixture = try makeFixture(files: ["clip notes.txt"], disabling: [.emoji, .clipboardHistory])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "clip"
        await fixture.schedule.typingPaused()
        coordinator.moveDown()   // past the Clipboard Built-in

        coordinator.triggerQuickLook()

        #expect(fixture.runner.recorded == [quickLook(fixture.root.appendingPathComponent("clip notes.txt"))])
    }

    @Test func shiftSpaceOnAClipboardRowPreviewsItsSnapshot() async throws {
        let fixture = try makeFixture(clipboard: ["clip this"], disabling: [.emoji, .builtIns])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "clip"
        await fixture.schedule.typingPaused()
        let item = try #require(fixture.history.items.first)
        let preview = try #require(fixture.history.previewURL(for: item))

        coordinator.triggerQuickLook()

        #expect(fixture.runner.recorded == [quickLook(preview)])
    }

    @Test func shiftSpaceOnAPathSubjectPreviewsIt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.root.appendingPathComponent("clip notes.txt")
        fixture.coordinator.subjectVM.searchText = file.path

        fixture.coordinator.triggerQuickLook()

        #expect(fixture.runner.recorded == [quickLook(file.standardizedFileURL)])
    }

    @Test func shiftSpaceOnAnEmojiRowDoesNothing() async throws {
        let fixture = try makeFixture(disabling: [.clipboardHistory, .builtIns, .applications])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "paperclip"
        await fixture.schedule.typingPaused()
        #expect(coordinator.subjectVM.results.first?.emoji != nil)

        coordinator.triggerQuickLook()

        #expect(fixture.runner.recorded.isEmpty)
    }

    @Test func shiftSpaceOnTheStandingLastSubjectPreviewsIt() throws {
        let fixture = try makeFixture(clipboard: ["clip this"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()
        coordinator.submit()
        coordinator.reset()
        fixture.runner.clear()
        let item = try #require(coordinator.standingSubject?.clipboardItem)
        let preview = try #require(fixture.history.previewURL(for: item))

        coordinator.triggerQuickLook()

        #expect(fixture.runner.recorded == [quickLook(preview)])
    }

    // MARK: - Action Phase

    @Test func aFileSubjectPreviewsByShiftSpaceAndByItsAction() async throws {
        let fixture = try makeFixture(files: ["clip notes.txt"], disabling: [.emoji, .clipboardHistory, .builtIns])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "clip"
        await fixture.schedule.typingPaused()
        coordinator.advancePhase()
        let expected = quickLook(fixture.root.appendingPathComponent("clip notes.txt").standardizedFileURL)

        coordinator.triggerQuickLook()
        #expect(fixture.runner.recorded == [expected])

        try selectAction("Quick Look", in: coordinator)
        #expect(coordinator.submit() == [expected])
    }

    @Test func aClipboardSubjectFromSearchPreviewsByShiftSpaceAndByItsAction() async throws {
        let fixture = try makeFixture(clipboard: ["clip this"], disabling: [.emoji, .builtIns])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "clip"
        await fixture.schedule.typingPaused()
        coordinator.advancePhase()
        let item = try #require(coordinator.selectedClipboardItem)
        let expected = quickLook(try #require(fixture.history.previewURL(for: item)))

        coordinator.triggerQuickLook()
        #expect(fixture.runner.recorded == [expected])

        try selectAction("Quick Look", in: coordinator)
        #expect(coordinator.submit() == [expected])
    }

    @Test func clipboardModeStillPreviewsTheSelectedItem() throws {
        let fixture = try makeFixture(clipboard: ["newest", "older"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()
        coordinator.moveDown()
        let preview = try #require(fixture.history.previewURL(for: fixture.history.items[1]))

        coordinator.triggerQuickLook()

        #expect(fixture.runner.recorded == [quickLook(preview)])
    }

    // MARK: - Text Quick Look cannot draw

    /// The coordinator's items write their copies beside the Clipboard's text
    /// previews; the Effect still names the file itself.
    @Test func aFileOfUnknownTypeHoldingTextPreviewsAsATextCopy() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.root.appendingPathComponent("Card.codiclenstext")
        try "export const card = 1\n".write(to: file, atomically: true, encoding: .utf8)
        fixture.coordinator.subjectVM.searchText = file.path

        fixture.coordinator.triggerQuickLook()

        guard case .quickLook(let context)? = fixture.runner.recorded.first else {
            Issue.record("expected Quick Look, got \(fixture.runner.recorded)")
            return
        }
        let item = try #require(context.items.first)
        #expect(item.url == file.standardizedFileURL)
        let copy = try #require(item.previewItemURL)
        #expect(copy.lastPathComponent == "Card.codiclenstext.txt")
        #expect(copy.path.hasPrefix(try #require(fixture.history.fileTextPreviewsDirectory).path))
        #expect(try String(contentsOf: copy, encoding: .utf8) == "export const card = 1\n")
        #expect(item.previewItemTitle == "Card.codiclenstext", "the Panel's title is the original's name")
    }

    @Test func aBinaryFileOfUnknownTypeIsHandedOverAsItIs() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("blob.codiclensbin")
        try Data([0x7F, 0x45, 0x4C, 0x46, 0x00, 0x01, 0xFF]).write(to: file)

        let item = QuickLookPreviewItem(url: file, title: "blob.codiclensbin", textCopies: root.appendingPathComponent("copies"))

        #expect(item.previewItemURL == file)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("copies").path))
    }

    /// Whatever this Mac calls `.tsx` — Xcode declares it TypeScript source,
    /// and without Xcode it is a type the system made up — it previews as text.
    @Test func aTSXFilePreviewsAsText() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Button.tsx")
        try "export function Button() { return <button /> }\n".write(to: file, atomically: true, encoding: .utf8)
        let type = try #require(try file.resourceValues(forKeys: [.contentTypeKey]).contentType)

        let item = QuickLookPreviewItem(url: file, title: "Button.tsx", textCopies: root.appendingPathComponent("copies"))

        if type.conforms(to: .text) {
            #expect(item.previewItemURL == file, "Quick Look draws \(type.identifier) itself")
        } else {
            #expect(item.previewItemURL.lastPathComponent == "Button.tsx.txt")
        }
    }

    /// `.ts` is declared as an MPEG-2 transport stream; a TypeScript file is
    /// still text, and a real stream fails the sniff on its first bytes.
    @Test func audioAndVideoTypesAreSniffedAndEverythingElseDeclaredIsNot() throws {
        let transportStream = try #require(UTType("public.mpeg-2-transport-stream"))
        #expect(!QuickLookTextCopy.drawsNatively(transportStream))
        #expect(!QuickLookTextCopy.drawsNatively(.data))
        #expect(QuickLookTextCopy.drawsNatively(.sourceCode))
        #expect(QuickLookTextCopy.drawsNatively(.pdf), "a PDF can be all ASCII, and Quick Look draws it")
        #expect(QuickLookTextCopy.drawsNatively(.png))
        #expect(QuickLookTextCopy.decode(Data([0x47, 0x40, 0x00, 0x10]), isTruncated: false) == nil)
    }

    @Test func aLongFileIsCutAtTheCapAndSaysSo() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("huge.codiclenstext")
        // "é" is two bytes, so the cap lands in the middle of one.
        let text = "a" + String(repeating: "é", count: QuickLookTextCopy.byteCap)
        try text.write(to: file, atomically: true, encoding: .utf8)

        let item = QuickLookPreviewItem(url: file, title: "huge.codiclenstext", textCopies: root.appendingPathComponent("copies"))

        let copy = try #require(item.previewItemURL)
        #expect(copy.pathExtension == "txt")
        let size = try #require(try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size <= QuickLookTextCopy.byteCap)
        #expect(item.previewItemTitle == "huge.codiclenstext (truncated)")
    }

    @Test func theCopyGoesWithItsItem() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.codiclenstext")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        var item: QuickLookPreviewItem? = QuickLookPreviewItem(url: file, textCopies: root.appendingPathComponent("copies"))
        let copy = try #require(item?.previewItemURL)
        #expect(FileManager.default.fileExists(atPath: copy.path))

        item = nil

        #expect(!FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path))
    }

    private func temporaryFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-quicklook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
