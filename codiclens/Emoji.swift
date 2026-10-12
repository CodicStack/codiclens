import AppKit

/// A single Unicode emoji together with its CLDR name and search keywords.
///
/// The `string` is fully qualified — VS16 and all — so it can go straight onto
/// the pasteboard. Symbols are out of scope: arrows, maths and currency have no
/// CLDR keywords, so there would be nothing to search them by.
nonisolated struct Emoji: Identifiable, Hashable, Sendable {
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

/// Draws an Emoji into an `NSImage`, for the places that demand one and cannot
/// take a glyph: `Subject.icon`, and the Subject Card's icon slot.
///
/// The grid does not come through here. `EmojiGridView` draws `Text` at a fixed
/// cell size, which is both sharper and far cheaper than bitmaps for 1,914 of
/// them.
enum EmojiRenderer {
    /// Apple Color Emoji is a bitmap font. It carries strikes at these pixel
    /// sizes and resamples — visibly soft — at anything in between.
    ///
    /// **64 is here for the Subject Card's icon slot.** The table stopped at 48
    /// while `Style.cardIcon` was 64; the slot is 76 now, and `strike(nearest:)`
    /// asks for `box * 0.8` — 61pt — which rounded back down to 48 and drew a
    /// glyph about 62pt tall in a 76pt slot, visibly smaller than the app icon
    /// beside it. 64 is a strike the font actually carries, so the Card fills
    /// its slot without resampling.
    static let strikes: [CGFloat] = [20, 26, 32, 40, 48, 64]

    static func strike(nearest requested: CGFloat) -> CGFloat {
        strikes.min { abs($0 - requested) < abs($1 - requested) } ?? 32
    }

    /// An image of `string`, `box` points square.
    ///
    /// The glyph is drawn at a strike that fits the box rather than one that
    /// equals it: at point size 32 the emoji is 42pt tall, so asking for the
    /// box size back would overflow it.
    ///
    /// **Cached, keyed on the glyph and the box together.** Drawing is deferred —
    /// the handler runs when AppKit first needs pixels — but deferral only makes
    /// *construction* cheap, and this is called from a view body: the Subject
    /// Card re-rendered a fresh image on every cell move. The box has to be part
    /// of the key because the call sites disagree about it (a Card asks for
    /// `Style.cardIcon`, a row for 32), and handing one size out for the other
    /// gives a visibly wrong image.
    static func image(for string: String, box: CGFloat = 32) -> NSImage {
        if let cached = cache.image(for: string, box: box) { return cached }
        let image = render(string, box: box)
        cache.store(image, for: string, box: box)
        return image
    }

    private static let cache = GlyphCache()

    private static func render(_ string: String, box: CGFloat) -> NSImage {
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

/// A bounded store of rendered glyphs.
///
/// Keyed on the glyph *and* the box size, because two call sites ask for two
/// different sizes of the same glyph. Bounded because the dataset has 1,914
/// entries and 2,030 Skin Tone variants on top, and nothing stops a session
/// touching all of them; evicting the oldest keeps whatever the user is
/// currently moving around in.
///
/// Locked rather than main-actor-only. Every current caller is on the main
/// thread, but `Subject(emoji:)` renders an icon as part of building a model
/// value, and that is not a place where a threading assumption should hide.
private final class GlyphCache {
    private struct Key: Hashable {
        let string: String
        let box: CGFloat
    }

    private let lock = NSLock()
    private var images: [Key: NSImage] = [:]
    private var order: [Key] = []

    /// Comfortably more than the number of distinct glyphs on screen at once,
    /// small enough that the memory never matters.
    private let limit = 512

    func image(for string: String, box: CGFloat) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[Key(string: string, box: box)]
    }

    func store(_ image: NSImage, for string: String, box: CGFloat) {
        let key = Key(string: string, box: box)
        lock.lock()
        defer { lock.unlock() }
        guard images[key] == nil else { return }
        images[key] = image
        order.append(key)
        if order.count > limit {
            let evicted = order.removeFirst()
            images[evicted] = nil
        }
    }
}

// MARK: - Results
//
// There is deliberately no `ResultDisplayItem(from: Emoji)`.
//
// There was one, built for a Results Slab that was a list in every Mode, and it
// outlived its purpose: grid Mode shipped, `EmojiGridView` reads `sections`, and
// nothing rendered the list form. `EmojiSearchVM` went on building it on every
// keystroke all the same — 1,914 `UUID()`s and 1,914 `NSImage`s per keypress on
// the main thread, which is what made typing in Emoji Mode lag. The fresh UUIDs
// also re-identified every row in any `ForEach` over them, so selection
// highlighting flickered on top of the cost.
//
// If a list rendering of an Emoji is ever needed again, its id is `emoji.string`
// — never a new `UUID`.
