import AppKit
import UniformTypeIdentifiers

/// The seam. Two adapters satisfy it: `SystemEffectRunner` in the app,
/// `RecordingEffectRunner` in tests.
protocol EffectRunner: AnyObject {
    func run(_ effects: [Effect])

    /// Whether opening `url` the ordinary way would hand it to Codiclens
    /// itself. Codiclens claims broad types at rank `Alternate` for Open With,
    /// which makes it the default app for a type nothing else installed claims
    /// (`.pages` without iWork); `.open` on such a file would only send it
    /// back in as an Incoming Subject. The coordinator asks before it opens a
    /// file or folder, and shows Quick Look instead.
    func opensInCodiclens(_ url: URL) -> Bool
}

/// Performs effects against the real system.
///
/// The panel-owned steps — dismissing, handing activation back before a paste,
/// Quick Look, the save panel — are injected by `PanelController`, because they
/// need window state this module deliberately doesn't own.
final class SystemEffectRunner: EffectRunner {
    /// Serial because reset can start a new image Action while an old callback
    /// is intentionally discarded. Two rotations of one file must still reach
    /// disk in command order rather than both reading the same old pixels.
    private let imageWorkQueue = DispatchQueue(
        label: "com.codiclens.image-actions",
        qos: .userInitiated
    )

    /// Serial so two operations on one file reach disk in command order. Its
    /// own queue, not the image one: a long Compress must not hold up a Rotate.
    private let fileWorkQueue = DispatchQueue(
        label: "com.codiclens.file-operations",
        qos: .userInitiated
    )

    /// Where Copy, Paste and Copy File write. `NSPasteboard.general` in the
    /// app; a test hands in a private one, so it never touches the user's
    /// clipboard.
    private let pasteboard: NSPasteboard

    /// Where Codictate's client is, asked each time Transcribe runs, so a
    /// Codictate installed or updated while the app runs is found.
    /// `Transcription.locate` in the app, which also asks the client's
    /// `status` once whether it speaks this contract; a test hands in a
    /// script of its own.
    private let codictate: @Sendable () -> Transcription.Location

    /// The transcription under way, so the next Panel session can stop it.
    /// Main thread only.
    private var transcription: TranscriptionRun?

    /// The bundle identifier of the app that opens a URL the ordinary way.
    /// LaunchServices in the app; a test says who without asking it.
    private let defaultApplication: (URL) -> String?

    init(
        pasteboard: NSPasteboard,
        codictate: @escaping @Sendable () -> Transcription.Location = { Transcription.locate() },
        defaultApplication: @escaping (URL) -> String? = SystemEffectRunner.defaultApplication(for:)
    ) {
        self.pasteboard = pasteboard
        self.codictate = codictate
        self.defaultApplication = defaultApplication
    }

    /// Compared by bundle identifier, not by URL: a Debug build in
    /// DerivedData and a Release one in `/Applications` are both Codiclens.
    func opensInCodiclens(_ url: URL) -> Bool {
        guard url.isFileURL, let own = Bundle.main.bundleIdentifier else { return false }
        return defaultApplication(url) == own
    }

    static func defaultApplication(for url: URL) -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    var onHide: (() -> Void)?
    var onPasteAndHide: ((@escaping () -> Void) -> Void)?
    var onQuickLook: ((QuickLookContext) -> Void)?
    var onShowSettings: (() -> Void)?
    var onSavePanel: ((Data, String, UTType) -> Void)?

    /// Where the OCR Text goes.
    ///
    /// `.ocr` is *answered*, not merely performed — `.savePanel` is the
    /// precedent, and OCR is the second user, which is the point at which the
    /// shape is a pattern. The runner does the awaiting, so
    /// `CommandCoordinator` neither imports Vision nor `await`s; see
    /// `docs/adr/0007-async-action-behind-the-effect-seam.md`. Called with
    /// `nil` when the image had no readable text, so no empty text Subject is
    /// ever created.
    var onOCRText: ((String?) -> Void)?
    var onQRCode: ((Int, Data?) -> Void)?
    var onImageRotation: ((Int, Bool) -> Void)?
    /// Where a Move, Copy, Rename or Compress lands, or why it did not.
    var onFileOperation: ((Int, Result<URL, FileOperation.Failure>) -> Void)?
    /// The transcript of an audio or video file, or why there is none.
    var onTranscription: ((Int, Result<String, Transcription.Failure>) -> Void)?
    /// Where the transcription under way is: queued behind others, reading
    /// the file, transcribing. Always before its `onTranscription`.
    var onTranscriptionProgress: ((Int, Transcription.Progress) -> Void)?
    /// Whether QuickTime opened a file at its moment.
    var onMomentOpen: ((Int, Bool) -> Void)?

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

