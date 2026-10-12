import SwiftUI

/// The whole visual language, in one place.
///
/// Every radius, material, tint and shadow in Codiclens is defined here. No view
/// outside this file holds one, and no view outside this file branches on
/// `colorScheme` — see `docs/adr/0002-liquid-glass-over-hand-rolled.md`.
///
/// There are exactly three tiers:
///
/// - **surface** — a Slab: Liquid Glass, one shared tint, its own shadow.
///   `slabSurface()`.
/// - **raised** — the focused Card: the same glass at full size, with its
///   content at full strength. `cardSurface(focused: true)`.
/// - **recessed** — an unfocused Card, and every Result row or grid cell. The
///   identical glass, laid out `Style.unfocusedCardShrink` smaller on every
///   side with its content at `unfocusedContentOpacity`; a Result is a flat
///   well in the Slab. `cardSurface(focused: false)` and
///   `resultSurface(selected:)`.
///
/// **A Card is bare native glass with nothing painted on it, and no colour of
/// its own.** The specular wash, the inner shadow, the rim hairline, the static
/// rim light and the travelling one are all deleted, and so is the accent tint
/// that briefly replaced them — every one of those was an attempt to say "this
/// Card holds the keyboard" in the *material*, and the answer is that the
/// material is the same everywhere and the focused Card is simply the one that
/// has not stepped back. The glass already supplies an edge highlight and an
/// adaptive shadow, so a Card adds neither — and it is deliberately **not
/// clipped**, because clipping glass cuts its own shadow off and leaves a grey
/// halo where the falloff was.
///
/// Slabs and Cards both use `.glassEffect`, because both are top-level surfaces
/// floating over the desktop. Results are the one flat tier: they sit *inside*
/// the Results Slab, and glass stacked on glass loses the backdrop it exists to
/// reveal.
///
/// **The Slab draws its own shadow and the window draws none.** A `.shadow()` on
/// a view that fills its window is clipped by the window bounds and renders as a
/// hard band down two edges rather than a falloff, which is why
/// `PanelLayout.margin` exists. `FloatingPanel.hasShadow` stays `false`
/// regardless — AppKit deriving a window shadow from transparent glass traces a
/// ragged contour.
enum Style {

    // MARK: - Geometry

    /// The Results Slab. Lower than a Card on purpose: it is the larger, calmer
    /// surface, and matching the Cards' curvature made it look inflated.
    static let slabRadius: CGFloat = 18

    /// A Card. Cards are their own top-level surfaces — there is no Card Slab
    /// behind them — so this is chosen for the Card's own proportions rather
    /// than derived from a container.
    static let cardRadius: CGFloat = 20

    /// A Result row or grid cell.
    static let resultRadius: CGFloat = 10

    static let padding: CGFloat = 12
    static let gap: CGFloat = 12

    /// One device pixel's worth of rim at 1x, which is what a hairline means.
    static let hairline: CGFloat = 1

    /// Half the gap between two Cards, because it is a padding *outside* each
    /// Card's drawn surface: two adjacent Cards contribute one each, so the
    /// visible gutter is twice this.
    ///
    /// Small, because the only thing in the gutter now is the glass's own
    /// shadow. It was 24 while a glow blurred outward from every rim and needed
    /// room to fall off in without reaching the neighbouring Card.
    static let cardInset: CGFloat = 6

    /// A Result's own inset from the Slab edge, so its selection fill reads as a
    /// row inside the Slab rather than a band across it.
    static let resultInset: CGFloat = 6

    /// How close two pieces of glass have to be before the container fuses them
    /// into one body.
    ///
    /// **Well under `cardInset * 2`, and that is the whole point.** The Cards
    /// share one `GlassEffectContainer` so that a new one can grow out of its
    /// neighbour, and the same container would happily weld them together if it
    /// were allowed to. Cards are separate objects; keep this below the gutter.
    static let glassMergeDistance: CGFloat = 4

