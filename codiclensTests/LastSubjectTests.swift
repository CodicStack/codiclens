import AppKit
import Testing
@testable import codiclens

/// The **Last Subject**: the Clipboard Item or Emoji the user last acted on,
/// standing as the Subject when the Panel opens again with the Query empty.
///
/// `reset()` is what `PanelController.showPanel()` calls, so a reset is a
/// reopened Panel here.
@MainActor
struct LastSubjectTests {

    private func makeCoordinator(
        seededWith texts: [String] = []
    ) throws -> (CommandCoordinator, ClipboardHistory) {
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        for text in texts { history.recordText(text) }
        let emojiVM = EmojiSearchVM(
            index: try EmojiIndex.bundled(),
            recents: EmojiRecents(store: InMemoryEmojiRecentsStore()),
            preferences: EmojiPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        let coordinator = CommandCoordinator(
            runner: RecordingEffectRunner(),
            history: history,
            emojiVM: emojiVM,
            index: inertAppIndex
        )
        return (coordinator, history)
    }

    /// Opens the Clipboard browser and pastes its first entry.
    private func pasteFirstClipboardItem(_ coordinator: CommandCoordinator) {
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()
        coordinator.submit()
    }

    private func insertEmoji(_ string: String, _ coordinator: CommandCoordinator) throws {
        coordinator.enterEmojiMode()
        coordinator.emojiVM.selectedIndex = try #require(
            coordinator.emojiVM.flattened.firstIndex { $0.string == string }
        )
        coordinator.submit()
    }

    private func notes() -> Subject {
        Subject(
            displayName: "Notes",
            path: "/System/Applications/Notes.app",
            url: URL(fileURLWithPath: "/System/Applications/Notes.app"),
            icon: NSImage(),
            kind: .app(bundleIdentifier: "com.apple.Notes", isRunning: false)
        )
    }

    // MARK: - Standing

