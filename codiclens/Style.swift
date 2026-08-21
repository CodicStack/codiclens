import SwiftUI

/// The whole visual language, in one place.
///
/// Every radius, material, tint, rim and shadow in Codiclens is defined here.
/// No view outside this file holds one, and no view outside this file branches
/// on `colorScheme` — see `docs/adr/0002-liquid-glass-over-hand-rolled.md`.
///
/// There are exactly three tiers:
///
/// - **surface** — a Slab. Liquid Glass, its own hairline rim, its own shadow.
///   `slabSurface()`.
/// - **raised** — the focused Card. A neutral lift out of the Slab plus an
///   accent stroke. The stroke is the focus signal; the fill stays neutral,
///   because accent across a whole Card reads as a coloured box rather than as
///   a tint. `cardSurface(focused: true)`.
/// - **recessed** — an unfocused Card, and every Result row or grid cell.
///   A neutral well sunk into the Slab. `cardSurface(focused: false)` and
///   `resultSurface(selected:)`.
///
/// Only the Slab uses `.glassEffect`. Cards and Results sit *inside* a Slab, and
/// glass stacked on glass loses the backdrop it is meant to reveal, so those two
/// tiers are fills over the Slab's glass rather than glass of their own.
enum Style {

    // MARK: - Geometry

    /// A Slab — the outer glass surface, and the container everything else is
    /// concentric with.
    static let slabRadius: CGFloat = 28

    /// A Card inside the Card Slab.
    ///
    /// Genuinely concentric: a Card sits `cardInset` in from the Slab's edge, so
    /// its radius is the Slab's less that inset. Concentric corners are what
    /// make a nested rounded rectangle look nested rather than merely rounded —
    /// the two curves stay parallel instead of drifting apart at the corner.
    static let cardRadius: CGFloat = concentric(inset: cardInset)

    /// A Result row or grid cell.
    ///
    /// Deliberately *not* derived. A row lives in the middle of a list, not in
    /// the Slab's corner, so it has nothing to be concentric with; taking the
    /// concentric value would give a 46pt row a 22pt radius and turn it into a
    /// capsule.
    static let resultRadius: CGFloat = 12

    static let padding: CGFloat = 12
    static let gap: CGFloat = 12

    /// One device pixel's worth of rim at 1x, which is what a hairline means.
    static let hairline: CGFloat = 1

    static let shadowRadius: CGFloat = 24
    static let shadowOffsetY: CGFloat = 8

    /// A Card's inset from the Card Slab's edge. The Card Slab must pad by this
    /// much, or `cardRadius` is concentric with nothing.
    static let cardInset: CGFloat = 10
    /// A Result's own inset from the Slab edge, so its selection fill reads as a
    /// row inside the Slab rather than a band across it.
    static let resultInset: CGFloat = 6

    static let rowPaddingH: CGFloat = 10
    static let rowPaddingV: CGFloat = 7
    static let chipPaddingH: CGFloat = 7
    static let chipPaddingV: CGFloat = 3

    /// The radius that keeps a shape inset by `inset` concentric with the Slab.
    ///
    /// macOS 26 ships `ConcentricRectangle`, which derives this from the
    /// enclosing `containerShape` automatically. We do the arithmetic instead
    /// because `ConcentricRectangle` is a `Shape` but not an `InsettableShape`,
    /// so it has no `strokeBorder` — and every tier here draws a hairline rim.
    /// Revisit if it gains the conformance.
    static func concentric(inset: CGFloat) -> CGFloat {
        max(inset, slabRadius - inset)
    }

    // MARK: - Shapes

    static var slabShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: slabRadius, style: .continuous)
    }

    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
    }

    static var resultShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: resultRadius, style: .continuous)
    }
}

// MARK: - Palette

/// The one place light and dark diverge.
///
/// The two appearances are treated **asymmetrically on purpose**. A light Slab
/// floats over a light wallpaper, where a blur alone leaves nothing to see, so
/// light gets a stronger tint into the glass, a darker rim to cut its own edge,
/// and a lighter shadow. A dark Slab has contrast for free and leans on the
/// shadow instead, so its tint stays thin and its rim is a light catch along the
/// edge rather than a border. Symmetric values are what made the old treatment
/// wash out in light and read as a solid black box in dark.
private struct Palette {

    // Slab
    /// Tint mixed into the glass. This is the *whole* material adjustment — the
    /// old `Color.black.opacity(0.92)` overlay is gone; it was opaque, which is
    /// precisely why the app read as solid rather than as glass.
    let glassTint: Color
    let slabRim: Color
    let shadow: Color