    /// The icon in a Card. The Card is the thing the user is looking at, so the
    /// icon carries it; the label underneath names it.
    static let cardIcon: CGFloat = 76

    /// A Card's drawn glass at full size: its cell less `cardInset` on each
    /// side, 200pt. Square, because the cell is.
    ///
    /// What a Card's **picture** is asked for at — one size, the focused one,
    /// whatever the Emphasis. The thumbnail cache keys on size, so asking for
    /// the 180pt an unfocused Card is drawn at would miss it every time focus
    /// moved and flash the icon back; the picture is scaled down instead.
    static var cardSide: CGFloat { PanelLayout.cardWidth - 2 * cardInset }

    static let rowPaddingH: CGFloat = 10
    static let rowPaddingV: CGFloat = 7
    static let chipPaddingH: CGFloat = 7
    static let chipPaddingV: CGFloat = 3

    // MARK: - The focus signal

    /// The Emphasis size step: how many points an **unfocused** Card gives up
    /// on every side, glass and all. A Card's drawn surface is 200pt, so an
    /// unfocused one is drawn at 180.
    ///
    /// **An inset, not a scale, and that distinction is the bug it fixes.**
    /// This used to be a `.scaleEffect(0.90, anchor: .center)`, and the Card
    /// came apart on screen: `GlassEffectContainer` draws its glass from the
    /// children's *layout frames* and never sees a transform's anchor, so the
    /// glass shrank from its frame's top-left while the content it wrapped
    /// scaled about the centre — the icon and label sat about 10pt right and
    /// 12pt below the middle of the glass. Shrinking the Card in layout instead
    /// keeps them concentric for free: the glass fills the inset frame and the
    /// content is centred inside the glass. Never reach for a transform here.
    ///
    /// One constant so the signal can be turned up or down in one place. It must
    /// stay small: at 10pt of 200 the row still reads as three Cards of one
    /// kind, and much beyond that the unfocused ones read as a different,
    /// smaller component.
    static let unfocusedCardShrink: CGFloat = 10

    /// How present an unfocused Card's content — its icon, its label, its chips
    /// — is. The glass itself is untouched, so what recedes is what the Card is
    /// *about*, which is the thing the keyboard is not currently on.
    static let unfocusedContentOpacity: Double = 0.6

    // MARK: - Material

    /// The glass every Card is drawn in, in one place so it can be flipped in
    /// one edit.
    ///
    /// **`.clear`, tried 2026-09-11 and rejected.** It lenses beautifully over a
    /// wallpaper but has no frost, so a dark-appearance Card over a white backdrop
    /// is a white square with invisible white content — a 15% grey tint, a content
    /// halo, a larger radius and `.interactive()` were all captured and none
    /// differed at rest. `.regular` is the only variant legible in every backdrop ×
    /// appearance; `.regular.interactive()` is pixel-identical at rest (RMSE 0), a
    /// pointer-hover effect for controls, which a keyboard-driven Card is not.
    /// There is no "thickness" dial; lensing scales with shape size.
    static let cardGlass: Glass = .regular

    // MARK: - A Card's picture

