import AppKit
import SwiftUI

/// The app's Setup over the real Mac: macOS's shortcut table, the folder
/// Sources, search by meaning's choice, the app's login item and the
/// Accessibility grant, and the window that shows it.
/// Made once, by `AppDelegate`, after the test-host check: nothing a test
/// runs reaches these.
final class SetupController {
    let takeover: ShortcutTakeover
    let openAtLogin: OpenAtLogin
    let setup: Setup
    private var window: NSWindow?
    private var closeObserver: Any?

    init(meaning: MeaningSettings, defaults: UserDefaults = .standard) {
        takeover = ShortcutTakeover(hotKeys: PrivateSymbolicHotKeys(), defaults: defaults)
        openAtLogin = OpenAtLogin(service: MainAppLoginItem())
        // Before the File Index starts and creates its database: a new
        // install's empty folder list is kept from then on.
        SourceStore.shared.rememberFolders()
        setup = Setup(
            shortcuts: ShortcutsRow(takeover: takeover),
            folders: FoldersRow(sources: .shared, isDenied: { FileIndex.shared.deniedFolders.contains($0) }),
            meaning: MeaningChoiceRow(meaning: meaning),
            paste: PasteRow(access: SystemAccessibility()),
            login: LoginRow(openAtLogin: openAtLogin),
            defaults: defaults
        )
    }

    /// Opens the window, or brings it forward with what it already shows.
    func show() {
        if window == nil {
            setup.begin()
            // Sized by its content, so a row added later grows the window.
            let content = NSHostingController(rootView: ThemeWrapper {
                SetupView(setup: self.setup, done: { [weak self] in self?.done() })
            })
            content.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: content)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.title = "Set Up Codiclens"
            window.center()
            // Closing without Done is a skip: the window goes, the choices
            // with it, and Setup comes back on the next reopen.
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.forgetWindow()
            }
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func done() {
        setup.done()
        window?.close()
    }

    private func forgetWindow() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window = nil
    }

    /// Before the app quits.
    func tearDown() {
        window?.close()
    }
}
