import AppKit
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// Clipboard entries are subjects now, so they go through the same execution
/// table as apps, files and text. These tests drive the browser end to end.
@MainActor
struct ClipboardCommandTests {

    private func makeCoordinator(
        seededWith texts: [String] = []
    ) -> (CommandCoordinator, RecordingEffectRunner, ClipboardHistory) {
        let runner = RecordingEffectRunner()
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        for text in texts {
            history.recordText(text)
        }
        let coordinator = CommandCoordinator.isolated(runner: runner, history: history, index: inertAppIndex)
        return (coordinator, runner, history)
    }

    /// Opens the clipboard browser with the first entry selected.
    private func browse(_ coordinator: CommandCoordinator) {
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()
    }

    private func selectAction(_ name: String, in coordinator: CommandCoordinator) throws {
        let index = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == name },
            "no action named \(name)"
        )
        coordinator.actionVM.selectedIndex = index
    }

    // MARK: - Pasting

    @Test func enterOnAnEntryPastesIt() {
        let (coordinator, _, _) = makeCoordinator(seededWith: ["hello"])
        browse(coordinator)

        #expect(coordinator.submit() == [.paste(.text("hello"))])
    }

    @Test func pastingMovesTheEntryToTheTop() {
        let (coordinator, _, history) = makeCoordinator(seededWith: ["oldest", "newest"])
        browse(coordinator)
        coordinator.clipboardVM.selectedIndex = 1   // "oldest"

        coordinator.submit()

        #expect(history.items.map(\.content) == ["oldest", "newest"])
    }

    /// Pasting must not be preceded by `.hide`: dismissing the panel clears the
    /// app to hand activation back to, and the paste would land in the wrong place.
    @Test func pastingNeverHidesFirst() throws {
        let (coordinator, _, _) = makeCoordinator(seededWith: ["hello"])
        browse(coordinator)
        coordinator.advancePhase()
        try selectAction("Paste", in: coordinator)

        #expect(coordinator.submit() == [.paste(.text("hello"))])
    }

    // MARK: - Actions

    @Test func copyingAnEntryHidesAndWritesThePasteboard() throws {
        let (coordinator, _, _) = makeCoordinator(seededWith: ["hello"])
        browse(coordinator)
        coordinator.advancePhase()
        try selectAction("Copy", in: coordinator)

        #expect(coordinator.submit() == [.hide, .copy(.text("hello"))])
    }

    @Test func typingAnEntrySynthesisesKeystrokes() throws {
        let (coordinator, _, _) = makeCoordinator(seededWith: ["hello"])
        browse(coordinator)
        coordinator.advancePhase()
        try selectAction("Type Text", in: coordinator)

        #expect(coordinator.submit() == [.typeText("hello")])
    }

    @Test func savingTextOffersAPlainTextFile() throws {
        let (coordinator, _, _) = makeCoordinator(seededWith: ["hello"])
        browse(coordinator)
        coordinator.advancePhase()
        try selectAction("Save as File…", in: coordinator)

        #expect(coordinator.submit() == [.savePanel(
            data: Data("hello".utf8), fileName: "untitled.txt", contentType: .plainText
        )])
    }

    @Test func deletingRemovesTheEntryAndReturnsToTheBrowser() throws {
        let (coordinator, _, history) = makeCoordinator(seededWith: ["keep", "drop"])
        browse(coordinator)
        coordinator.advancePhase()
        try selectAction("Delete from History", in: coordinator)

        #expect(coordinator.submit().isEmpty)
        #expect(history.items.map(\.content) == ["keep"])
        #expect(coordinator.phase == .browsingClipboard)
    }

    @Test func deletingFromTheActionKeepsTheQueryAndSelectsTheNextRow() throws {
        let (coordinator, _, history) = makeCoordinator(seededWith: ["apple tart", "banana", "apple pie"])
        browse(coordinator)
        coordinator.clipboardVM.searchText = "apple"
        let dropped = try #require(coordinator.currentClipboardItem)
        coordinator.advancePhase()
        try selectAction("Delete from History", in: coordinator)

        coordinator.submit()

        #expect(history.items.contains { $0.id == dropped.id } == false)
        #expect(coordinator.phase == .browsingClipboard)
        #expect(coordinator.currentQuery == "apple")
        #expect(coordinator.clipboardVM.filteredItems.count == 1)
        #expect(coordinator.currentClipboardItem?.content.hasPrefix("apple") == true)
    }

    @Test func countingShowsTheResultWithoutLeavingThePanel() throws {
        let (coordinator, runner, _) = makeCoordinator(seededWith: ["a b c"])
        browse(coordinator)
        coordinator.advancePhase()
        try selectAction("Count Words", in: coordinator)

        #expect(coordinator.submit().isEmpty)
        #expect(runner.recorded.isEmpty)
        #expect(coordinator.phase == .showingResult("3 words"))
    }

    // MARK: - Transforms

    @Test func transformingAnEntryRewritesItInHistory() throws {
        let (coordinator, _, history) = makeCoordinator(seededWith: ["hello"])
        browse(coordinator)
        coordinator.advancePhase()
        try selectAction("UPPERCASE", in: coordinator)

        #expect(coordinator.submit().isEmpty)
        #expect(history.items.map(\.content) == ["HELLO"])
        #expect(coordinator.phase == .browsingClipboard, "stays in the browser")
    }

    /// The same transform on a text subject chains instead of rewriting history —
    /// the one place the merged table still branches on subject kind.
    @Test func transformingTextChainsInsteadOfRewriting() throws {
        let (coordinator, _, history) = makeCoordinator(seededWith: ["untouched"])
        coordinator.subjectVM.results = [Subject(text: "hello")]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.advancePhase()
        try selectAction("UPPERCASE", in: coordinator)

        #expect(coordinator.submit().isEmpty)
        #expect(history.items.map(\.content) == ["untouched"])
        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.standingSubject?.clipboardItem == nil, "the output is text, not an entry")
    }

    // MARK: - Images

    @Test func imageEntriesOfferImageActionsOnly() {
        let (coordinator, _, history) = makeCoordinator()
        history.recordImage(Data([0x89, 0x50]))
        browse(coordinator)
        coordinator.advancePhase()

        let names = coordinator.actionVM.filteredActions.map(\.name)
        #expect(names.contains("Save Image…"))
        #expect(names.contains("Open in Preview"))
        #expect(names.contains("Type Text") == false, "images can't be typed")
        #expect(names.contains("UPPERCASE") == false, "images can't be transformed")
    }

    @Test func textEntriesOfferTextActionsOnly() {
        let (coordinator, _, _) = makeCoordinator(seededWith: ["hello"])
        browse(coordinator)
        coordinator.advancePhase()

        let names = coordinator.actionVM.filteredActions.map(\.name)
        #expect(names.contains("Type Text"))
        #expect(names.contains("UPPERCASE"))
        #expect(names.contains("Save Image…") == false)
    }

    @Test func savingAnImageOffersThePNG() throws {
        let (coordinator, _, history) = makeCoordinator()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        history.recordImage(png)
        browse(coordinator)
        coordinator.advancePhase()
        try selectAction("Save Image…", in: coordinator)

        let effects = coordinator.submit()
        guard case .savePanel(let data, _, let type) = try #require(effects.first) else {
            Issue.record("expected a save panel")
            return
        }
        #expect(data == png)
        #expect(type == .png)
    }

    // MARK: - Cmd+Backspace

    @Test func cmdBackspaceDeletesTheSelectedEntryAndStaysInTheBrowser() {
        let (coordinator, runner, history) = makeCoordinator(seededWith: ["oldest", "middle", "newest"])
        browse(coordinator)
        coordinator.clipboardVM.selectedIndex = 1   // "middle"

        #expect(coordinator.deleteSelectedClipboardItem())

        #expect(history.items.map(\.content) == ["newest", "oldest"])
        #expect(coordinator.phase == .browsingClipboard)
        #expect(coordinator.currentClipboardItem?.content == "oldest", "the row that took its place")
        #expect(runner.recorded.isEmpty, "nothing hides the Panel")
    }

    @Test func cmdBackspaceKeepsTheQuery() {
        let (coordinator, _, history) = makeCoordinator(seededWith: ["apple tart", "banana", "apple pie"])
        browse(coordinator)
        coordinator.clipboardVM.searchText = "apple"
        let dropped = coordinator.currentClipboardItem

        #expect(coordinator.deleteSelectedClipboardItem())

        #expect(history.items.count == 2)
        #expect(history.items.contains { $0.id == dropped?.id } == false)
        #expect(coordinator.currentQuery == "apple")
        #expect(coordinator.clipboardVM.filteredItems.count == 1)
        #expect(coordinator.currentClipboardItem?.content.hasPrefix("apple") == true)
    }

    @Test func cmdBackspaceOnTheLastRowSelectsTheNewLastRow() {
        let (coordinator, _, _) = makeCoordinator(seededWith: ["oldest", "middle", "newest"])
        browse(coordinator)
        coordinator.clipboardVM.selectedIndex = 2   // "oldest"

        coordinator.deleteSelectedClipboardItem()

        #expect(coordinator.clipboardVM.selectedIndex == 1)
        #expect(coordinator.currentClipboardItem?.content == "middle")
    }

    @Test func cmdBackspaceOnTheOnlyEntryLeavesAnEmptyBrowser() {
        let (coordinator, _, history) = makeCoordinator(seededWith: ["only"])
        browse(coordinator)

        coordinator.deleteSelectedClipboardItem()

        #expect(history.items.isEmpty)
        #expect(coordinator.phase == .browsingClipboard)
        #expect(coordinator.currentClipboardItem == nil)
        #expect(coordinator.currentResults.isEmpty)
    }

    @Test func cmdBackspaceDeletesAnImageEntrysStoredPNG() {
        let store = InMemoryClipboardStore()
        let history = ClipboardHistory(store: store)
        history.recordImage(Data([0x89, 0x50, 0x4E, 0x47]))
        let coordinator = CommandCoordinator.isolated(
            runner: RecordingEffectRunner(), history: history, index: inertAppIndex
        )
        browse(coordinator)
        #expect(store.images.count == 1)

        #expect(coordinator.deleteSelectedClipboardItem())

        #expect(history.items.isEmpty)
        #expect(store.images.isEmpty)
    }

    /// Outside Clipboard Mode the key retreats the Phase instead, which the view
    /// does on `false` — and nothing is deleted on the way.
    @Test func cmdBackspaceDeletesNothingOnceAnEntryIsTheSubject() {
        let (coordinator, _, history) = makeCoordinator(seededWith: ["hello"])
        browse(coordinator)
        coordinator.advancePhase()
        #expect(coordinator.phase == .pickingAction)

        #expect(coordinator.deleteSelectedClipboardItem() == false)
        #expect(history.items.map(\.content) == ["hello"])
        #expect(coordinator.phase == .pickingAction)
    }

    @Test func cmdBackspaceDeletesNothingInSubjectSearch() {
        let (coordinator, _, history) = makeCoordinator(seededWith: ["hello"])

        #expect(coordinator.deleteSelectedClipboardItem() == false)
        #expect(history.items.map(\.content) == ["hello"])
    }

    @Test func cmdBackspaceDeletesNothingWhileTheEntryIsBeingEdited() {
        let (coordinator, _, history) = makeCoordinator(seededWith: ["hello"])
        browse(coordinator)
        coordinator.toggleTextSubjectEdit()
        #expect(coordinator.isEditingTextSubject)

        #expect(coordinator.deleteSelectedClipboardItem() == false)
        #expect(history.items.map(\.content) == ["hello"])
    }

    // MARK: - Save To…

    private struct SaveToFixture {
        let root: URL
        let folder: URL
        let coordinator: CommandCoordinator
        let history: ClipboardHistory
    }

    /// A coordinator whose only folder Source is a temporary `Saved` folder,
    /// over a history `seed` fills.
    private func makeSaveToFixture(_ seed: (ClipboardHistory) -> Void) throws -> SaveToFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-save-to-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Saved", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let defaults = ThrowawayDefaults()
        defaults.set([String](), forKey: "codiclens.sources.folders")
        let sources = SourceStore(defaults: defaults)
        sources.addFolder(folder)

        let history = ClipboardHistory(store: InMemoryClipboardStore())
        seed(history)
        let coordinator = CommandCoordinator.isolated(history: history, sources: sources)
        return SaveToFixture(root: root, folder: folder.standardizedFileURL, coordinator: coordinator, history: history)
    }

    /// From the browser's selected row to Save To…'s folder list, `folder`
    /// selected.
    private func pickSaveTo(_ folder: URL, in coordinator: CommandCoordinator) throws {
        coordinator.advancePhase()
        try selectAction("Save To…", in: coordinator)
        coordinator.advancePhase()
        #expect(coordinator.phase == .pickingTarget)
        coordinator.targetVM.selectedIndex = try #require(
            coordinator.targetVM.filteredTargets.firstIndex { $0.url?.standardizedFileURL == folder },
            "no Target at \(folder.path)"
        )
    }

    @Test func saveToListsTheFoldersCopyToDoes() throws {
        let fixture = try makeSaveToFixture { $0.recordText("hello") }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        browse(coordinator)
        coordinator.advancePhase()
        try selectAction("Save To…", in: coordinator)
        coordinator.advancePhase()

        let listed = coordinator.targetVM.filteredTargets.compactMap { $0.url?.standardizedFileURL.path }
        #expect(listed == coordinator.destinationFolders().map(\.standardizedFileURL.path))
        #expect(listed.contains(fixture.folder.path))
    }

    @Test func savingTextToAFolderWritesATxtNamedFromItsFirstLine() throws {
        let text = "\n  Shopping   list\nmilk"
        let fixture = try makeSaveToFixture { $0.recordText(text) }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        browse(coordinator)
        try pickSaveTo(fixture.folder, in: coordinator)

        let effects = coordinator.submit()
        guard case .fileOperation(_, let generation) = try #require(effects.first) else {
            Issue.record("expected a file operation, got \(effects)")
            return
        }
        #expect(effects == [.fileOperation(
            .save(.text(text), into: fixture.folder, named: "Shopping list.txt"),
            generation: generation
        )], "no .hide: the saved file stands in the Panel")
        #expect(coordinator.isFileOperationInFlight)
        #expect(coordinator.fileOperationNote == "Saving…")
    }

    @Test func savingAnImageCopiesItsStoredFileUnderTheOriginalsName() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let fixture = try makeSaveToFixture {
            $0.recordImage(png, originalURL: URL(fileURLWithPath: "/Users/someone/Pictures/Holiday.jpeg"))
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        let item = try #require(fixture.history.items.first)
        let stored = try #require(fixture.history.imageURL(for: item))
        browse(coordinator)
        try pickSaveTo(fixture.folder, in: coordinator)

        let effects = coordinator.submit()
        guard case .fileOperation(_, let generation) = try #require(effects.first) else {
            Issue.record("expected a file operation, got \(effects)")
            return
        }
        #expect(effects == [.fileOperation(
            .save(.copy(of: stored), into: fixture.folder, named: "Holiday.png"),
            generation: generation
        )])
    }

    @Test func anImageCopiedWithoutAFileIsNamedForWhenItWasCopied() throws {
        let copied = try #require(Calendar.current.date(from: DateComponents(
            year: 2026, month: 11, day: 7, hour: 14, minute: 3, second: 27
        )))
        let screenshot = ClipboardItem(imageFileName: "Screenshot.png", timestamp: copied)
        let finderCopy = ClipboardItem(imageFileName: "Scan 2026-11-07 at 14.03.27.tiff", originalFilePath: "/tmp/Scan.tiff")

        #expect(CommandCoordinator.saveToFileName(for: screenshot) == "Image 2026-11-07 at 14.03.27.png")
        #expect(CommandCoordinator.saveToFileName(for: finderCopy) == "Scan.tiff", "the stored file's own format")
        #expect(CommandCoordinator.saveToFileName(for: ClipboardItem(content: "  ")) == "Text.txt")
    }

    /// The saved file stands as Copy To…'s copy does, and the Clipboard Item
    /// stays where it was in history.
    @Test func theSavedFileStandsAndTheItemStaysPut() throws {
        let fixture = try makeSaveToFixture {
            $0.recordText("older note")
            $0.recordText("newest")
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        let before = fixture.history.items.map(\.id)
        browse(coordinator)
        coordinator.clipboardVM.selectedIndex = 1   // "older note"
        try pickSaveTo(fixture.folder, in: coordinator)
        let effects = coordinator.submit()
        guard case .fileOperation(let operation, let generation) = try #require(effects.first) else {
            Issue.record("expected a file operation, got \(effects)")
            return
        }

        let landed = try operation.perform().get()
        coordinator.receiveFileOperation(.success(landed), generation: generation)

        #expect(try String(contentsOf: landed, encoding: .utf8) == "older note")
        #expect(!coordinator.isFileOperationInFlight)
        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.standingSubject?.url?.standardizedFileURL == landed.standardizedFileURL)
        #expect(coordinator.standingSubject?.clipboardItem == nil, "the file, not the Clipboard Item")
        #expect(fixture.history.items.map(\.id) == before, "not moved to the top")
        #expect(coordinator.destinationFolders().first?.standardizedFileURL == fixture.folder)

        coordinator.advancePhase()
        #expect(coordinator.actionVM.filteredActions.first?.name == "Open", "a file's Actions")
    }

    @Test func aFailedSaveStaysOnTheFolderListAndSaysSo() throws {
        let fixture = try makeSaveToFixture { $0.recordText("hello") }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        browse(coordinator)
        try pickSaveTo(fixture.folder, in: coordinator)
        guard case .fileOperation(_, let generation) = try #require(coordinator.submit().first) else {
            Issue.record("expected a file operation")
            return
        }

        coordinator.receiveFileOperation(.failure(.failed), generation: generation)

        #expect(coordinator.fileOperationNote == "Couldn't save")
        #expect(coordinator.phase == .pickingTarget)
        #expect(coordinator.selectedSubject?.clipboardItem?.content == "hello")
    }

    // MARK: - Retreating

    @Test func retreatingFromAClipboardActionReturnsToTheBrowser() {
        let (coordinator, _, _) = makeCoordinator(seededWith: ["hello"])
        browse(coordinator)
        coordinator.advancePhase()
        #expect(coordinator.phase == .pickingAction)

        coordinator.retreatPhase()

        #expect(coordinator.phase == .browsingClipboard)
    }
}
