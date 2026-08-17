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