    /// The ground under a picture's caption: clear at the top, darkening to the
    /// bottom edge. A **content-layer** gradient over the picture, never a tint
    /// on the glass, and the same in both appearances — it sits on a
    /// photograph, not on the material, so it has nothing to adapt to.
    static let pictureScrim = LinearGradient(
        colors: [.black.opacity(0), .black.opacity(0.55)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// How far up the picture the scrim reaches: the caption's line and its
    /// padding, and enough above it for the darkening to read as a falloff.
    static let pictureScrimHeight: CGFloat = 76

    /// The caption over a picture. Fixed, because the scrim under it is.
    static let pictureCaption: Color = .white

    // MARK: - A Passage

    /// The scrim under a caption that carries a Passage's lines over the name:
    /// three lines of excerpt more than `pictureScrimHeight`.
    static let passageScrimHeight: CGFloat = 124

    /// The icon over a name and a Passage, on a Card with no picture: smaller
    /// than `cardIcon`, so three lines of excerpt fit under the name.
    static let passageIcon: CGFloat = 48

    /// The words a Passage matched, in the Panel's own preview of the file:
    /// the system's find highlight, as Preview and Xcode mark found text,
    /// under the app's underline. Content inside a document, not a surface —
    /// no glass and no Card carries it.
    static let passageHighlight: NSColor = .findHighlightColor

    /// The preview's document, inset from the Slab's glass on three sides
    /// under its header.
    static let previewInset: CGFloat = 6

    /// The document's corner: concentric with the Slab's, `previewInset` in.
    static var previewDocumentRadius: CGFloat { slabRadius - previewInset }

    // MARK: - Loading Ring

    /// The Loading Ring's box. A `.small` `ProgressView` — the system spinner
    /// this replaced — occupies about 14pt, so nothing sized to fit that moves.
    static let ringDiameter: CGFloat = 13

    static let ringStroke: CGFloat = 1.5

    /// How much of the circle is lit: 270°, and a **constant** length. A ring
    /// that fills once and waits would be a progress claim, and neither Vision
    /// nor `mdfind` reports progress for it to be a measure of.
    static let ringArcFraction: CGFloat = 0.75

    // MARK: - Shadow

    /// How far a Slab's shadow reaches, and how far it hangs below it. Both are
    /// bounded by `PanelLayout.margin`: the shadow needs to have fallen off to
    /// nothing before it reaches the window edge, or it is clipped into a hard
    /// band instead.
    static let shadowRadius: CGFloat = 16
    static let shadowY: CGFloat = 5

    // MARK: - Shapes

    static var slabShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: slabRadius, style: .continuous)
    }

    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
    }

    /// A Card's picture, which fills the Card edge to edge.
    ///
    /// **`cardRadius`, and that is the concentric radius, not a coincidence.**
    /// The picture is the Card's content, laid out in the same frame
    /// `.glassEffect(in: cardShape)` draws its glass in, so it sits at an inset
    /// of 0 from the glass and a concentric corner is `cardRadius - 0`. The
    /// unfocused Card's `unfocusedCardShrink` is padding *outside* the glass,
    /// so it moves both outlines together — a 180pt glass with a 180pt picture,
    /// both at 20. Clip the **picture** with this; the glass is never clipped.
    static var pictureShape: RoundedRectangle { cardShape }

    static var resultShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: resultRadius, style: .continuous)
    }
}

// MARK: - Palette

/// The one place light and dark diverge.
///
/// The two appearances are treated **asymmetrically on purpose**. A light
/// surface floats over a light wallpaper, where a blur alone leaves nothing to
/// see, so light gets a stronger tint into the glass. A dark surface has
/// contrast for free and leans on its shadow instead, so its tint stays thin.
///
/// **There is no accent colour here, and none anywhere else either.** Focus is
/// a Card's size and the presence of its content, not a colour; selection is a
/// neutral lift. Everything in this table is monochrome.
private struct Palette {

    /// The one colour a glass surface is tinted with.
    ///
    /// White in light, black in dark — and **nothing mixes the two**. An earlier
    /// version tinted a Slab with black 0.16 while tinting a Card with white
    /// 0.09, in the same appearance. Those are not two weights of one material,
    /// they are two different materials.
    let tint: Color

    /// The weight the Slab's tint carries.
    ///
    /// Low: `.regular` glass supplies the blur, and the tint only has to keep
    /// the Slab's own text legible over a wallpaper. It was 0.58 under clear
    /// glass and read as opaque rather than as glass.
    let base: Double

