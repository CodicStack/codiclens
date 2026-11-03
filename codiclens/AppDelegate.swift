import AppKit
import Carbon.HIToolbox
import Quartz

/// Carbon hotkey identifiers. One event handler serves every hotkey, so it has
/// to be able to tell them apart.
private enum HotKeyID {
    static let signature = fourCharCode("CLNS")
    static let panel: UInt32 = 1
    static let emoji: UInt32 = 2
}

/// The keystrokes that summon Codiclens.
///
/// macOS ships holding both, for Spotlight and Emoji & Symbols, and while it
/// does WindowServer eats the keystroke before it reaches us. They are
/// registered plainly either way; `ShortcutTakeover` makes macOS let go when
/// the user chose that in Setup or Settings
/// (`docs/adr/0016-codiclens-takes-both-system-shortcuts.md`).
private enum HotKey {
    static let panel = (key: UInt32(kVK_Space), modifiers: UInt32(cmdKey))
    static let emoji = (key: UInt32(kVK_Space), modifiers: UInt32(controlKey | cmdKey))
}

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Whether this process is the unit-test host. XCTest names its
    /// configuration file in the environment of the app it injects the test
    /// bundle into, Swift Testing's runs included.
    ///
    /// The test host is the app itself, so a launch that started anything
    /// would crawl the user's folders into their own File Index, record their
    /// clipboard, scan `/Applications` and take Cmd+Space from the copy of
    /// the app they are running. It starts nothing: tests build what they
    /// need, over their own folders and stores.
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var panelController: PanelController?

    /// Setup, and the shortcut takeover and login item it shares with
    /// Settings.
    private var setupController: SetupController?

    /// Sparkle, behind the `Updater` seam. Made after Move to Applications,
    /// so a copy about to be replaced never checks.
    private var updater: SparkleUpdater?

    /// The launch offered Move to Applications and the copy is opening in
    /// this one's place: nothing was started, so nothing is torn down.
    private var isMovingToApplications = false

    /// Clipboard History's recorder. Owned here rather than by the `App` value
    /// so that starting it and stopping it sit on the same object.
    private var pasteboardWatcher: PasteboardWatcher?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandlerRef: EventHandlerRef?

    /// The app an Incoming Subject came from. See `LastActiveApp`.
    private let lastActiveApp = LastActiveApp()
    private let incomingService = IncomingService()

    /// An Incoming Subject that arrived before the Panel existed.
    ///
    /// A cold launch from Open With delivers `application(_:open:)` before
    /// `applicationDidFinishLaunching`, so the URLs wait here and are handed
    /// over once the Panel is made. Only the latest is kept, as it would win
    /// over an earlier one in a Panel already up.
    private var pendingIncoming: Incoming?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !EmbeddingService.isRequested(), !Self.isTestHost else { return }
        lastActiveApp.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Relaunched as the embedding helper: no Panel, no hotkeys, no File
        // Index, no clipboard recorder, only the request loop.
        if EmbeddingService.isRequested() { return EmbeddingService.start() }
        guard !Self.isTestHost else { return }
        // Before anything starts: a copy about to be replaced by the one in
        // /Applications must not crawl, record or take shortcuts.
        if MoveToApplications.offerIfNeeded() {
            isMovingToApplications = true
            return
        }
        // Before anything reads the Sources and before the File Index
        // creates its database.
        SourcesMigration.migrate()
        let setupController = SetupController(meaning: FileIndex.shared.meaning)
        self.setupController = setupController
        // Whatever an OS update, a restart or a crash left behind: the
        // shortcuts the user gave Codiclens are taken again.
        setupController.takeover.takeAtLaunch()
        let updater = SparkleUpdater()
        self.updater = updater
        panelController = PanelController(lastActiveApp: lastActiveApp, setupController: setupController, updater: updater)
        // Off-thread, so neither launch nor the first Emoji Mode waits on the
        // 226 KB dataset being decoded.
        EmojiIndex.prewarm()
        // Opens the File Index and crawls the folder Sources, off the main
        // thread; File Results are whatever has been read so far.
        FileIndex.shared.start()
        pasteboardWatcher = PasteboardWatcher(history: .shared)
        pasteboardWatcher?.start()
        installHotKeyHandler()
        register(HotKey.panel, as: HotKeyID.panel)
        register(HotKey.emoji, as: HotKeyID.emoji)

        // "Open in Codiclens". Service requests that launched the app are
        // delivered once this is set, after the Panel exists. The update makes
        // a fresh install's Service show up without logging out.
        incomingService.onIncoming = { [weak self] incoming in
            self?.receive(incoming)
        }
        NSApp.servicesProvider = incomingService
        NSUpdateDynamicServices()

        if let pendingIncoming {
            self.pendingIncoming = nil
            receive(pendingIncoming)
        }

        setupController.showAtLaunch()
    }

    /// Opening the app while it runs, from Finder, Launchpad or Spotlight.
    /// It always opens the Panel, which is the way in for a user who kept
    /// ⌘Space for Spotlight; Setup opens under it until Done has been pressed
    /// once.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !Self.isTestHost, !EmbeddingService.isRequested(), let setupController else { return false }
        // Setup first: the Panel hides when it stops being key, so it has to
        // be the last window to take the keyboard.
        setupController.showOnReopen()
        panelController?.showPanel()
        return false
    }

    /// Back to the front, from System Settings perhaps: a folder macOS
    /// refused may be allowed now.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !Self.isTestHost, !EmbeddingService.isRequested(), setupController != nil else { return }
        FileIndex.shared.recheckAccess()
    }

    /// Everything the app holds outside its own memory, released in one place.
    ///
    /// A background accessory app has no window to close and no document to
    /// save, so nothing else prompts this teardown: without it the Carbon
    /// handler, the hotkeys, both FSEvents streams and the pasteboard timer all
    /// outlive the decision to quit.
    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isTestHost, !EmbeddingService.isRequested(), !isMovingToApplications else { return }
        // Spotlight and Emoji & Symbols go back to macOS whenever Codiclens
        // is not running to answer them.
        setupController?.takeover.handBack()
        setupController?.tearDown()
        unregisterHotKeys()
        lastActiveApp.stop()
        pasteboardWatcher?.stop()
        panelController?.tearDown()
        panelController = nil
        AppIndex.shared.stop()
        FileIndex.shared.stop()
    }

    // MARK: - Incoming Subjects

    /// Finder's Open With ▸ Codiclens, for one file or several, and `open -a`.
    ///
    /// SwiftUI's app delegate hands this to the adaptor; with only a `Settings`
    /// scene there is no window for it to open instead.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !Self.isTestHost, !EmbeddingService.isRequested() else { return }
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }
        receive(.urls(fileURLs))
    }

    private func receive(_ incoming: Incoming) {
        guard let panelController else {
            pendingIncoming = incoming
            return
        }
        switch incoming {
        case .urls(let urls): panelController.showIncoming(urls: urls)
        case .text(let text): panelController.showIncoming(text: text)
        }
    }

    // MARK: - QuickLook Responder Chain

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        panelController?.quickLookActive ?? false
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panelController?.configurePreviewPanel(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panelController?.unconfigurePreviewPanel(panel)
    }

    // MARK: - Hotkeys

    /// One handler for every hotkey the app registers, installed once.
    private func installHotKeyHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandlerRef
        )
    }

    private func register(_ hotKey: (key: UInt32, modifiers: UInt32), as id: UInt32) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.key,
            hotKey.modifiers,
            EventHotKeyID(signature: HotKeyID.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            print("[codiclens] hotkey \(id) registration failed: \(status)")
            return
        }
        hotKeyRefs.append(ref)
    }

    private func unregisterHotKeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs = []

        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
    }

    fileprivate func handleHotKey(_ id: UInt32) {
        switch id {
        case HotKeyID.panel:
            panelController?.toggle()
        case HotKeyID.emoji:
            showEmojiPanel()
        default:
            break
        }
    }

    /// Opens the Panel straight into Emoji Mode: Emoji selected, grid open,
    /// Recents on top, empty Query.
    private func showEmojiPanel() {
        guard let panelController else { return }
        // Dismiss first so `showPanel`'s one-time setup never runs twice over an
        // already-open Panel. It is a no-op when nothing is showing.
        panelController.hidePanel()
        panelController.coordinator.requestEmojiMode()
        panelController.showPanel()
    }
}

// MARK: - Carbon plumbing

private func hotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return OSStatus(eventNotHandledErr) }

    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        delegate.handleHotKey(hotKeyID.id)
    }
    return noErr
}

private func fourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for char in string.utf8.prefix(4) {
        result = (result << 8) + FourCharCode(char)
    }
    return result
}
