import AppKit
import Testing
@testable import codiclens

/// The Check for Updates Built-in, through the phase machine. The coordinator
/// only says what should happen; the check itself is the updater's, behind
/// the Effect seam (ADR 0007).
@MainActor
struct UpdateCommandTests {

    private func makeCoordinator() -> (CommandCoordinator, RecordingEffectRunner) {
        let runner = RecordingEffectRunner()
        return (CommandCoordinator.isolated(runner: runner), runner)
    }

    @Test func typingUpdatesFindsTheBuiltIn() throws {
        let (coordinator, _) = makeCoordinator()

        coordinator.subjectVM.searchText = "updates"

        let subject = try #require(coordinator.subjectVM.results.first)
        #expect(subject.displayName == "Check for Updates")
        guard case .builtIn(.checkForUpdates) = subject.kind else {
            Issue.record("expected the Check for Updates Built-in, got \(subject.kind)")
            return
        }
    }

    @Test func enterHidesThePanelThenChecks() {
        let (coordinator, runner) = makeCoordinator()
        coordinator.subjectVM.searchText = "check for updates"

        let effects = coordinator.submit()

        #expect(effects == [.hide, .update(.check)])
        #expect(runner.recorded == effects)
    }

    @Test func itsOneActionChecksToo() throws {
        let (coordinator, _) = makeCoordinator()
        coordinator.subjectVM.searchText = "check for updates"
        coordinator.advancePhase()

        #expect(coordinator.phase == .pickingAction)
        #expect(coordinator.actionVM.filteredActions.map(\.name) == ["Check"])
        #expect(coordinator.submit() == [.hide, .update(.check)])
    }

    @Test func itNeverBecomesTheLastSubject() {
        let (coordinator, _) = makeCoordinator()
        coordinator.subjectVM.searchText = "check for updates"
        _ = coordinator.submit()

        #expect(coordinator.lastSubject == nil)
    }

    @Test func itIsOneOfTheBuiltInsSwitchedOffTogether() {
        let sources = SourceStore(defaults: ThrowawayDefaults())
        sources.setEnabled(false, for: "built-ins")
        let coordinator = CommandCoordinator.isolated(sources: sources)

        coordinator.subjectVM.searchText = "check for updates"

        #expect(!coordinator.subjectVM.results.contains { $0.displayName == "Check for Updates" })
    }
}
