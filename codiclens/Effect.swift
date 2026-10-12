import AppKit
import UniformTypeIdentifiers

/// What an effect carries: the thing to put on the pasteboard, type, or share.
enum Payload: Equatable {
    case text(String)
    case image(Data)
    case fileURL(URL)
}

/// A side effect the command machine asks the world to perform.
///
/// `CommandCoordinator` decides *what* should happen and returns Effects; an
/// `EffectRunner` decides *how*. Every `NSPasteboard`, `NSWorkspace`, `CGEvent`,
/// `NSAppleScript` and `FileManager` call sits behind that seam, which is what
/// makes the phase machine reachable from a test.
///
/// Effects are ordered. `.hide` comes first when the panel must be gone before
/// the rest runs — opening an app, or pasting into whatever was frontmost.
enum Effect {
    /// Dismiss the panel.
    case hide

    // Opening
    case open(URL)
    case openWith(file: URL, application: URL)
    case revealInFinder(URL)
    case moveToTrash(URL)

    // Running applications
    case terminate(bundleIdentifier: String)
    case hideApplication(bundleIdentifier: String)

    // Pasteboard
    /// Write to the pasteboard and stop there.
    case copy(Payload)
    /// Write to the pasteboard, dismiss, hand activation back to the previous
    /// app, then synthesise Cmd+V.
    case paste(Payload)
    /// Dismiss, hand activation back, then synthesise the text keystroke by
    /// keystroke — for targets that refuse a paste.
    case typeText(String)

    /// Read the text out of the image at this URL and hand the OCR Text back.
    ///
    /// The only Effect that is *answered* rather than merely performed —
    /// `.savePanel` is the precedent — and the only one with no `.hide`
    /// anywhere near it. That is the point: the OCR Text lands *in* the Panel,
    /// so the Panel has to still be there. An OCR Effect that hides is a bug,
    /// not a variation. See
    /// `docs/adr/0007-async-action-behind-the-effect-seam.md`.
    ///
    /// A URL crosses the seam, never image bytes: loading the image in the
    /// coordinator would be file I/O on the wrong side of the line.
    case ocr(URL)

    /// Generate PNG bytes for a QR code away from the coordinator. The
    /// generation lets the coordinator reject an answer from a Panel session
    /// that has already been reset.
    case generateQRCode(String, generation: Int)

    /// Rotate the image at `URL` in place. Clipboard images pass their stored
    /// snapshot URL; file Subjects pass the original file URL.
    case rotateImage(URL, direction: ImageActions.RotationDirection, generation: Int)

    /// Move, copy, rename or compress a file or folder, answered with where
    /// the result now is. Never overwrites anything; see `FileOperation`. No
    /// `.hide` beside it, for the reason Rotate has none: the Subject retargets
    /// to the answer *in* the Panel. The generation drops an answer meant for a
    /// Panel session that has since been reset.
    case fileOperation(FileOperation, generation: Int)

    /// Transcribe the audio or video file at `URL` with Codictate's command,
    /// answered with the transcript or why there is none. No `.hide`, for the
    /// reason OCR has none: the transcript lands *in* the Panel as a text
    /// Subject. The generation drops an answer meant for a Panel session that
    /// has since been reset. See `Transcription`.
    case transcribe(URL, generation: Int)

    /// Stop the transcription under way. Its answer, a cancelled run, is
    /// dropped by its generation.
    case cancelTranscription

    /// Open a recording or a video in QuickTime Player at `seconds` and play
    /// it, by AppleScript — the moment a File Result matched at. Answered
    /// with whether QuickTime did, because the first time macOS asks the user
    /// whether Codiclens may, and they can say no; then the file opens the
    /// ordinary way. No `.hide` beside it: the Panel says "Opening at 14:02…"
    /// until the answer, and QuickTime coming forward is what dismisses it.
    case openAtMoment(URL, seconds: Double, generation: Int)

    // Everything else
    case runAppleScript(String)
    case share(Payload, via: NSSharingService)
    case openInPreview(URL)
    case quickLook(QuickLookContext)
    case showSettings
    case savePanel(data: Data, fileName: String, contentType: UTType)
}

extension Effect: Equatable {
    static func == (lhs: Effect, rhs: Effect) -> Bool {
        switch (lhs, rhs) {
        case (.hide, .hide), (.showSettings, .showSettings), (.cancelTranscription, .cancelTranscription):
            true
        case let (.open(a), .open(b)):
            a == b
        case let (.openWith(fa, aa), .openWith(fb, ab)):
            fa == fb && aa == ab
        case let (.revealInFinder(a), .revealInFinder(b)):
            a == b
        case let (.moveToTrash(a), .moveToTrash(b)):
            a == b
        case let (.terminate(a), .terminate(b)):
            a == b
        case let (.hideApplication(a), .hideApplication(b)):
            a == b
        case let (.copy(a), .copy(b)):
            a == b
        case let (.paste(a), .paste(b)):
            a == b
        case let (.typeText(a), .typeText(b)):
            a == b
        case let (.ocr(a), .ocr(b)):
            a == b
        case let (.generateQRCode(ta, ga), .generateQRCode(tb, gb)):
            ta == tb && ga == gb
        case let (.rotateImage(ua, da, ga), .rotateImage(ub, db, gb)):
            ua == ub && da == db && ga == gb
        case let (.fileOperation(oa, ga), .fileOperation(ob, gb)):
            oa == ob && ga == gb
        case let (.transcribe(ua, ga), .transcribe(ub, gb)):
            ua == ub && ga == gb
        case let (.openAtMoment(ua, sa, ga), .openAtMoment(ub, sb, gb)):
            ua == ub && sa == sb && ga == gb
        case let (.runAppleScript(a), .runAppleScript(b)):
            a == b
        case let (.share(pa, sa), .share(pb, sb)):
            pa == pb && sa === sb
        case let (.openInPreview(a), .openInPreview(b)):
            a == b
        case let (.quickLook(a), .quickLook(b)):
            a.selectedIndex == b.selectedIndex && a.items.map(\.url) == b.items.map(\.url)
        case let (.savePanel(da, na, ta), .savePanel(db, nb, tb)):
            da == db && na == nb && ta == tb
        default:
            false
        }
    }
}
