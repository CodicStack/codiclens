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
/// Ctrl+Cmd+Space is macOS's own Emoji & Symbols shortcut out of the box. We
/// register ours plainly and let the user decide: while the system shortcut is
/// on, WindowServer eats the keystroke before it reaches us, and turning it off
/// (System Settings → Keyboard → Keyboard Shortcuts) hands it over. We do not
/// reach into the system's shortcut table to take it — see
/// `docs/adr/0006-private-symbolic-hotkey-api.md`.
private enum HotKey {
    static let panel = (key: UInt32(kVK_Space), modifiers: UInt32(cmdKey))
    static let emoji = (key: UInt32(kVK_Space), modifiers: UInt32(controlKey | cmdKey))
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var panelController: PanelController?

    /// Clipboard History's recorder. Owned here rather than by the `App` value
    /// so that starting it and stopping it sit on the same object.
    private let pasteboardWatcher = PasteboardWatcher(history: .shared)

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandlerRef: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = PanelController()
        pasteboardWatcher.start()
        installHotKeyHandler()
        register(HotKey.panel, as: HotKeyID.panel)
        register(HotKey.emoji, as: HotKeyID.emoji)
    }

    /// Everything the app holds outside its own memory, released in one place.
    ///
    /// A background accessory app has no window to close and no document to
    /// save, so nothing else prompts this teardown: without it the Carbon
    /// handler, the hotkeys, the FSEvents stream and the pasteboard timer all
    /// outlive the decision to quit.
    func applicationWillTerminate(_ notification: Notification) {
        unregisterHotKeys()
        pasteboardWatcher.stop()
        panelController?.tearDown()
        panelController = nil
        AppIndex.shared.stop()
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