    @Test func aPastedClipboardItemStandsWhenThePanelOpensAgain() throws {
        let (coordinator, _) = try makeCoordinator(seededWith: ["hello"])
        coordinator.subjectVM.searchText = "clip"
        pasteFirstClipboardItem(coordinator)

        coordinator.reset()

        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.standingSubject?.clipboardItem?.content == "hello")
        #expect(coordinator.subjectVM.searchText.isEmpty, "the Query is empty")
        #expect(coordinator.currentResults.isEmpty, "it is not a Result")
    }

    @Test func enterOnTheReopenedPanelPastesItAgain() throws {
        let (coordinator, _) = try makeCoordinator(seededWith: ["hello"])
        pasteFirstClipboardItem(coordinator)
        coordinator.reset()

        #expect(coordinator.submit() == [.paste(.text("hello"))])
    }

    @Test func anInsertedEmojiStandsAndEnterInsertsItAgain() throws {
        let (coordinator, _) = try makeCoordinator()
        try insertEmoji("🔥", coordinator)

        coordinator.reset()

        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.standingSubject?.emoji?.string == "🔥")
        #expect(coordinator.submit() == [.paste(.text("🔥"))])
    }

    /// Any Final Action on a Clipboard Item counts, not just Enter's Paste.
    @Test func copyingAClipboardItemThroughItsActionsMakesItTheLastSubject() throws {
        let (coordinator, _) = try makeCoordinator(seededWith: ["hello"])
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()
        coordinator.advancePhase()
        coordinator.actionVM.selectedIndex = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == "Copy" }
        )
        coordinator.submit()

        coordinator.reset()

        #expect(coordinator.standingSubject?.clipboardItem?.content == "hello")
    }

    @Test func tabOpensItsActionsAndShiftTabComesBack() throws {
        let (coordinator, _) = try makeCoordinator(seededWith: ["hello"])
        pasteFirstClipboardItem(coordinator)
        coordinator.reset()

        coordinator.advancePhase()
        #expect(coordinator.phase == .pickingAction)
        #expect(coordinator.selectedClipboardItem?.content == "hello")
        #expect(coordinator.actionVM.filteredActions.first?.name == "Paste")

        coordinator.retreatPhase()
        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.standingSubject?.clipboardItem?.content == "hello")
    }

    @Test func escapeOnItClosesThePanel() throws {
        let (coordinator, _) = try makeCoordinator(seededWith: ["hello"])
        pasteFirstClipboardItem(coordinator)
        coordinator.reset()

        #expect(!coordinator.handleEscape())
    }

    // MARK: - Ending

    @Test func theFirstKeystrokeStartsANewQuery() throws {
        let (coordinator, _) = try makeCoordinator(seededWith: ["hello"])
        pasteFirstClipboardItem(coordinator)
        coordinator.reset()

        coordinator.acceptTypedText("c")

        #expect(coordinator.standingSubject == nil)
        #expect(coordinator.currentSearchText == "c")
        #expect(coordinator.subjectVM.results.map(\.displayName) == ["Clipboard"])
    }

    @Test func aDeletedClipboardItemIsNoLastSubject() throws {
        let (coordinator, _) = try makeCoordinator(seededWith: ["hello"])
        pasteFirstClipboardItem(coordinator)
        coordinator.reset()
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()
        #expect(coordinator.deleteSelectedClipboardItem())

        coordinator.reset()

        #expect(coordinator.standingSubject == nil)
    }

    /// Gone from history by any route — trimmed, or removed from elsewhere — is
    /// gone. The item is looked up again on every open.
    @Test func aClipboardItemNoLongerInHistoryIsNoLastSubject() throws {
        let (coordinator, history) = try makeCoordinator(seededWith: ["hello"])
        pasteFirstClipboardItem(coordinator)
        history.remove(try #require(history.items.first))

        coordinator.reset()

        #expect(coordinator.standingSubject == nil)
    }

    @Test func actingOnAnAppEndsIt() throws {
        let (coordinator, _) = try makeCoordinator(seededWith: ["hello"])
        pasteFirstClipboardItem(coordinator)
        coordinator.reset()

        coordinator.acceptTypedText("n")
        coordinator.subjectVM.results = [notes()]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.submit()
        coordinator.reset()

        #expect(coordinator.standingSubject == nil)
    }

    @Test func actingOnTextEndsIt() throws {
        let (coordinator, _) = try makeCoordinator()
        try insertEmoji("🔥", coordinator)
        coordinator.reset()

        coordinator.acceptTypedText("hello")
        coordinator.toggleTextSubjectEdit()
        coordinator.toggleTextSubjectEdit()
        coordinator.submit()
        coordinator.reset()

        #expect(coordinator.standingSubject == nil)
    }

    /// Typing ends it standing, not it being the Last Subject: dismissed
    /// without acting on anything, the next open stands it again.
    @Test func dismissingAfterTypingKeepsIt() throws {
        let (coordinator, _) = try makeCoordinator(seededWith: ["hello"])
        pasteFirstClipboardItem(coordinator)
        coordinator.reset()
        coordinator.acceptTypedText("x")

        coordinator.reset()

        #expect(coordinator.standingSubject?.clipboardItem?.content == "hello")
    }

    @Test func theEmojiHotkeyOpensTheGridNotTheLastSubject() throws {
        let (coordinator, _) = try makeCoordinator(seededWith: ["hello"])
        pasteFirstClipboardItem(coordinator)

        coordinator.requestEmojiMode()
        coordinator.reset()

        #expect(coordinator.phase == .browsingEmoji)
        #expect(coordinator.standingSubject == nil)
    }

    // MARK: - Editing it

    /// ⌘E on a standing Clipboard Item edits it in history, and what stands —
    /// and what Enter pastes — is the edit.
    @Test func editingTheStandingClipboardItemKeepsItStanding() throws {
        let (coordinator, history) = try makeCoordinator(seededWith: ["hello"])
        pasteFirstClipboardItem(coordinator)
        coordinator.reset()

        coordinator.toggleTextSubjectEdit()
        #expect(coordinator.textSubjectEditText == "hello")
        coordinator.textSubjectEditText = "hello, edited"
        coordinator.toggleTextSubjectEdit()

        #expect(history.items.map(\.content) == ["hello, edited"])
        #expect(coordinator.standingSubject?.clipboardItem?.content == "hello, edited")
        #expect(coordinator.submit() == [.paste(.text("hello, edited"))])

        coordinator.reset()
        #expect(coordinator.standingSubject?.clipboardItem?.content == "hello, edited")
    }
}
