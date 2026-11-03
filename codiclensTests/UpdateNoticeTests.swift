import Foundation
import Testing
@testable import codiclens

/// The Update Notice, driven through `FakeUpdater` the way Sparkle would drive
/// it, and acted on through the phase machine (ADR 0007): ⌘U or a click in
/// any Phase hides the Panel and asks the updater, never Sparkle.
@MainActor
struct UpdateNoticeTests {

    private func makeCoordinator() -> (CommandCoordinator, FakeUpdater, RecordingEffectRunner) {
        let runner = RecordingEffectRunner()
        let updater = FakeUpdater()
        return (CommandCoordinator.isolated(runner: runner, updater: updater), updater, runner)
    }

    // MARK: - What it says

    @Test func thereIsNoNoticeWithoutAnUpdate() {
        let (coordinator, _, _) = makeCoordinator()

        #expect(coordinator.updateNotice == nil)
    }

    @Test func anAvailableUpdateNamesItsVersion() {
        let (coordinator, updater, _) = makeCoordinator()

        updater.send(.scheduledUpdateFound(version: "1.0.3", isDownloaded: false))

        #expect(coordinator.updateNotice?.text == "Codiclens 1.0.3 is available")
    }

    @Test func aReadyUpdateSaysRestartToUpdate() {
        let (coordinator, updater, _) = makeCoordinator()
        updater.send(.scheduledUpdateFound(version: "1.0.3", isDownloaded: false))

        updater.send(.readyToInstall(version: "1.0.3"))

        #expect(coordinator.updateNotice?.text == "Codiclens 1.0.3 is ready · Restart to update")
    }

    @Test func onlyTheNewestVersionIsNamed() {
        let (coordinator, updater, _) = makeCoordinator()
        updater.send(.scheduledUpdateFound(version: "1.0.3", isDownloaded: false))

        updater.send(.scheduledUpdateFound(version: "1.0.4", isDownloaded: false))

        #expect(coordinator.updateNotice?.text == "Codiclens 1.0.4 is available")
    }

    @Test func itCarriesTheKeyThatActsOnIt() {
        #expect(UpdateNotice.keyHint == "⌘U")
    }

    @Test func skipHidesItUntilANewerVersion() {
        let (coordinator, updater, _) = makeCoordinator()
        updater.send(.scheduledUpdateFound(version: "1.0.3", isDownloaded: false))

        updater.send(.userAttended)
        updater.send(.sessionFinished)
        #expect(coordinator.updateNotice == nil)

        updater.send(.scheduledUpdateFound(version: "1.0.4", isDownloaded: false))
        #expect(coordinator.updateNotice?.text == "Codiclens 1.0.4 is available")
    }

    @Test func remindMeLaterBringsItBackAtTheNextDailyCheck() {
        let (coordinator, updater, _) = makeCoordinator()
        updater.send(.scheduledUpdateFound(version: "1.0.3", isDownloaded: false))
        updater.send(.userAttended)
        updater.send(.sessionFinished)
        #expect(coordinator.updateNotice == nil)

        updater.send(.scheduledUpdateFound(version: "1.0.3", isDownloaded: false))

        #expect(coordinator.updateNotice?.text == "Codiclens 1.0.3 is available")
    }

    // MARK: - ⌘U and a click

    private static let everyPhase: [CommandCoordinator.Phase] = [
        .searchingSubject, .browsingClipboard, .browsingEmoji,
        .pickingAction, .pickingTarget, .showingResult("Done"),
    ]

    @Test(arguments: everyPhase)
    func actingOnAnAvailableUpdateHidesThePanelThenShowsIt(phase: CommandCoordinator.Phase) {
        let (coordinator, updater, runner) = makeCoordinator()
        updater.send(.scheduledUpdateFound(version: "1.0.3", isDownloaded: false))
        coordinator.phase = phase

        let effects = coordinator.actOnUpdateNotice()

        #expect(effects == [.hide, .update(.showWaitingUpdate)])
        #expect(runner.recorded == effects)
    }

    @Test(arguments: everyPhase)
    func actingOnAReadyUpdateHidesThePanelThenInstallsIt(phase: CommandCoordinator.Phase) {
        let (coordinator, updater, runner) = makeCoordinator()
        updater.send(.readyToInstall(version: "1.0.3"))
        coordinator.phase = phase

        let effects = coordinator.actOnUpdateNotice()

        #expect(effects == [.hide, .update(.installReadyUpdate)])
        #expect(runner.recorded == effects)
    }

    @Test(arguments: everyPhase)
    func withNoUpdateItDoesNothing(phase: CommandCoordinator.Phase) {
        let (coordinator, _, runner) = makeCoordinator()
        coordinator.phase = phase

        #expect(coordinator.actOnUpdateNotice().isEmpty)
        #expect(runner.recorded.isEmpty)
        #expect(coordinator.phase == phase)
    }

    /// The coordinator only says what should happen; the updater is asked by
    /// the Effect runner, after the Panel is on its way out.
    @Test func theCoordinatorNeverAsksTheUpdaterItself() {
        let (coordinator, updater, _) = makeCoordinator()
        updater.send(.scheduledUpdateFound(version: "1.0.3", isDownloaded: false))

        _ = coordinator.actOnUpdateNotice()

        #expect(updater.requests.isEmpty)
    }
}
