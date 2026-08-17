import AppKit

/// Owns which app codiclens took activation from, and how it gives it back.
///
/// The panel is `.nonactivatingPanel`, so normally the previous app stays
/// frontmost and a synthesised Cmd+V lands where the user expects. Quick Look
/// and the save panel both break that by activating codiclens, and then
/// activation has to be handed back explicitly — before any paste is fired,
/// or it goes to the wrong app.
///
/// Every `previousApp` read and write in the app lives here.
final class FocusHandoff {
    private var previousApp: NSRunningApplication?
    private var activationObserver: Any?
    private var timeoutWork: DispatchWorkItem?

    /// How long to wait for the activation notification before giving up and
    /// acting anyway. A guard against a notification that never arrives — not
    /// a delay the normal path depends on.
    private let activationTimeout: TimeInterval = 0.5

    var hasCapturedApp: Bool { previousApp != nil }

    /// Remembers whatever was frontmost, so it can be given activation back.
    func capture(frontmost: NSRunningApplication?) {
        guard frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        previousApp = frontmost
    }

    /// Gives activation back, if codiclens took it, and forgets the app.
    /// Used when dismissing without pasting.
    func restore() {
        if NSApp.isActive, let app = previousApp, !app.isTerminated {
            app.activate()
        }
        clear()
    }

    /// Hands activation back and runs `action` once the app is frontmost again.
    ///
    /// The wait is event-driven — `didActivateApplicationNotification` for that
    /// exact process. If codiclens never took activation there is nothing to
    /// wait for and `action` runs immediately.
    func yield(then action: @escaping () -> Void) {
        guard let app = previousApp,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              !app.isTerminated,
              NSApp.isActive else {
            clear()
            action()
            return
        }

        app.activate()

        let timeout = DispatchWorkItem { [weak self] in
            self?.stopObserving()
            action()
        }
        timeoutWork = timeout

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  activated.processIdentifier == app.processIdentifier else { return }
            timeout.cancel()
            self?.stopObserving()
            action()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + activationTimeout, execute: timeout)
        previousApp = nil
    }

    /// Forgets the captured app and cancels any pending wait.
    func clear() {
        previousApp = nil
        stopObserving()
    }

    private func stopObserving() {
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
        timeoutWork?.cancel()
        timeoutWork = nil
    }
}
