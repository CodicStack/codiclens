import AppKit

/// A single Unicode emoji together with its CLDR name and search keywords.
///
/// The `string` is fully qualified — VS16 and all — so it can go straight onto
/// the pasteboard. Symbols are out of scope: arrows, maths and currency have no
/// CLDR keywords, so there would be nothing to search them by.
struct Emoji: Identifiable, Hashable, Sendable {
    /// The emoji itself, fully qualified.
    let string: String
    /// The CLDR short name — "flexed biceps".
    let name: String
    /// CLDR keywords, so "hot" and "lit" both find 🔥.
    let keywords: [String]
    /// Index into `EmojiIndex.groups`.
    let groupIndex: Int

    var id: String { string }

    /// The same emoji wearing a different skin tone. The variant string is
    /// always looked up, never built — see `EmojiIndex.emoji(_:in:)`.
    func wearing(_ string: String) -> Emoji {
        Emoji(string: string, name: name, keywords: keywords, groupIndex: groupIndex)
    }
}

// MARK: - Skin Tone

/// A Fitzpatrick variant of an Emoji. Users have one default; individual uses
/// can override it. Variants never appear as separate Results.
enum SkinTone: Int, CaseIterable, Identifiable, Codable, Sendable {
    case none = 0
    case light
    case mediumLight
    case medium
    case mediumDark
    case dark

    var id: Int { rawValue }

    /// The modifier scalar this tone appends. `nil` for the default, which is
    /// the absence of a modifier rather than a modifier of its own.
    var modifier: Unicode.Scalar? {
        switch self {
        case .none: nil
        case .light: "\u{1F3FB}"
        case .mediumLight: "\u{1F3FC}"
        case .medium: "\u{1F3FD}"
        case .mediumDark: "\u{1F3FE}"
        case .dark: "\u{1F3FF}"
        }
    }

    var name: String {
        switch self {
        case .none: "Default"
        case .light: "Light"
        case .mediumLight: "Medium-Light"
        case .medium: "Medium"
        case .mediumDark: "Medium-Dark"
        case .dark: "Dark"
        }
    }

    static func isModifier(_ scalar: Unicode.Scalar) -> Bool {
        (0x1F3FB...0x1F3FF).contains(scalar.value)
    }
}

// MARK: - Preferences

/// The Emoji settings that outlive a session. Currently one: the default Skin
/// Tone every Emoji is offered in until a single use overrides it.
@Observable
final class EmojiPreferences {
    static let shared = EmojiPreferences()

    private static let skinToneKey = "codiclens.emoji.defaultSkinTone"

    private let defaults: UserDefaults

    /// - Parameter defaults: where the preference lives. Tests pass their own.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.skinToneKey) as? Int
        self.defaultSkinTone = stored.flatMap(SkinTone.init(rawValue:)) ?? .none
    }

    var defaultSkinTone: SkinTone {
        didSet {
            guard defaultSkinTone != oldValue else { return }
            defaults.set(defaultSkinTone.rawValue, forKey: Self.skinToneKey)
        }
    }
}

// MARK: - Rendering

/// Draws an Emoji into an `NSImage`, for the two places that demand one and
/// cannot take a glyph: `Subject.icon` and `ResultDisplayItem`.
///
/// The grid does not come through here. `EmojiGridView` draws `Text` at a fixed
/// cell size, which is both sharper and far cheaper than bitmaps for 1,914 of
/// them.
enum EmojiRenderer {
    /// Apple Color Emoji is a bitmap font. It carries strikes at these pixel
    /// sizes and resamples — visibly soft — at anything in between.
    static let strikes: [CGFloat] = [20, 26, 32, 40, 48]

    static func strike(nearest requested: CGFloat) -> CGFloat {
        strikes.min { abs($0 - requested) < abs($1 - requested) } ?? 32
    }

    /// An image of `string`, `box` points square.
    ///
    /// The glyph is drawn at a strike that fits the box rather than one that
    /// equals it: at point size 32 the emoji is 42pt tall, so asking for the
    /// box size back would overflow it.
    ///
    /// Drawing is deferred — the handler runs when AppKit first needs pixels —
    /// so building one of these per row of a 1,914-row list costs nothing until
    /// those rows are actually on screen.
    static func image(for string: String, box: CGFloat = 32) -> NSImage {
        let pointSize = strike(nearest: box * 0.8)
        return NSImage(size: NSSize(width: box, height: box), flipped: false) { rect in
            let font = NSFont(name: "Apple Color Emoji", size: pointSize)
                ?? NSFont.systemFont(ofSize: pointSize)
            let attributed = NSAttributedString(string: string, attributes: [.font: font])
            let size = attributed.size()
            attributed.draw(at: NSPoint(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2
            ))
            return true
        }
    }
}

// MARK: - Results

extension ResultDisplayItem {
    /// The list rendering of an Emoji.
    ///
    /// This exists so the results slab has something to show while it is still
    /// a list for every Mode. `EmojiGridView` is the real path; once the slab
    /// knows about grid Mode this initialiser has no callers.
    init(from emoji: Emoji) {
        self.id = UUID()
        self.name = emoji.name
        self.icon = .nsImage(EmojiRenderer.image(for: emoji.string))
        self.subtitle = emoji.string
    }
}
