import Foundation
import Observation

/// The update Codiclens knows about. Only the newest version is ever named.
enum UpdateState: Equatable {
    case none
    /// Found by a scheduled check, not downloaded. Showing it opens
    /// Sparkle's dialog.
    case available(version: String)
    /// Downloaded and waiting to install when Codiclens quits. Installing it
    /// now restarts straight into it.
    case ready(version: String)
}

/// What the update machinery reports, in the app's words. Sparkle's
/// user-driver and updater delegates translate into these; a test sends them
/// to `FakeUpdater` directly.
enum UpdateEvent: Equatable {
    /// A scheduled check found an update and, as asked, left showing it to
    /// the app instead of opening a window. This is what raises the Update
    /// Notice. Never sent for a check the user asked for: then Sparkle's own
    /// dialog is already showing it.
    case scheduledUpdateFound(version: String, isDownloaded: Bool)
    /// An automatic download finished and will install when Codiclens quits.
    case readyToInstall(version: String)
    /// The user has the update in front of them: they brought the dialog up,
    /// or chose in it.
    case userAttended
    /// The update session ended: skipped, put off, failed or dismissed.
    case sessionFinished
}

/// What the user can ask of the updater. Nothing else ever asks: an update
/// that turns up on its own is reported through `UpdateState` and shown only
/// when one of these says so.
enum UpdateRequest: Equatable {
    /// Check now. A waiting update is shown instead of checking again.
    case check
    /// Bring Sparkle's dialog up for the waiting update.
    case showWaitingUpdate
    /// Install the ready update now and relaunch into it.
    case installReadyUpdate
}

extension UpdateState {
    /// Where an event leaves the state. Shared by the Sparkle-backed updater
    /// and the fake, so the tests drive the rules the app runs.
    func applying(_ event: UpdateEvent) -> UpdateState {
        switch event {
        case .scheduledUpdateFound(let version, let isDownloaded):
            isDownloaded ? .ready(version: version) : .available(version: version)
        case .readyToInstall(let version):
            .ready(version: version)
        case .userAttended, .sessionFinished:
            .none
        }
    }
}

/// The app's updater: the one place that knows updates exist. The Panel's
/// Update Notice, Settings → General → Updates and the Effect runner read
/// and ask only this, never Sparkle. `SparkleUpdater` in the app,
/// `FakeUpdater` in tests.
///
/// Observable, so a SwiftUI view reading `state` or the two flags redraws
/// when they change.
@MainActor
protocol Updater: AnyObject, Observable {
    /// The update waiting, if any.
    var state: UpdateState { get }
    /// This build's version, as the user sees it (`CFBundleShortVersionString`).
    var version: String { get }
    /// When the last check finished, scheduled or asked for. Nil before the
    /// first.
    var lastCheck: Date? { get }
    /// Checks once a day without being asked. On by default.
    var checksAutomatically: Bool { get set }
    /// Downloads a found update and installs it on quit. Off by default.
    var downloadsAutomatically: Bool { get set }
    /// Whether a check can start now: false while one runs, and always in a
    /// Debug build, whose updater never starts.
    var canCheck: Bool { get }

    func request(_ request: UpdateRequest)
}

extension Updater {
    /// Automatic downloads ride on automatic checks; with checks off there
    /// is nothing to download.
    var canDownloadAutomatically: Bool { checksAutomatically }
}

/// "Version 1.0.3 · last checked 2 hours ago", under the Updates group.
enum UpdateStatusLine {
    static func text(version: String, lastCheck: Date?, now: Date, locale: Locale = .current) -> String {
        guard let lastCheck else { return "Version \(version) · not checked yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return "Version \(version) · last checked \(formatter.localizedString(for: lastCheck, relativeTo: now))"
    }
}
