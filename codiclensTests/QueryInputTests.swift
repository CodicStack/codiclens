import AppKit
import Testing
@testable import codiclens

/// The append-vs-replace rule for the search field. This lived inside a
/// SwiftUI view, reached across into the subject view model's commit flag, and
/// was held together by three re-entrancy guards — so none of it could be tested.
@MainActor
struct QueryInputTests {

    private func makeCoordinator() -> CommandCoordinator {
        CommandCoordinator(
            runner: RecordingEffectRunner(),
            history: ClipboardHistory(store: InMemoryClipboardStore())
        )
    }

    /// Puts the coordinator in the state the rule cares about: a settled
    /// subject search whose selected result is an app, not free text.
    private func settledAppSearch(_ coordinator: CommandCoordinator, query: String) {
        coordinator.subjectVM.searchText = query
        coordinator.subjectVM.results = [Subject(
            displayName: "Safari",
            path: "/Applications/Safari.app",
            url: URL(fileURLWithPath: "/Applications/Safari.app"),
            icon: NSImage(),
            kind: .app(bundleIdentifier: "com.apple.Safari", isRunning: false)
        )]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.subjectVM.isSearchCommitted = true
        // The field is showing that query, which is what typing is measured against.
        coordinator.syncQueryDisplay()
    }

    /// Stands in for the text field: holds what is on screen and runs the same
    /// loop `CardContainerView.onChange(of: fieldText)` runs.
    private struct Field {
        var text = ""

        mutating func type(_ characters: String, into coordinator: CommandCoordinator) {
            for character in characters {
                text.append(character)
                guard text != coordinator.displayedQuery else { continue }
                text = coordinator.acceptTypedText(text)
            }
        }

        mutating func showCurrentQuery(_ coordinator: CommandCoordinator) {
            coordinator.syncQueryDisplay()
            text = coordinator.displayedQuery
        }
    }

    // MARK: - The whole interaction

    /// Type "settings", wait for the results, then type "gamer": the field must
    /// end up holding "gamer" alone.
    @Test func typingAfterTheResultsSettleReplacesTheWholeQuery() {
        let coordinator = makeCoordinator()
        var field = Field()

        field.type("settings", into: coordinator)
        #expect(coordinator.currentSearchText == "settings")

        settle(coordinator)
        field.type("gamer", into: coordinator)

        #expect(field.text == "gamer", "the field shows only the new search")
        #expect(coordinator.currentSearchText == "gamer")
    }

    /// Without the pause, the two runs are one query.
    @Test func typingStraightThroughKeepsExtending() {
        let coordinator = makeCoordinator()
        var field = Field()

        field.type("settings", into: coordinator)
        field.type("gamer", into: coordinator)

        #expect(field.text == "settingsgamer")
    }

    @Test func aSettledQueryCanBeReplacedRepeatedly() {
        let coordinator = makeCoordinator()
        var field = Field()

        field.type("settings", into: coordinator)
        settle(coordinator)
        field.type("gamer", into: coordinator)

        settle(coordinator)
        field.type("mail", into: coordinator)

        #expect(field.text == "mail")
        #expect(coordinator.currentSearchText == "mail")
    }

    /// Marks the search as settled, the way the debounce does once results are up.
    private func settle(_ coordinator: CommandCoordinator) {
        coordinator.subjectVM.results = [Subject(
            displayName: "Settings",
            path: nil, url: nil, icon: NSImage(), kind: .builtIn(.settings)
        )]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.subjectVM.isSearchCommitted = true
    }

    // MARK: - While typing

    @Test func charactersExtendTheQueryWhileTheSearchIsStillRunning() {
        let coordinator = makeCoordinator()
        coordinator.subjectVM.searchText = "saf"
        coordinator.subjectVM.isSearchCommitted = false

        coordinator.acceptTypedText("safa")

        #expect(coordinator.currentSearchText == "safa")
    }

    // MARK: - After the search settles

