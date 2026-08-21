import AppKit
import Carbon.HIToolbox
import Quartz

/// Carbon hotkey identifiers. One event handler serves both hotkeys, so it has
/// to be able to tell them apart.
private enum HotKeyID {
    static let signature = fourCharCode("CLNS")
    static let panel: UInt32 = 1
    static let emoji: UInt32 = 2
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var panelController: PanelController?

    /// Ctrl+Cmd+Space and everything it has to negotiate with macOS.
    /// `SettingsView` drives this.
    let emojiHotKey = EmojiHotKeyController()

    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestAccessibilityIfNeeded()
        panelController = PanelController()
        installHotKeyHandler()
        registerPanelHotKey()
        emojiHotKey.applyAtLaunch()
        print("[codiclens] launched, hotkeys registered (emoji: \(emojiHotKey.status))")
    }

    private func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            print("[codiclens] accessibility not granted — paste simulation requires it")
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
            nil
        )
    }

    private func registerPanelHotKey() {
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey),
            EventHotKeyID(signature: HotKeyID.signature, id: HotKeyID.panel),
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            print("[codiclens] hotkey registration failed: \(status)")
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

    /// Opens the panel straight into Emoji Mode: Emoji selected, grid open,
    /// Recents on top, empty Query.
    private func showEmojiPanel() {
        guard let panelController else { return }
        // Dismiss first so `showPanel`'s one-time setup never runs twice over an
        // already-open panel. It is a no-op when nothing is showing.
        panelController.hidePanel()
        panelController.coordinator.requestEmojiMode()
        panelController.showPanel()
    }
}

// MARK: - Symbolic hotkeys

/// The two private CoreGraphics calls that read and write macOS's own
/// keyboard shortcuts, resolved at runtime.
///
/// **This is private API.** `CGSIsSymbolicHotKeyEnabled` and
/// `CGSSetSymbolicHotKeyEnabled` are unexported CoreGraphics SPI, which is why
/// they are looked up with `dlsym` rather than linked. Symbolic hotkey 50 is
/// `ShowHideCharacterPalette` — the system's Ctrl+Cmd+Space — confirmed against
/// the live OS via `SLSSymbolicHotKeyName` and against the CGSInternal header's
/// `kCGSHotKeyToggleCharacterPallette`. Using it is a Mac App Store rejection
/// risk and acceptable for direct distribution. The decision is recorded in
/// `docs/adr/0006-private-symbolic-hotkey-api.md`.
///
/// Every entry point returns an optional so a future OS that drops these
/// symbols degrades to "the hotkey is not available" instead of trapping.
enum SymbolicHotKey {
    /// `kCGSHotKeyToggleCharacterPallette` — Show/Hide Emoji & Symbols.
    static let showHideCharacterPalette: Int32 = 50

    private typealias IsEnabledFunction = @convention(c) (Int32) -> DarwinBoolean
    /// The flag is taken as `Int32` rather than `Bool`: the real parameter has
    /// been spelled both `bool` and `boolean_t` across headers, and a
    /// zero-extended word is correct for either.
    private typealias SetEnabledFunction = @convention(c) (Int32, Int32) -> Int32

    private static let isEnabledFunction: IsEnabledFunction? = symbol("CGSIsSymbolicHotKeyEnabled")
    private static let setEnabledFunction: SetEnabledFunction? = symbol("CGSSetSymbolicHotKeyEnabled")