    // Card
    let cardRim: Color
    let recessedFill: Color
    /// The focused Card's fill. Neutral, not accent-tinted: a Card is a large
    /// surface, and an accent fill across it at any legible alpha stops reading
    /// as a tint and becomes a coloured box. The accent lives in `raisedRim`
    /// instead, where it signals focus without painting the Panel.
    let raisedFill: Color
    let raisedRim: Color
    /// The Card you are typing into. The least transparent thing in the app,
    /// deliberately: 13pt body text over a wallpaper is unreadable otherwise.
    let writingFill: Color

    // Result
    let selectionFill: Color
    let selectionRim: Color

    // Chip — keyboard hints, counts, badges
    let chipFill: Color
    let chipRim: Color

    static let dark = Palette(
        glassTint: .black.opacity(0.30),
        slabRim: .white.opacity(0.14),
        shadow: .black.opacity(0.28),
        cardRim: .white.opacity(0.10),
        recessedFill: .black.opacity(0.22),
        raisedFill: .white.opacity(0.10),
        raisedRim: .accentColor.opacity(0.50),
        writingFill: .black.opacity(0.52),
        selectionFill: .accentColor.opacity(0.28),
        selectionRim: .accentColor.opacity(0.34),
        chipFill: .white.opacity(0.10),
        chipRim: .white.opacity(0.10)
    )

    static let light = Palette(
        glassTint: .white.opacity(0.55),
        slabRim: .black.opacity(0.12),
        shadow: .black.opacity(0.18),
        cardRim: .black.opacity(0.10),
        recessedFill: .black.opacity(0.05),
        raisedFill: .white.opacity(0.62),
        raisedRim: .accentColor.opacity(0.40),
        writingFill: .white.opacity(0.72),
        selectionFill: .accentColor.opacity(0.18),
        selectionRim: .accentColor.opacity(0.30),
        chipFill: .white.opacity(0.55),
        chipRim: .black.opacity(0.08)
    )

    static func of(_ scheme: ColorScheme) -> Palette {
        scheme == .dark ? .dark : .light
    }
}

// MARK: - Tier modifiers

private struct SlabSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let palette = Palette.of(scheme)
        return content
            .glassEffect(.regular.tint(palette.glassTint), in: Style.slabShape)
            .overlay {
                Style.slabShape.strokeBorder(palette.slabRim, lineWidth: Style.hairline)
            }
            .clipShape(Style.slabShape)
            .shadow(color: palette.shadow, radius: Style.shadowRadius, y: Style.shadowOffsetY)
    }
}

private struct CardSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let focused: Bool
    let writing: Bool

    func body(content: Content) -> some View {
        let palette = Palette.of(scheme)
        let fill = writing
            ? palette.writingFill
            : (focused ? palette.raisedFill : palette.recessedFill)
        let rim = focused ? palette.raisedRim : palette.cardRim
        return content
            .background { Style.cardShape.fill(fill) }
            .overlay {
                Style.cardShape.strokeBorder(rim, lineWidth: Style.hairline)
            }
            .clipShape(Style.cardShape)
    }
}

private struct ResultSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let selected: Bool

    func body(content: Content) -> some View {
        let palette = Palette.of(scheme)
        return content
            .background {
                if selected {
                    Style.resultShape
                        .fill(palette.selectionFill)
                        .overlay {
                            Style.resultShape
                                .strokeBorder(palette.selectionRim, lineWidth: Style.hairline)
                        }
                }
            }
            .clipShape(Style.resultShape)
            .contentShape(Rectangle())
    }
}

private struct ChipSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let palette = Palette.of(scheme)
        return content
            .padding(.horizontal, Style.chipPaddingH)
            .padding(.vertical, Style.chipPaddingV)
            .background(palette.chipFill, in: Capsule())
            .overlay { Capsule().strokeBorder(palette.chipRim, lineWidth: Style.hairline) }
    }
}

// MARK: - The API views use

extension View {

    /// A Slab: the outer glass surface. Own rim, own shadow, clipped to
    /// `Style.slabRadius`.
    func slabSurface() -> some View {
        modifier(SlabSurface())
    }

    /// A Card inside the Card Slab.
    ///
    /// - Parameters:
    ///   - focused: the accent-tinted selection signal — an accent fill and an
    ///     accent stroke, never a system focus ring.
    ///   - writing: the Card holds editable or long-form text, which needs a
    ///     near-solid ground to stay legible over a wallpaper.
    func cardSurface(focused: Bool, writing: Bool = false) -> some View {
        modifier(CardSurface(focused: focused, writing: writing))
    }

    /// One Result row or grid cell in the Results Slab.
    func resultSurface(selected: Bool) -> some View {
        modifier(ResultSurface(selected: selected))
    }

    /// A small capsule for text that annotates rather than names: keyboard
    /// hints, counts, section labels.
    func chipSurface() -> some View {
        modifier(ChipSurface())
    }
}