        case .openInPreview(let file):
            guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
                return
            }
            Task {
                let config = NSWorkspace.OpenConfiguration()
                _ = try? await NSWorkspace.shared.open([file], withApplicationAt: preview, configuration: config)
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
            service.perform(withItems: [SharePayloadItems.item(for: payload)])

        case .quickLook(let context):
            onQuickLook?(context)

        case .showSettings:
            onShowSettings?()

        case .savePanel(let data, let fileName, let contentType):
            onSavePanel?(data, fileName, contentType)

        case .ocr(let url):
            // The one Effect that is awaited. Nothing is hidden and nothing
            // else in the list is reordered around it: the coordinator has
            // already flagged the run as in flight, and the answer comes back
            // through the callback whenever Vision has one.
            guard let onOCRText else { return }
            Task { @MainActor in
                onOCRText(await OCR.text(in: url))
            }

        case .generateQRCode(let text, let generation):
            guard let onQRCode else { return }
            imageWorkQueue.async {
                let data = try? ImageActions.generateQRCode(for: text)
                DispatchQueue.main.async { onQRCode(generation, data) }
            }

        case .rotateImage(let url, let direction, let generation):
            guard let onImageRotation else { return }
            imageWorkQueue.async {
                let succeeded: Bool
                do {
                    try ImageActions.rotateImage(at: url, direction: direction)
                    succeeded = true
                } catch {
                    succeeded = false
                }
                DispatchQueue.main.async {
                    onImageRotation(generation, succeeded)
                }
            }

        case .fileOperation(let operation, let generation):
            guard let onFileOperation else { return }
            fileWorkQueue.async {
                let result = operation.perform()
                DispatchQueue.main.async { onFileOperation(generation, result) }
            }

        case .transcribe(let file, let generation):
            guard let onTranscription else { return }
            transcription?.cancel()
            let codictate = codictate
            let onTranscriptionProgress = onTranscriptionProgress
            let run = TranscriptionRun(file: file)
            transcription = run
            // Not a serial queue: a cancelled run still winding down must not
            // hold up the next one. Looked up off the main thread too: Launch
            // Services may have to think about it, and the first look asks the
            // client's `status`, which can start Codictate.
            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<String, Transcription.Failure> = switch codictate() {
                case .found(let command):
                    // Posted in order on the main queue, so every progress
                    // lands before the answer posted after it.
                    run.perform(with: command) { progress in
                        DispatchQueue.main.async { onTranscriptionProgress?(generation, progress) }
                    }
                case .missing: .failure(.codictateMissing)
                case .tooOld: .failure(.codictateTooOld)
                case .unavailable: .failure(.codictateUnavailable)
                }
                DispatchQueue.main.async { [weak self] in
                    if self?.transcription === run { self?.transcription = nil }
                    onTranscription(generation, result)
                }
            }

        case .cancelTranscription:
            transcription?.cancel()
            transcription = nil

        case .openAtMoment(let file, let seconds, let generation):
            guard let onMomentOpen else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let opened = QuickTime.open(file, at: seconds)
                DispatchQueue.main.async { onMomentOpen(generation, opened) }
            }
        }
    }

    // MARK: - Pasteboard

    /// A `.fileURL` goes on as the file itself, not its path: Finder and Mail
    /// paste the file. That is Copy File; Copy Path writes `.text`.
    private func write(_ payload: Payload) {
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

    /// Which URLs Codiclens itself opens. None unless a test says so.
    var codiclensOpens: (URL) -> Bool = { _ in false }

    func opensInCodiclens(_ url: URL) -> Bool {
        codiclensOpens(url)
    }

    func run(_ effects: [Effect]) {
        recorded.append(contentsOf: effects)
    }

    func clear() {
        recorded.removeAll()
    }
}
