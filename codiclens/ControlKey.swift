import Foundation

/// Which letter a Control-modified key press means.
///
/// `KeyPress.characters` under Control arrives as either the letter itself or as
/// the ASCII control character Control maps it to — Ctrl+E as `"e"` or as
/// `\u{05}` — depending on the keyboard layout and on what is handling the
/// field. Both spellings have to be accepted, and the codebase used to accept
/// whichever one someone had happened to observe: Ctrl+E was compared against
/// both, and Ctrl+H/J/K/L against only the plain letter.
enum ControlKey {

    /// - Returns: the lowercase letter, or nil if the press is not one.
    static func letter(_ characters: String) -> Character? {
        let scalars = characters.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return nil }
        // \u{01}...\u{1A} are Ctrl+A through Ctrl+Z.
        if (1...26).contains(scalar.value), let letter = UnicodeScalar(scalar.value + 96) {
            return Character(letter)
        }
        return Character(scalar).lowercased().first
    }
}
