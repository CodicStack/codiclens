import AppKit
import Observation
import Sparkle

/// The `Updater` the app runs: Sparkle 2's standard updater and its stock
/// dialog, with every scheduled update turned into a report instead of a
/// window.
///
/// Configured in `codiclens-Info.plist`: the feed, the public EdDSA key, a
/// signed feed and verification before extraction, and automatic checks on
/// from the first launch (no second-launch prompt), once a day. Automatic
/// downloads stay off until the user turns them on. No sandbox services:
/// Codiclens is not sandboxed.
///
/// Never started in a Debug build, so a dev build never checks; its Check
/// Now stays disabled.
///
/// The only file that imports Sparkle. Everything else reads `Updater`.
@MainActor
@Observable
final class SparkleUpdater: Updater {
    private(set) var state: UpdateState = .none
    let version: String
    private(set) var lastCheck: Date?
    private(set) var canCheck = false

    var checksAutomatically: Bool {
        didSet {
            guard sparkle.automaticallyChecksForUpdates != checksAutomatically else { return }
            sparkle.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    var downloadsAutomatically: Bool {
        didSet {
            guard sparkle.automaticallyDownloadsUpdates != downloadsAutomatically else { return }
            sparkle.automaticallyDownloadsUpdates = downloadsAutomatically
        }
    }

    @ObservationIgnored private let delegate = SparkleDelegate()
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var sparkle: SPUUpdater { controller.updater }
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// Sparkle's block that installs the downloaded update now and relaunches,
    /// kept from "will install on quit" for `.installReadyUpdate`.
    @ObservationIgnored private var installNow: (() -> Void)?

    #if DEBUG
    private static let starts = false
    #else
    private static let starts = true
    #endif

    init(bundle: Bundle = .main) {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: delegate
        )
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let sparkle = controller.updater
        checksAutomatically = sparkle.automaticallyChecksForUpdates
        downloadsAutomatically = sparkle.automaticallyDownloadsUpdates
        lastCheck = sparkle.lastUpdateCheckDate

        delegate.onEvent = { [weak self] event in
            guard let self else { return }
            state = state.applying(event)
        }
        delegate.onInstallNow = { [weak self] block in
            self?.installNow = block
        }
        delegate.onCycleFinished = { [weak self] in
            self?.refresh()
        }

        // Sparkle's dialog has its own "Automatically download and install"
        // checkbox, and a check moves the date: mirror what Sparkle holds.
        observations = [
            sparkle.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            sparkle.observe(\.automaticallyDownloadsUpdates) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            sparkle.observe(\.canCheckForUpdates) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            sparkle.observe(\.lastUpdateCheckDate) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ]

        if Self.starts {
            // A misconfigured build (no feed, a malformed key) logs and shows
            // Sparkle's own alert once; there is nothing better to do then.
            controller.startUpdater()
        }
        refresh()
    }

    func request(_ request: UpdateRequest) {
        guard Self.starts else {
            NSLog("[codiclens] updates are off in Debug builds; ignored \(request)")
            return
        }
        if request == .installReadyUpdate, case .ready = state, let installNow {
            installNow()
            return
        }
        // A check and showing the waiting update are the same call: with an
        // update waiting, Sparkle brings its dialog up for it rather than
        // checking again. Codiclens is an accessory app, so it has to come
        // forward for the dialog to be in front.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    private func refresh() {
        let sparkle = sparkle
        if checksAutomatically != sparkle.automaticallyChecksForUpdates {
            checksAutomatically = sparkle.automaticallyChecksForUpdates
        }
        if downloadsAutomatically != sparkle.automaticallyDownloadsUpdates {
            downloadsAutomatically = sparkle.automaticallyDownloadsUpdates
        }
        let canCheck = Self.starts && sparkle.canCheckForUpdates
        if self.canCheck != canCheck { self.canCheck = canCheck }
        if lastCheck != sparkle.lastUpdateCheckDate { lastCheck = sparkle.lastUpdateCheckDate }
    }
}

/// Sparkle's two delegates, translated into `UpdateEvent`s.
///
/// The rule this enforces: Sparkle never shows a scheduled update by itself,
/// at launch or later. It reports it, and the Update Notice says so; the
/// dialog opens only when the user asks.
private final class SparkleDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    var onEvent: ((UpdateEvent) -> Void)?
    var onInstallNow: ((@escaping () -> Void) -> Void)?
    var onCycleFinished: (() -> Void)?

    // MARK: SPUStandardUserDriverDelegate

    /// Codiclens is dockless; without this Sparkle logs that background apps
    /// should implement gentle reminders.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Never, whatever the focus: a login-item launcher must not throw a
    /// window in front of the user's work, or hide one behind it.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    /// Raises the Update Notice for a scheduled update Sparkle left to us. A
    /// check the user asked for is already on screen in Sparkle's dialog.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        let event = UpdateEvent.scheduledUpdateFound(
            version: update.displayVersionString,
            isDownloaded: state.stage != .notDownloaded
        )
        MainActor.assumeIsolated { onEvent?(event) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { onEvent?(.userAttended) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { onEvent?(.sessionFinished) }
    }

    // MARK: SPUUpdaterDelegate

    /// An automatic download is in place. Keeping the block (and answering
    /// true) means "Restart to update" can install it at once; it installs
    /// on quit either way.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        onInstallNow?(immediateInstallHandler)
        onEvent?(.readyToInstall(version: item.displayVersionString))
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        onCycleFinished?()
    }
}
