import ApplicationServices

/// The Accessibility grant Paste needs to send ⌘V. A fake in tests: nothing
/// under test opens the prompt.
protocol AccessibilityAccess {
    var isGranted: Bool { get }
    /// macOS's own prompt, which offers to open Privacy & Security.
    func prompt()
}

struct SystemAccessibility: AccessibilityAccess {
    var isGranted: Bool { AXIsProcessTrusted() }

    func prompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
