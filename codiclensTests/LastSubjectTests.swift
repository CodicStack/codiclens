import AppKit
import Testing
@testable import codiclens

/// The **Last Subject**: the Subject the user last acted on — a Clipboard
/// Item, an Emoji, a file, a folder or text, never an app or a Built-in —
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
            preferences: EmojiPreferences(defaults: ThrowawayDefaults())
        )
        let coordinator = CommandCoordinator.isolated(
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
        #expect(coordinator.subjectVM.results.map(\.displayName) == ["Clipboard", "Check for Updates"])
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

    @Test func actingOnABuiltInEndsIt() throws {
        let (coordinator, _) = try makeCoordinator(seededWith: ["hello"])
        pasteFirstClipboardItem(coordinator)
        coordinator.reset()

        coordinator.acceptTypedText("s")
        coordinator.subjectVM.results = [
            Subject(displayName: "Settings", path: nil, url: nil, icon: NSImage(), kind: .builtIn(.settings)),
        ]
        coordinator.subjectVM.selectedIndex = 0
        #expect(coordinator.submit() == [.hide, .showSettings])
        coordinator.reset()

        #expect(coordinator.lastSubject == nil)
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

    // MARK: - Files, folders and text

    /// A folder holding `note.txt` and an `Inbox` folder, for a Path Subject
    /// to resolve. The caller removes it.
    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-last-subject-\(UUID().uuidString)")
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Inbox", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "hello".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        return root
    }

    /// Types the path and opens its Actions.
    private func choose(_ url: URL, _ coordinator: CommandCoordinator) {
        coordinator.subjectVM.searchText = url.path
        coordinator.advancePhase()
    }

    private func selectAction(_ name: String, _ coordinator: CommandCoordinator) throws {
        coordinator.actionVM.selectedIndex = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == name },
            "no Action named \(name)"
        )
    }

    private func generation(of effects: [Effect]) throws -> Int {
        guard case .fileOperation(_, let generation) = try #require(effects.first) else {
            Issue.record("expected a file operation, got \(effects)")
            return -1
        }
        return generation
    }

    @Test func anOpenedFileStandsAndEnterOpensItAgain() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("note.txt")
        let (coordinator, _) = try makeCoordinator()
        coordinator.subjectVM.searchText = note.path
        #expect(coordinator.submit() == [.hide, .open(note)])

        coordinator.reset()

        #expect(coordinator.standingSubject?.url == note)
        #expect(coordinator.subjectVM.searchText.isEmpty, "the Query is empty")
        #expect(coordinator.submit() == [.hide, .open(note)])
    }

    @Test func aFolderActedOnThroughItsActionsStands() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL
        let (coordinator, _) = try makeCoordinator()
        choose(inbox, coordinator)
        try selectAction("Copy Path", coordinator)
        coordinator.submit()

        coordinator.reset()

        guard case .folder? = coordinator.standingSubject?.kind else {
            Issue.record("expected a folder, got \(String(describing: coordinator.standingSubject?.kind))")
            return
        }
        #expect(coordinator.standingSubject?.url == inbox)
    }

    /// ⌘E text acted on stands as text, and Enter pastes it again.
    @Test func typedTextStands() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.acceptTypedText("hello")
        coordinator.toggleTextSubjectEdit()
        coordinator.toggleTextSubjectEdit()
        #expect(coordinator.submit() == [.paste(.text("hello"))])

        coordinator.reset()

        guard case .text("hello")? = coordinator.standingSubject?.kind else {
            Issue.record("expected the text, got \(String(describing: coordinator.standingSubject?.kind))")
            return
        }
        #expect(coordinator.submit() == [.paste(.text("hello"))])
    }

    /// What a transform turned the text into is what it left behind.
    @Test func aTransformsOutputStands() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.acceptTypedText("hello")
        coordinator.toggleTextSubjectEdit()
        coordinator.toggleTextSubjectEdit()
        coordinator.advancePhase()
        try selectAction("UPPERCASE", coordinator)
        coordinator.submit()

        guard case .text("HELLO")? = coordinator.standingSubject?.kind else {
            Issue.record("expected the output standing at once, got \(String(describing: coordinator.standingSubject?.kind))")
            return
        }
        coordinator.reset()

        guard case .text("HELLO")? = coordinator.standingSubject?.kind else {
            Issue.record("expected the output, got \(String(describing: coordinator.standingSubject?.kind))")
            return
        }
    }

    @Test func editingStandingTextKeepsItStandingAsTheEdit() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.acceptTypedText("hello")
        coordinator.toggleTextSubjectEdit()
        coordinator.toggleTextSubjectEdit()
        coordinator.submit()
        coordinator.reset()

        coordinator.toggleTextSubjectEdit()
        coordinator.textSubjectEditText = "hello, edited"
        coordinator.toggleTextSubjectEdit()

        #expect(coordinator.submit() == [.paste(.text("hello, edited"))])
        coordinator.reset()
        guard case .text("hello, edited")? = coordinator.standingSubject?.kind else {
            Issue.record("expected the edit, got \(String(describing: coordinator.standingSubject?.kind))")
            return
        }
    }

    @Test func aTrashedFileIsNoLastSubject() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("note.txt")
        let (coordinator, _) = try makeCoordinator()
        coordinator.subjectVM.searchText = note.path
        coordinator.submit()
        coordinator.reset()

        coordinator.advancePhase()
        try selectAction("Move to Trash", coordinator)
        #expect(coordinator.submit() == [.hide, .moveToTrash(note)])
        coordinator.reset()

        #expect(coordinator.lastSubject == nil)
        #expect(coordinator.standingSubject == nil)
    }

    /// Gone from disk by any route is gone: the file is resolved again on
    /// every open, and the Panel opens empty with nothing to shake about.
    @Test func aFileGoneSinceIsNoLastSubjectAndThePanelOpensEmpty() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("note.txt")
        let (coordinator, _) = try makeCoordinator()
        coordinator.subjectVM.searchText = note.path
        coordinator.submit()
        try FileManager.default.removeItem(at: note)

        coordinator.reset()

        #expect(coordinator.standingSubject == nil)
        #expect(coordinator.lastSubject == nil)
        #expect(coordinator.subjectVM.searchText.isEmpty)
        #expect(coordinator.currentResults.isEmpty)
        #expect(!coordinator.hasNoSubjectMatch, "no shake")
    }

    @Test func aRenamedFileIsFollowed() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("note.txt")
        let (coordinator, _) = try makeCoordinator()
        choose(note, coordinator)
        try selectAction("Rename", coordinator)
        coordinator.submit()
        coordinator.renameText = "memo.txt"
        let generation = try generation(of: coordinator.commitRename())

        let renamed = root.appendingPathComponent("memo.txt")
        try FileManager.default.moveItem(at: note, to: renamed)
        coordinator.receiveFileOperation(.success(renamed), generation: generation)
        coordinator.reset()
        #expect(coordinator.standingSubject?.url == renamed)
        #expect(coordinator.standingSubject?.displayName == "memo.txt")
    }

    @Test func aMovedFileIsFollowed() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("note.txt")
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let (coordinator, _) = try makeCoordinator()
        choose(note, coordinator)
        try selectAction("Move To…", coordinator)
        coordinator.advancePhase()
        // The first folder offered. Nothing moves until the test moves it:
        // the runner only records.
        #expect(!coordinator.targetVM.filteredTargets.isEmpty)
        let generation = try generation(of: coordinator.submit())

        let landed = inbox.appendingPathComponent("note.txt")
        try FileManager.default.moveItem(at: note, to: landed)
        coordinator.receiveFileOperation(.success(landed), generation: generation)
        coordinator.reset()

        #expect(coordinator.standingSubject?.url == landed.standardizedFileURL)
    }

    /// Typing ends a file standing, not it being the Last Subject.
    @Test func dismissingAStandingFileAfterTypingKeepsIt() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("note.txt")
        let (coordinator, _) = try makeCoordinator()
        coordinator.subjectVM.searchText = note.path
        coordinator.submit()
        coordinator.reset()
        coordinator.acceptTypedText("x")
        #expect(coordinator.standingSubject == nil)

        coordinator.reset()

        #expect(coordinator.standingSubject?.url == note)
    }

    // MARK: - Backspace

    /// Backspace with the Query empty takes the standing Subject away, and
    /// it is forgotten: the Card says "Type..." and the next opening is empty.
    @Test func backspaceRemovesTheStandingSubjectForGood() throws {
        let (coordinator, _) = try makeCoordinator(seededWith: ["hello"])
        pasteFirstClipboardItem(coordinator)
        coordinator.reset()
        #expect(coordinator.standingSubject != nil)

        #expect(coordinator.removeStandingSubject())

        #expect(coordinator.standingSubject == nil)
        #expect(coordinator.lastSubject == nil)
        #expect(coordinator.subjectVM.cardSubject == nil, "the Card is empty, not holding it")
        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.cardCount == 1)
        #expect(coordinator.submit().isEmpty, "Enter has nothing to act on")

        coordinator.reset()
        #expect(coordinator.standingSubject == nil, "it does not come back")
    }

    /// An Action's result that stands is a Subject like the rest.
    @Test func backspaceRemovesAStandingTransformOutput() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.acceptTypedText("hello")
        coordinator.toggleTextSubjectEdit()
        coordinator.toggleTextSubjectEdit()
        coordinator.advancePhase()
        try selectAction("UPPERCASE", coordinator)
        coordinator.submit()

        #expect(coordinator.removeStandingSubject())
        coordinator.reset()

        #expect(coordinator.standingSubject == nil)
    }

    /// Anywhere else Backspace is the field's, deleting a letter of the Query.
    @Test func backspaceWithAQueryOrNothingStandingIsLeftToTheField() throws {
        let (coordinator, _) = try makeCoordinator(seededWith: ["hello"])
        #expect(!coordinator.removeStandingSubject(), "nothing stands")

        pasteFirstClipboardItem(coordinator)
        coordinator.reset()
        coordinator.subjectVM.searchText = "x"
        #expect(!coordinator.removeStandingSubject(), "a Query is there to delete from")
        #expect(coordinator.lastSubject != nil)

        coordinator.reset()
        coordinator.acceptTypedText("x")
        #expect(!coordinator.removeStandingSubject(), "typing ended it standing")
        #expect(coordinator.lastSubject != nil, "and did not forget it")
    }

    /// The editor holds the keyboard; its Backspace edits the text.
    @Test func backspaceInTheEditorLeavesTheStandingTextAlone() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.acceptTypedText("hello")
        coordinator.toggleTextSubjectEdit()
        coordinator.toggleTextSubjectEdit()
        coordinator.submit()
        coordinator.reset()

        coordinator.toggleTextSubjectEdit()
        #expect(coordinator.isEditingTextSubject)
        #expect(!coordinator.removeStandingSubject())
        #expect(coordinator.lastSubject != nil)
    }
}
