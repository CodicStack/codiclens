import AppKit
import UniformTypeIdentifiers

/// The seam. Two adapters satisfy it: `SystemEffectRunner` in the app,
/// `RecordingEffectRunner` in tests.
protocol EffectRunner: AnyObject {
    func run(_ effects: [Effect])
}

/// Performs effects against the real system.
///
/// The panel-owned steps — dismissing, handing activation back before a paste,
/// Quick Look, the save panel — are injected by `PanelController`, because they
/// need window state this module deliberately doesn't own.
final class SystemEffectRunner: EffectRunner {
    var onHide: (() -> Void)?
    var onPasteAndHide: ((@escaping () -> Void) -> Void)?
    var onQuickLook: ((QuickLookContext) -> Void)?
    var onShowSettings: (() -> Void)?
    var onSavePanel: ((Data, String, UTType) -> Void)?

    func run(_ effects: [Effect]) {
        for effect in effects {
            perform(effect)
        }
    }

    private func perform(_ effect: Effect) {
        switch effect {
        case .hide:
            onHide?()

        case .open(let url):
            open(url)

        case .openWith(let file, let application):
            Task {
                let config = NSWorkspace.OpenConfiguration()
                _ = try? await NSWorkspace.shared.open([file], withApplicationAt: application, configuration: config)
            }

        case .revealInFinder(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])

        case .moveToTrash(let url):
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)

        case .terminate(let bundleIdentifier):
            NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .first?
                .terminate()

        case .hideApplication(let bundleIdentifier):
            NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .first?
                .hide()

        case .copy(let payload):
            write(payload)

        case .paste(let payload):
            write(payload)
            onPasteAndHide?({ Self.simulatePaste() })

        case .typeText(let text):
            onPasteAndHide?({ Self.simulateTyping(text) })

        case .runAppleScript(let source):
            let script = NSAppleScript(source: source)
            var error: NSDictionary?
            script?.executeAndReturnError(&error)

        case .share(let payload, let service):
            service.perform(withItems: [Self.sharingItem(for: payload)])

        case .quickLook(let context):
            onQuickLook?(context)

        case .showSettings:
            onShowSettings?()

        case .savePanel(let data, let fileName, let contentType):
            onSavePanel?(data, fileName, contentType)
        }
    }

    // MARK: - Pasteboard

    private func write(_ payload: Payload) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch payload {
        case .text(let text):
            pasteboard.setString(text, forType: .string)
        case .image(let data):
            pasteboard.setData(data, forType: .png)
        case .fileURL(let url):
            pasteboard.writeObjects([url as NSURL])
        }
    }

    private static func sharingItem(for payload: Payload) -> Any {
        switch payload {
        case .text(let text): text as NSString
        case .image(let data): NSImage(data: data) ?? NSImage()
        case .fileURL(let url): url
        }
    }

    // MARK: - Opening

    /// `NSWorkspace.open` blocks the main thread, so it always goes through a Task.
    private func open(_ url: URL) {
        Task {
            let config = NSWorkspace.OpenConfiguration()
            _ = try? await NSWorkspace.shared.open(url, configuration: config)
        }
    }

    // MARK: - Input simulation

    static func simulatePaste() {
        requestAccessibilityIfNeeded()

        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            print("[codiclens] CGEvent creation failed, using AppleScript fallback")
            simulatePasteFallback()
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }

    /// Asks for Accessibility, and only at the moment something needs it.
    ///
    /// Deliberately not done at launch: an app that prompts on every cold start
    /// trains the user to dismiss the dialog, and a build under test launches
    /// dozens of times. Synthesising a keystroke is the one operation that
    /// actually requires the grant, so this is where the question belongs.
    private static func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        print("[codiclens] accessibility not granted — paste simulation needs it")
    }

    private static func simulatePasteFallback() {
        let script = NSAppleScript(source: """
            tell application "System Events"
                keystroke "v" using command down
            end tell
        """)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            print("[codiclens] AppleScript paste fallback failed: \(error)")
        }
    }

    /// How long to leave between synthesised keystrokes.
    ///
    /// **A device constraint, not a bug fix.** `CGEvent.post` hands a keystroke
    /// to the window server, which delivers it to whatever is frontmost; the
    /// receiving app then has to run its own event loop and its text input
    /// system to turn it into a character. There is no acknowledgement to wait
    /// on and no API that reports delivery, so an unpaced burst of events
    /// arrives faster than the far side consumes it and characters go missing —
    /// reliably, in Electron apps and in terminals. This is the input device
    /// being emulated having a plausible key rate, which is why it stays.
    private static let keystrokeInterval: useconds_t = 10_000

    private static func simulateTyping(_ text: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let source = CGEventSource(stateID: .combinedSessionState)
            for char in text {
                var utf16 = Array(String(char).utf16)
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { continue }
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                event.post(tap: .cgSessionEventTap)
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                up?.post(tap: .cgSessionEventTap)
                // A device constraint — see `keystrokeInterval`. Off the main
                // thread, and not standing in for a fix.
                usleep(keystrokeInterval)
            }
        }
    }
}

/// Records effects instead of performing them. The test adapter.
final class RecordingEffectRunner: EffectRunner {
    private(set) var recorded: [Effect] = []

    func run(_ effects: [Effect]) {
        recorded.append(contentsOf: effects)
    }

    func clear() {
        recorded.removeAll()
    }
}