    @Test func typingAfterASettledSearchStartsANewQuery() {
        let coordinator = makeCoordinator()
        settledAppSearch(coordinator, query: "saf")

        coordinator.acceptTypedText("safn")

        #expect(coordinator.currentSearchText == "n", "the new character starts a fresh search")
    }

    /// The field is forced back to the new query, not left showing what was
    /// typed. Every later keystroke is measured against this value, so if it
    /// stays "safn" the next character slices the wrong prefix off.
    @Test func replacingTheQueryAlsoRewritesWhatTheFieldShows() {
        let coordinator = makeCoordinator()
        settledAppSearch(coordinator, query: "saf")

        coordinator.acceptTypedText("safn")

        #expect(coordinator.displayedQuery == "n")
    }

    /// The regression that broke type-to-search-again: after a replace the
    /// search is no longer settled, so the following keystrokes must simply
    /// extend the new query.
    @Test func keystrokesAfterAReplaceExtendTheNewQuery() {
        let coordinator = makeCoordinator()
        settledAppSearch(coordinator, query: "saf")

        coordinator.acceptTypedText("safn")          // replaces: query is "n"
        coordinator.subjectVM.isSearchCommitted = false
        coordinator.acceptTypedText("no")            // the field now holds "n" + "o"
        coordinator.acceptTypedText("not")

        #expect(coordinator.currentSearchText == "not")
        #expect(coordinator.displayedQuery == "not")
    }

    /// Typing twice in a row without the search settling in between must not
    /// replace twice.
    @Test func aSecondReplaceNeedsTheSearchToSettleAgain() {
        let coordinator = makeCoordinator()
        settledAppSearch(coordinator, query: "saf")

        coordinator.acceptTypedText("safn")
        coordinator.acceptTypedText("nx")

        #expect(
            coordinator.currentSearchText == "nx",
            "still committed, but the field already shows the new query"
        )
    }

    @Test func pastingAfterASettledSearchStartsANewQuery() {
        let coordinator = makeCoordinator()
        settledAppSearch(coordinator, query: "saf")

        coordinator.acceptTypedText("safnotes app")

        #expect(coordinator.currentSearchText == "notes app")
    }

    @Test func deletingAfterASettledSearchIsTakenLiterally() {
        let coordinator = makeCoordinator()
        settledAppSearch(coordinator, query: "saf")

        coordinator.acceptTypedText("sa")

        #expect(coordinator.currentSearchText == "sa", "a backspace shortens, it doesn't replace")
    }

    @Test func clearingTheFieldClearsTheQuery() {
        let coordinator = makeCoordinator()
        settledAppSearch(coordinator, query: "saf")

        coordinator.acceptTypedText("")

        #expect(coordinator.currentSearchText.isEmpty)
    }

    // MARK: - Text mode is exempt

    @Test func textModeKeepsExtendingEvenOnceSettled() {
        let coordinator = makeCoordinator()
        coordinator.subjectVM.searchText = "hello"
        coordinator.subjectVM.results = [Subject(text: "hello")]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.subjectVM.isSearchCommitted = true

        coordinator.acceptTypedText("hello world")

        #expect(
            coordinator.currentSearchText == "hello world",
            "in text mode the query is the content being written"
        )
    }

    // MARK: - Other phases

    @Test func filteringActionsAlwaysExtends() {
        let coordinator = makeCoordinator()
        coordinator.subjectVM.isSearchCommitted = true
        coordinator.phase = .pickingAction

        coordinator.acceptTypedText("co")
        coordinator.acceptTypedText("cop")

        #expect(coordinator.actionVM.searchText == "cop")
    }

    @Test func typingWritesToThePhaseItBelongsTo() {
        let coordinator = makeCoordinator()

        coordinator.phase = .searchingSubject
        coordinator.acceptTypedText("subject")
        coordinator.phase = .pickingTarget
        coordinator.acceptTypedText("target")

        #expect(coordinator.subjectVM.searchText == "subject")
        #expect(coordinator.targetVM.searchText == "target")
    }
}
