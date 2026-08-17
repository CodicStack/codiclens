import AppKit
import Testing
@testable import codiclens

/// Drives the phase machine through its interface and asserts on the effects
/// it produces. Nothing here touches the pasteboard, the workspace, or the
/// desktop — `RecordingEffectRunner` sits at the seam instead.
@MainActor
struct CommandCoordinatorTests {

    // MARK: - Fixtures

    private static let notesURL = URL(fileURLWithPath: "/System/Applications/Notes.app")

    private func makeCoordinator() -> (CommandCoordinator, RecordingEffectRunner) {
        let runner = RecordingEffectRunner()
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        return (CommandCoordinator(runner: runner, history: history), runner)
    }

    /// Seeds the subject list directly, so tests don't depend on which apps
    /// happen to be installed on the machine running them.
    private func seed(_ coordinator: CommandCoordinator, with subject: Subject) {
        coordinator.subjectVM.results = [subject]
        coordinator.subjectVM.selectedIndex = 0
    }

    private func textSubject(_ text: String) -> Subject {
        Subject(displayName: text, path: nil, url: nil, icon: NSImage(), kind: .text(rawText: text))
    }

    private func appSubject() -> Subject {
        Subject(
            displayName: "Notes",
            path: Self.notesURL.path,
            url: Self.notesURL,
            icon: NSImage(),
            kind: .app(bundleIdentifier: "com.apple.Notes", isRunning: false)
        )
    }

