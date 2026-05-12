import AppKit
import Carbon.HIToolbox
import Quartz

class AppDelegate: NSObject, NSApplicationDelegate {
    var panelController: PanelController?
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestAccessibilityIfNeeded()
        panelController = PanelController()
        registerHotKey()
        print("[codiclens] launched, hotkey registered")
    }

    private func requestAccessibilityIfNeeded() {
        if !AXIsProcessTrusted() {
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

    private func registerHotKey() {
        let hotKeyID = EventHotKeyID(signature: fourCharCode("CLNS"), id: 1)

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

        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            print("[codiclens] hotkey registration failed: \(status)")
        }
    }
}

private func hotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        delegate.panelController?.toggle()
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
