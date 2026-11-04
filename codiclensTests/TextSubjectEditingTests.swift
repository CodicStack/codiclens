import AppKit
import Testing
@testable import codiclens

/// Editing belongs to a **text Subject**, not to the Clipboard.
///
/// It used to be gated on `phase == .browsingClipboard`, so a Clipboard Item
/// was the only thing that could be edited. OCR Text and a transform's output
/// are the same thing to edit, and now they are.
@MainActor
struct TextSubjectEditingTests {

    private func makeCoordinator(
        seededWith texts: [String] = []
    ) -> (CommandCoordinator, ClipboardHistory) {
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        for text in texts { history.recordText(text) }
        let coordinator = CommandCoordinator.isolated(
            runner: RecordingEffectRunner(),
            history: history,
            index: inertAppIndex
        )
        return (coordinator, history)
    }

    private func browse(_ coordinator: CommandCoordinator) {
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()
    }

    // MARK: - The Action order the whole interaction rests on

    /// "Enter right after OCR pastes" depends entirely on this array order, and
    /// nothing else pinned it.
    @Test func aTextSubjectsActionsStartWithPaste() {
        let actions = SubjectAction.actions(for: Subject(text: "hello"))

        #expect(actions.first?.name == "Paste")
        #expect(actions.first?.isFinal == true)
        #expect(actions.dropFirst().first?.name == "Copy")
    }

    // MARK: - A Clipboard Item

    @Test func editingAClipboardItemWritesThroughToHistory() throws {
        let (coordinator, history) = makeCoordinator(seededWith: ["before"])
        browse(coordinator)

        coordinator.toggleTextSubjectEdit()
        #expect(coordinator.isEditingTextSubject)
        #expect(coordinator.textSubjectEditText == "before")

        coordinator.textSubjectEditText = "after"
        coordinator.toggleTextSubjectEdit()

        #expect(!coordinator.isEditingTextSubject)
        #expect(history.items.map(\.content) == ["after"], "history is where a Clipboard Item lives")
    }

    @Test func aClipboardImageCannotBeEdited() {
        let (coordinator, history) = makeCoordinator()
        history.recordImage(Data([0x89, 0x50]))
        browse(coordinator)

        coordinator.toggleTextSubjectEdit()

        #expect(!coordinator.isEditingTextSubject, "an image has no text to edit")
    }

    @Test func tabbingOutOfTheEditorSavesAndGoesToTheActions() throws {
        let (coordinator, history) = makeCoordinator(seededWith: ["before"])
        browse(coordinator)
        coordinator.toggleTextSubjectEdit()
        coordinator.textSubjectEditText = "after"

        coordinator.saveTextSubjectEditAndAdvance()

        #expect(coordinator.phase == .pickingAction)
        #expect(history.items.map(\.content) == ["after"])
        #expect(coordinator.actionVM.filteredActions.first?.name == "Paste")
        #expect(coordinator.submit() == [.paste(.text("after"))])
    }

    // MARK: - Any other text Subject