    /// The ground behind a Card's body text, drawn on the glass and under the
    /// text.
    ///
    /// Its polarity follows `tint` for the same reason: more of it means more
    /// contrast against the body text in both appearances. A Card holding a page
    /// of OCR Text or a clipboard entry is the one thing on screen that needs a
    /// near-solid ground; a Card naming an app does not, and does not get one.
    let writingGround: Color

    /// The selected Result. A neutral lift, strong enough to find at a glance
    /// and quiet enough to sit under a row of app icons.
    let selectionFill: Color

    /// Chip — keyboard hints, counts, badges.
    let chipFill: Color
    let chipRim: Color

    /// What a Slab casts onto whatever is behind it.
    ///
    /// Black in both appearances — a shadow is an absence of light, so unlike
    /// `tint` it does not flip polarity. Only the weight differs, and it is
    /// heavier in dark: the falloff has to be visible against a dark desktop
    /// without turning into a halo on a light one.
    let shadow: Color

    var surfaceTint: Color { tint.opacity(base) }

    static let dark = Palette(
        tint: .black,
        base: 0.26,
        writingGround: .black.opacity(0.22),
        selectionFill: .white.opacity(0.13),
        chipFill: .white.opacity(0.09),
        chipRim: .white.opacity(0.10),
        shadow: .black.opacity(0.44)
    )

    static let light = Palette(
        tint: .white,
        base: 0.15,
        writingGround: .white.opacity(0.45),
        selectionFill: .black.opacity(0.07),
        chipFill: .white.opacity(0.62),
        chipRim: .black.opacity(0.07),
        shadow: .black.opacity(0.20)
    )

    static func of(_ scheme: ColorScheme) -> Palette {
        scheme == .dark ? .dark : .light
    }
}

// MARK: - Tier modifiers

/// Which Card in the row a piece of glass is.
///
/// The identity the material keeps across an **Arrival**: the Action Card grows
/// out of the Subject Card's glass and the Target Card out of the Action Card's,
/// which the glass container can only do if it can tell one from another between
/// two frames.
/// `nonisolated`, because `glassEffectID` wants a `Sendable` identity and this
/// file compiles main-actor-isolated by default.
nonisolated enum CardPhase: Hashable, Sendable {
    case subject
    case action
    case target
}

/// The Slab's glass, at one shared tint.
///
/// **`.regular`, and the tint kept low.** `Glass` offers two steps rather than a
/// dial — `.regular` and `.clear` — so "a little more frosted" is not directly
/// expressible. The Slab is the surface carrying rows of body text, and `.clear`
/// let the desktop through so completely that they were hard to read. `.regular`
/// supplies the blur and the tints come down a long way behind it. Blur and tint
/// are separate levers; the earlier mistake was cranking both. A Card is the
/// other choice, untinted and `Style.cardGlass`.
private func glass(_ tint: Color) -> Glass {
    .regular.tint(tint)
}

private struct SlabSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let palette = Palette.of(scheme)
        return content
            .glassEffect(glass(palette.surfaceTint), in: Style.slabShape)
            .clipShape(Style.slabShape)
            // After the clip, so the falloff follows the corner radius rather
            // than the content's own bounds.
            .shadow(color: palette.shadow, radius: Style.shadowRadius, y: Style.shadowY)
    }
}