    private static func symbol<T>(_ name: String) -> T? {
        // RTLD_DEFAULT: search every image already loaded, CoreGraphics included.
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// Whether both symbols resolved. False means this OS no longer exposes
    /// them and the takeover cannot work at all.
    static var isAvailable: Bool {
        isEnabledFunction != nil && setEnabledFunction != nil
    }

    /// Whether macOS currently holds this shortcut. `nil` when unavailable.
    static func isEnabled(_ id: Int32) -> Bool? {
        isEnabledFunction.map { $0(id).boolValue }
    }

    /// - Returns: the `CGError` the call reported, or `nil` when unavailable.
    @discardableResult
    static func setEnabled(_ id: Int32, _ enabled: Bool) -> CGError? {
        setEnabledFunction.map { CGError(rawValue: $0(id, enabled ? 1 : 0)) ?? .failure }
    }
}

// MARK: - Emoji hotkey

/// Owns Ctrl+Cmd+Space: the preference, the negotiation with macOS over who
/// gets the keystroke, and the Carbon registration itself.
///
/// macOS binds Ctrl+Cmd+Space to Emoji & Symbols and there is no row for it in
/// System Settings, so a user cannot hand it over by hand. `RegisterEventHotKey`
/// is no help either — it returns `noErr` while WindowServer quietly eats the
/// keystroke first. Taking the shortcut therefore means turning the system's
/// own off, and giving it back means turning it on again.
@Observable
final class EmojiHotKeyController {
    /// Where the app stands with Ctrl+Cmd+Space.
    enum Status: Equatable {
        /// The preference is off. macOS still owns the shortcut.
        case systemOwns
        /// Codiclens owns it: the system shortcut is off, ours is registered.
        case codiclensOwns
        /// The preference is on but the system shortcut is still live, so
        /// WindowServer will keep swallowing the keystroke.
        case blockedBySystemShortcut
        /// The private symbols did not resolve. Nothing can be done here.
        case unavailable
    }

    static let preferenceKey = "codiclens.emoji.ownsEmojiHotKey"

    private let defaults: UserDefaults
    private var hotKeyRef: EventHotKeyRef?

    private(set) var status: Status = .systemOwns

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Default off. Taking a system shortcut over on first launch, without
        // being asked, is not ours to do.
        self.isEnabled = defaults.bool(forKey: Self.preferenceKey)
    }

    /// Whether Codiclens should own Ctrl+Cmd+Space. Setting it performs the
    /// takeover or the hand-back there and then.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.preferenceKey)
            if isEnabled { takeOver() } else { handBack() }
        }
    }

    /// Whether this OS still exposes the calls the takeover needs.
    var isSupported: Bool { SymbolicHotKey.isAvailable }

    /// Whether macOS currently holds Ctrl+Cmd+Space for Emoji & Symbols.
    /// `nil` when the private symbols are unavailable.
    var isSystemShortcutEnabled: Bool? {
        SymbolicHotKey.isEnabled(SymbolicHotKey.showHideCharacterPalette)
    }

    /// Re-asserts the takeover at every launch when the preference is on.
    ///
    /// Assert, don't assume: an OS update, a settings migration or another app
    /// can put the system shortcut back, and then our hotkey silently stops
    /// firing. With the preference off this deliberately touches nothing — the
    /// user may have disabled the system shortcut themselves, and switching it
    /// back on is not ours to do either.
    func applyAtLaunch() {
        guard isEnabled else {
            status = SymbolicHotKey.isAvailable ? .systemOwns : .unavailable
            return
        }
        takeOver()
    }

    /// Disables the system shortcut, then registers ours.
    private func takeOver() {
        guard SymbolicHotKey.isAvailable else {
            unregister()
            status = .unavailable
            return
        }

        let error = SymbolicHotKey.setEnabled(SymbolicHotKey.showHideCharacterPalette, false)
        let systemStillHasIt = isSystemShortcutEnabled ?? true
        register()

        status = (error == .success && !systemStillHasIt) ? .codiclensOwns : .blockedBySystemShortcut
    }

    /// Gives macOS its shortcut back and drops ours.
    ///
    /// A first-class path, not an afterthought: a user who turns this off — or
    /// who is about to uninstall — must end up with a working system emoji
    /// picker again.
    func handBack() {
        unregister()
        guard SymbolicHotKey.isAvailable else {
            status = .unavailable
            return
        }
        SymbolicHotKey.setEnabled(SymbolicHotKey.showHideCharacterPalette, true)
        status = .systemOwns
    }

    private func register() {
        guard hotKeyRef == nil else { return }
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | cmdKey),
            EventHotKeyID(signature: HotKeyID.signature, id: HotKeyID.emoji),
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            print("[codiclens] emoji hotkey registration failed: \(status)")
            hotKeyRef = nil
        }
    }

    private func unregister() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
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
