import Foundation
import Testing
@testable import codiclens

/// The updater seam, driven through `FakeUpdater`: Sparkle's events go in,
/// in the app's words, and what comes out is the state the Update Notice
/// and Settings read. Nothing here touches Sparkle or the network.
@MainActor
struct UpdaterTests {

    @Test func startsWithNoUpdate() {
        let updater = FakeUpdater()

        #expect(updater.state == .none)
        #expect(updater.requests.isEmpty)
    }

    @Test func aScheduledCheckThatFindsAnUpdateMakesItAvailable() {
        let updater = FakeUpdater()

        updater.send(.scheduledUpdateFound(version: "1.0.3", isDownloaded: false))

        #expect(updater.state == .available(version: "1.0.3"))
    }

    @Test func anUpdateAlreadyDownloadedIsReady() {
        let updater = FakeUpdater()

        updater.send(.scheduledUpdateFound(version: "1.0.3", isDownloaded: true))

        #expect(updater.state == .ready(version: "1.0.3"))
    }

    @Test func anAutomaticDownloadThatWillInstallOnQuitIsReady() {
        let updater = FakeUpdater()
        updater.send(.scheduledUpdateFound(version: "1.0.3", isDownloaded: false))

        updater.send(.readyToInstall(version: "1.0.3"))

        #expect(updater.state == .ready(version: "1.0.3"))
    }

    @Test func onlyTheNewestVersionIsReported() {
        let updater = FakeUpdater()
        updater.send(.scheduledUpdateFound(version: "1.0.3", isDownloaded: false))

        updater.send(.scheduledUpdateFound(version: "1.0.4", isDownloaded: false))

        #expect(updater.state == .available(version: "1.0.4"))
    }

    /// The user brought the dialog up: it is in front of them, so nothing
    /// else needs to say an update is waiting.
    @Test func theUserSeeingTheDialogClearsIt() {
        let updater = FakeUpdater()
        updater.send(.scheduledUpdateFound(version: "1.0.3", isDownloaded: false))

        updater.send(.userAttended)

        #expect(updater.state == .none)
    }

    /// A ready update stays until it is installed or the session ends. Once
    /// the app holds the install-now block Sparkle stops running update
    /// cycles, so nothing else would ever say it again, and it still installs
    /// on quit: the dialog being in front does not make that untrue.
    @Test func theUserSeeingTheDialogLeavesAReadyUpdate() {
        let updater = FakeUpdater()
        updater.send(.readyToInstall(version: "1.0.3"))

        updater.send(.userAttended)

        #expect(updater.state == .ready(version: "1.0.3"))
    }

    @Test func skippingClearsItUntilANewerVersionIsFound() {
        let updater = FakeUpdater()
        updater.send(.scheduledUpdateFound(version: "1.0.3", isDownloaded: false))

        // Skip This Version: the dialog was seen, then the session ends.
        // Sparkle itself stops offering 1.0.3, so the next event is a newer one.
        updater.send(.userAttended)
        updater.send(.sessionFinished)
        #expect(updater.state == .none)

        updater.send(.scheduledUpdateFound(version: "1.0.4", isDownloaded: false))
        #expect(updater.state == .available(version: "1.0.4"))
    }

    @Test func remindMeLaterBringsItBackAtTheNextScheduledCheck() {
        let updater = FakeUpdater()
        updater.send(.scheduledUpdateFound(version: "1.0.3", isDownloaded: false))
        updater.send(.userAttended)
        updater.send(.sessionFinished)
        #expect(updater.state == .none)

        updater.send(.scheduledUpdateFound(version: "1.0.3", isDownloaded: false))

        #expect(updater.state == .available(version: "1.0.3"))
    }

    @Test func aFinishedSessionClearsIt() {
        let updater = FakeUpdater()
        updater.send(.scheduledUpdateFound(version: "1.0.3", isDownloaded: true))

        updater.send(.sessionFinished)

        #expect(updater.state == .none)
    }

    /// The point of the seam: an update that turns up on its own is only ever
    /// reported, never shown. Showing is a request, and only the user makes one.
    @Test func noEventEverAsksToShowAnything() {
        let updater = FakeUpdater()

        updater.send(.scheduledUpdateFound(version: "1.0.3", isDownloaded: false))
        updater.send(.readyToInstall(version: "1.0.3"))
        updater.send(.scheduledUpdateFound(version: "1.0.4", isDownloaded: true))
        updater.send(.userAttended)
        updater.send(.sessionFinished)

        #expect(updater.requests.isEmpty)
    }

    @Test func requestsAreTakenAsAsked() {
        let updater = FakeUpdater()

        updater.request(.check)
        updater.request(.showWaitingUpdate)
        updater.request(.installReadyUpdate)

        #expect(updater.requests == [.check, .showWaitingUpdate, .installReadyUpdate])
    }

    // MARK: - Settings

    @Test func checksAutomaticallyAndDoesNotDownloadByDefault() {
        let updater = FakeUpdater()

        #expect(updater.checksAutomatically)
        #expect(!updater.downloadsAutomatically)
    }

    @Test func downloadingAutomaticallyIsOnlyOfferedWhileCheckingAutomatically() {
        let updater = FakeUpdater()
        #expect(updater.canDownloadAutomatically)

        updater.checksAutomatically = false

        #expect(!updater.canDownloadAutomatically)
    }

    @Test func theVersionLineSaysWhenItLastChecked() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let twoHoursAgo = now.addingTimeInterval(-2 * 60 * 60)

        #expect(
            UpdateStatusLine.text(version: "1.0.3", lastCheck: twoHoursAgo, now: now, locale: Locale(identifier: "en_US"))
                == "Version 1.0.3 · last checked 2 hours ago"
        )
    }

    @Test func theVersionLineSaysWhenItHasNeverChecked() {
        #expect(
            UpdateStatusLine.text(version: "1.0.3", lastCheck: nil, now: .now, locale: Locale(identifier: "en_US"))
                == "Version 1.0.3 · not checked yet"
        )
    }
}