    private func selectAction(_ name: String, in coordinator: CommandCoordinator) throws {
        let index = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == name },
            "no action named \(name)"
        )
        coordinator.actionVM.selectedIndex = index
    }

    // MARK: - Default action (Enter on a subject)

    @Test func enterOnAnAppHidesThenOpensIt() {
        let (coordinator, runner) = makeCoordinator()
        seed(coordinator, with: appSubject())

        let effects = coordinator.submit()

        #expect(effects == [.hide, .open(Self.notesURL)])
        #expect(runner.recorded == effects)
    }

    @Test func enterOnTextCopiesIt() {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: textSubject("hello"))

        #expect(coordinator.submit() == [.hide, .copy(.text("hello"))])
    }

    @Test func enterOnSettingsOpensSettings() {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: Subject(
            displayName: "Settings", path: nil, url: nil, icon: NSImage(), kind: .builtIn(.settings)
        ))

        #expect(coordinator.submit() == [.hide, .showSettings])
    }

    @Test func enterOnClipboardOpensTheBrowserWithoutAnyEffect() {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: Subject(
            displayName: "Clipboard", path: nil, url: nil, icon: NSImage(), kind: .builtIn(.clipboard)
        ))

        #expect(coordinator.submit().isEmpty)
        #expect(coordinator.phase == .browsingClipboard)
    }

    // MARK: - Actions on a subject

    /// No `.hide` before a `.paste`: hiding clears the app to hand activation
    /// back to, so the keystroke would land in the wrong place. Text and
    /// clipboard pastes behave the same way now.
    @Test func pasteActionOnTextEmitsAPasteWithoutHidingFirst() throws {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: textSubject("hello"))
        coordinator.advancePhase()
        try selectAction("Paste", in: coordinator)

        #expect(coordinator.submit() == [.paste(.text("hello"))])
    }

    @Test func copyActionOnTextEmitsACopy() throws {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: textSubject("hello"))
        coordinator.advancePhase()
        try selectAction("Copy", in: coordinator)

        #expect(coordinator.submit() == [.hide, .copy(.text("hello"))])
    }

    @Test func quitActionTerminatesByBundleIdentifier() throws {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: appSubject())
        coordinator.advancePhase()
        try selectAction("Quit", in: coordinator)

        #expect(coordinator.submit() == [.hide, .terminate(bundleIdentifier: "com.apple.Notes")])
    }

    @Test func searchWebPercentEncodesSpaces() throws {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: textSubject("a b"))
        coordinator.advancePhase()
        try selectAction("Search Web", in: coordinator)

        let expected = try #require(URL(string: "https://www.google.com/search?q=a%20b"))
        #expect(coordinator.submit() == [.hide, .open(expected)])
    }

    /// Query separators must survive as part of the search text rather than
    /// splitting the URL into extra parameters.
    @Test(arguments: [
        ("a&c", "a&c"),
        ("swift + kotlin", "swift + kotlin"),
        ("what is a #hashtag", "what is a #hashtag"),
        ("x=1&y=2", "x=1&y=2"),
    ])
    func searchWebKeepsTheWholeQuery(input: String, expected: String) throws {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: textSubject(input))
        coordinator.advancePhase()
        try selectAction("Search Web", in: coordinator)

        let effects = coordinator.submit()
        guard case .open(let url) = try #require(effects.last) else {
            Issue.record("expected the search to open a URL")
            return
        }
        let query = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value
        )
        #expect(query == expected)
    }

    @Test func emailBodyKeepsTheWholeText() throws {
        let url = try #require(CommandCoordinator.mailtoURL(body: "a & b"))
        let body = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "body" })?.value
        )
        #expect(body == "a & b")
    }

    // MARK: - Phase machine

    @Test func transformingTextFeedsTheResultBackAsTheNewSubject() throws {
        let (coordinator, runner) = makeCoordinator()
        seed(coordinator, with: textSubject("hello world"))
        coordinator.advancePhase()
        try selectAction("UPPERCASE", in: coordinator)

        #expect(coordinator.submit().isEmpty, "a transform stays in the panel")
        #expect(runner.recorded.isEmpty)
        #expect(coordinator.phase == .pickingAction)

        let kind = try #require(coordinator.selectedSubject?.kind)
        guard case .text(let rawText) = kind else {
            Issue.record("expected a text subject after transforming")
            return
        }
        #expect(rawText == "HELLO WORLD")
    }

    @Test func aNonFinalActionAdvancesToTargetsWithoutAnyEffect() throws {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: textSubject("hello"))
        coordinator.advancePhase()
        try selectAction("Share…", in: coordinator)

        #expect(coordinator.submit().isEmpty)
        #expect(coordinator.phase == .pickingTarget)
    }

    @Test func enterOnAResultCopiesItThenHides() {
        let (coordinator, _) = makeCoordinator()
        coordinator.phase = .showingResult("11 characters")

        #expect(coordinator.submit() == [.copy(.text("11 characters")), .hide])
    }

    @Test func escapeIsConsumedWhileRetreatingButNotAtTheRoot() {
        let (coordinator, _) = makeCoordinator()

        #expect(coordinator.handleEscape() == false, "root escape dismisses the panel")

        coordinator.phase = .pickingTarget
        #expect(coordinator.handleEscape() == true)
        #expect(coordinator.phase == .pickingAction)
    }

    // MARK: - SearchScope

    @Test func eachPhaseSearchesItsOwnScope() {
        let (coordinator, _) = makeCoordinator()

        coordinator.phase = .searchingSubject
        coordinator.currentSearchText = "subject query"
        coordinator.phase = .pickingAction
        coordinator.currentSearchText = "action query"

        #expect(coordinator.subjectVM.searchText == "subject query")
        #expect(coordinator.actionVM.searchText == "action query")

        coordinator.phase = .searchingSubject
        #expect(coordinator.currentSearchText == "subject query")
    }

    @Test func showingAResultHasNoScope() {
        let (coordinator, _) = makeCoordinator()
        coordinator.phase = .showingResult("done")

        #expect(coordinator.currentScope == nil)
        #expect(coordinator.currentSearchText.isEmpty)
        #expect(coordinator.currentResults.isEmpty)
    }

    @Test func selectionCannotLeaveTheResultList() {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: textSubject("hello"))
        coordinator.subjectVM.isResultsVisible = true

        coordinator.moveUp()
        #expect(coordinator.currentSelectedIndex == 0, "already at the top")

        coordinator.moveDown()
        #expect(coordinator.currentSelectedIndex == 0, "only one result")
    }
}