    /// A transform's output is a text Subject standing in Subject search, and
    /// Ctrl+E reaches it. The old gate refused this outright.
    @Test func aTransformsOutputCanBeEdited() throws {
        let (coordinator, history) = makeCoordinator(seededWith: ["untouched"])
        coordinator.subjectVM.results = [Subject(text: "hello")]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.advancePhase()
        let index = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == "UPPERCASE" }
        )
        coordinator.actionVM.selectedIndex = index
        _ = coordinator.submit()

        coordinator.toggleTextSubjectEdit()
        #expect(coordinator.isEditingTextSubject)
        #expect(coordinator.textSubjectEditText == "HELLO")

        coordinator.textSubjectEditText = "HELLO, EDITED"
        coordinator.saveTextSubjectEdit()

        guard case .text(let rawText)? = coordinator.selectedSubject?.kind else {
            Issue.record("saving keeps it a text Subject")
            return
        }
        #expect(rawText == "HELLO, EDITED")
        #expect(coordinator.actionVM.filteredActions.first?.name == "Paste", "Actions reloaded")
        #expect(history.items.map(\.content) == ["untouched"], "nothing leaked into history")
    }

    /// OCR Text is a text Subject like any other, so it is editable too — and
    /// editing it must not touch the Clipboard Image it came from.
    @Test func ocrTextCanBeEditedWithoutTouchingTheImage() throws {
        let (coordinator, history) = makeCoordinator()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        history.recordImage(png)
        browse(coordinator)
        coordinator.advancePhase()
        let index = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == "OCR" }
        )
        coordinator.actionVM.selectedIndex = index
        _ = coordinator.submit()
        coordinator.receiveOCRText("misread text")

        coordinator.toggleTextSubjectEdit()
        #expect(coordinator.textSubjectEditText == "misread text")
        coordinator.textSubjectEditText = "corrected text"
        coordinator.saveTextSubjectEdit()

        guard case .text(let rawText)? = coordinator.selectedSubject?.kind else {
            Issue.record("saving keeps it a text Subject")
            return
        }
        #expect(rawText == "corrected text")

        let item = try #require(history.items.first)
        #expect(item.isImage, "the Clipboard Image is untouched")
        #expect(history.imageData(for: item) == png)
    }

    @Test func anAppSubjectCannotBeEdited() {
        let (coordinator, _) = makeCoordinator()
        coordinator.subjectVM.results = [Subject(
            displayName: "Notes",
            path: "/System/Applications/Notes.app",
            url: URL(fileURLWithPath: "/System/Applications/Notes.app"),
            icon: NSImage(),
            kind: .app(bundleIdentifier: "com.apple.Notes", isRunning: false)
        )]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.advancePhase()

        coordinator.toggleTextSubjectEdit()

        #expect(!coordinator.isEditingTextSubject)
    }

    // MARK: - ⌘E on a Query

    /// The only way a Query becomes text (ADR 0012): ⌘E opens the editor with
    /// the Query in it, saving stands the text where the Query was, and Tab
    /// goes on to a text Subject's Actions.
    @Test func cmdEOnAQueryOpensTheEditorWithTheQuery() throws {
        let (coordinator, history) = makeCoordinator()
        coordinator.subjectVM.searchText = "hello world"
        #expect(coordinator.subjectVM.results.isEmpty, "nothing matched, and nothing stood in")

        coordinator.toggleTextSubjectEdit()
        #expect(coordinator.isEditingTextSubject)
        #expect(coordinator.textSubjectEditText == "hello world")
        #expect(coordinator.phase == .searchingSubject)

        coordinator.toggleTextSubjectEdit()
        #expect(!coordinator.isEditingTextSubject)
        #expect(coordinator.isTextMode)
        guard case .text(let rawText)? = coordinator.selectedSubject?.kind else {
            Issue.record("saving leaves a text Subject")
            return
        }
        #expect(rawText == "hello world")

        coordinator.advancePhase()
        #expect(coordinator.phase == .pickingAction)
        let index = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == "Search Web" }
        )
        coordinator.actionVM.selectedIndex = index
        let expected = try #require(URL(string: "https://www.google.com/search?q=hello%20world"))
        #expect(coordinator.submit() == [.hide, .open(expected)])
        #expect(history.items.isEmpty, "a Query is not a Clipboard Item")
    }

    /// What is saved is the edit, not the Query, and Enter acts on it.
    @Test func theSavedEditStandsInPlaceOfTheQuery() {
        let (coordinator, _) = makeCoordinator()
        coordinator.subjectVM.searchText = "helo"

        coordinator.toggleTextSubjectEdit()
        coordinator.textSubjectEditText = "hello"
        coordinator.toggleTextSubjectEdit()

        #expect(coordinator.subjectVM.results.map(\.displayName) == ["hello"])
        #expect(coordinator.submit() == [.paste(.text("hello"))])
    }

    /// ⌘E does not care whether an app matched: the user asked for text.
    @Test func cmdEWorksWhenTheQueryMatchedSomething() {
        let (coordinator, _) = makeCoordinator()
        coordinator.subjectVM.searchText = "clip"
        #expect(coordinator.subjectVM.results.map(\.displayName) == ["Clipboard"])

        coordinator.toggleTextSubjectEdit()
        #expect(coordinator.textSubjectEditText == "clip")
        coordinator.toggleTextSubjectEdit()

        #expect(coordinator.isTextMode)
        #expect(coordinator.subjectVM.results.count == 1)
    }

    /// A path Query is a path until the user asks for it as text.
    @Test func cmdEMakesAPathQueryText() {
        let (coordinator, _) = makeCoordinator()
        coordinator.subjectVM.searchText = "/no/such/place"

        coordinator.toggleTextSubjectEdit()

        #expect(coordinator.isEditingTextSubject)
        #expect(coordinator.textSubjectEditText == "/no/such/place")
    }

    /// A URL typed as a Query gets Open URL once it is text.
    @Test func aURLQueryGetsOpenURL() throws {
        let (coordinator, _) = makeCoordinator()
        coordinator.subjectVM.searchText = "https://example.com"
        coordinator.toggleTextSubjectEdit()

        coordinator.saveTextSubjectEditAndAdvance()

        #expect(coordinator.phase == .pickingAction)
        let index = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == "Open URL" }
        )
        coordinator.actionVM.selectedIndex = index
        let url = try #require(URL(string: "https://example.com"))
        #expect(coordinator.submit() == [.hide, .open(url)])
    }

    @Test func cmdEOnAnEmptyQueryDoesNothing() {
        let (coordinator, _) = makeCoordinator()

        coordinator.toggleTextSubjectEdit()

        #expect(!coordinator.isEditingTextSubject)
    }

    /// Escape in the editor discards ⌘E altogether: the Query is a search again.
    @Test func escapeFromTheQueryEditorLeavesTheSearchAsItWas() {
        let (coordinator, _) = makeCoordinator()
        coordinator.subjectVM.searchText = "clip"
        coordinator.toggleTextSubjectEdit()

        #expect(coordinator.handleEscape())

        #expect(!coordinator.isTextMode)
        #expect(coordinator.subjectVM.results.map(\.displayName) == ["Clipboard"])
    }

    /// Escape on the saved text undoes ⌘E, rather than clearing the Query.
    @Test func escapeOnTheStandingTextGoesBackToTheQuery() {
        let (coordinator, _) = makeCoordinator()
        coordinator.subjectVM.searchText = "clip"
        coordinator.toggleTextSubjectEdit()
        coordinator.toggleTextSubjectEdit()

        #expect(coordinator.handleEscape(), "consumed, not a dismissal")

        #expect(!coordinator.isTextMode)
        #expect(coordinator.subjectVM.searchText == "clip")
        #expect(coordinator.subjectVM.results.map(\.displayName) == ["Clipboard"])
    }

    // MARK: - Escape

    @Test func escapeClosesTheEditorWithoutSaving() {
        let (coordinator, history) = makeCoordinator(seededWith: ["before"])
        browse(coordinator)
        coordinator.toggleTextSubjectEdit()
        coordinator.textSubjectEditText = "discarded"

        #expect(coordinator.handleEscape(), "escape is consumed by the editor")

        #expect(!coordinator.isEditingTextSubject)
        #expect(history.items.map(\.content) == ["before"])
    }
}
