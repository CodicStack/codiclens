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

    // Everything else
    case runAppleScript(String)
    case share(Payload, via: NSSharingService)
    case quickLook(QuickLookContext)
    case showSettings
    case savePanel(data: Data, fileName: String, contentType: UTType)
}

extension Effect: Equatable {
    static func == (lhs: Effect, rhs: Effect) -> Bool {
        switch (lhs, rhs) {
        case (.hide, .hide), (.showSettings, .showSettings):
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
        case let (.runAppleScript(a), .runAppleScript(b)):
            a == b
        case let (.share(pa, sa), .share(pb, sb)):
            pa == pb && sa === sb
        case let (.quickLook(a), .quickLook(b)):
            a.selectedIndex == b.selectedIndex && a.items.map(\.url) == b.items.map(\.url)
        case let (.savePanel(da, na, ta), .savePanel(db, nb, tb)):
            da == db && na == nb && ta == tb
        default:
            false
        }
    }
}