/// A Card: one piece of plain native Liquid Glass, full size when it holds the
/// keyboard and stepped back when it does not.
///
/// **Nothing is clipped and no shadow is added.** `.glassEffect` draws its own
/// edge and its own adaptive shadow; a `clipShape` over it cuts that shadow into
/// a grey halo, and a second `.shadow` doubles it.
///
/// **The Emphasis is layout, never a transform.** The padding below is what
/// makes an unfocused Card smaller, and it is applied *after* `.glassEffect` on
/// purpose: glass fills the whole of the view it is applied to, including any
/// padding added before it, so only padding on the outside shrinks the glass
/// itself. A `.scaleEffect` cannot do this job — `GlassEffectContainer` builds
/// its shapes from layout frames and ignores the transform's anchor, so the
/// glass shrinks from the frame's top-left while the content scales about its
/// centre and the two drift apart (measured: ~10pt across, ~12pt down). With
/// the inset, the content is inside the glass and stays centred for nothing.
///
/// The glass also carries its own **Arrival**: `glassEffectID` is what lets the
/// container morph a new Card out of the one before it, and it belongs here
/// because the Card views must not name a material or a transition.
private struct CardSurface: ViewModifier {
    let focused: Bool
    let writing: Bool
    let phase: CardPhase
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        content
            // The ground goes on **before** the Emphasis opacity, so the two
            // recede together. Applied after it, the ground is outside the
            // dimming and an unfocused text Card keeps a full-strength slab
            // under faded text — the one part of the Card that would not step
            // back. The ground belongs to the content layer, not to the glass.
            .writingGround(writing)
            .opacity(focused ? 1 : Style.unfocusedContentOpacity)
            .glassEffect(Style.cardGlass, in: Style.cardShape)
            .glassEffectID(phase, in: namespace)
            // A Transition, not a fourth curve: the shape's growth rides
            // whatever animation the Card row's `cardCount` change is running.
            // Under Reduce Motion the new Card is simply there.
            .glassEffectTransition(Motion.isReduced ? .identity : .matchedGeometry)
            // The Emphasis. Outside the glass, so it shrinks the glass too —
            // and in layout, so glass and content shrink about the same centre.
            .padding(focused ? 0 : Style.unfocusedCardShrink)
            // Focus moving is **instant**, and this is what keeps it instant:
            // a Phase advance changes `cardCount` and `focused` in the same
            // update, and the row animates the first with `Motion.resize`. The
            // Arrival is a surface changing size and belongs in that animation;
            // a Card growing or shrinking because the keyboard moved is
            // information, and animating it lags the keypress. Scoped to
            // `focused`, so it cannot swallow the Arrival's own morph.
            .animation(nil, value: focused)
    }
}

/// The ground under a Card's body text.
///
/// A **content-layer fill, never a second piece of glass**: it is drawn on top
/// of the Card's material and behind its text, so the glass stays one sheet.
/// Glass over glass loses the backdrop it exists to reveal, and a Card holding a
/// page of text over a busy wallpaper is the one place legibility outranks the
/// backdrop.
///
/// It covers the **whole** Card, edge to edge in `cardShape` with no inset. An
/// inset panel floating inside the glass read as a card inside a card.
private struct WritingGround: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let writing: Bool

    func body(content: Content) -> some View {
        let palette = Palette.of(scheme)
        return content.background {
            if writing {
                Style.cardShape
                    .fill(palette.writingGround)
            }
        }
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
                    Style.resultShape.fill(palette.selectionFill)
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

    /// A Slab: the outer glass surface. Own shadow, clipped to
    /// `Style.slabRadius`.
    func slabSurface() -> some View {
        modifier(SlabSurface())
    }

    /// A Card: one piece of native Liquid Glass.
    ///
    /// - Parameters:
    ///   - focused: where the keyboard is. Signalled by the Card being at full
    ///     size with its content at full strength while the others step back —
    ///     no tint, no rim, no lift, no focus ring.
    ///   - writing: the Card holds editable or long-form text, which needs a
    ///     ground inside the Card to stay legible over a wallpaper.
    ///   - phase: which Card this is, so its glass can be matched across an
    ///     Arrival.
    ///   - namespace: the Card row's glass namespace.
    func cardSurface(
        focused: Bool,
        writing: Bool = false,
        phase: CardPhase,
        in namespace: Namespace.ID
    ) -> some View {
        modifier(
            CardSurface(focused: focused, writing: writing, phase: phase, namespace: namespace)
        )
    }

    /// A legible ground for body text, on the Card's glass and under the text.
    fileprivate func writingGround(_ writing: Bool) -> some View {
        modifier(WritingGround(writing: writing))
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
