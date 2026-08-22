import SwiftUI

/// The whole visual language, in one place.
///
/// Every radius, material, tint, rim and shadow in Codiclens is defined here.
/// No view outside this file holds one, and no view outside this file branches
/// on `colorScheme` — see `docs/adr/0002-liquid-glass-over-hand-rolled.md`.
///
/// There are exactly three tiers:
///
/// - **surface** — a Slab. Liquid Glass and its own shadow, and **no rim**: it is
///   the one surface that carries none. `Palette.slabRim` is declared and unused,
///   which is deliberate rather than forgotten — it was wired up once, while the
///   Border Beam lived on the Slab and wanted an edge to run along, and reverted
///   when the beam moved to the Cards. `slabSurface()`.
/// - **raised** — the focused Card. Brighter and a touch more defined at the
///   edge than its neighbours. No accent colour: brightness is the focus
///   signal. `cardSurface(focused: true)`.
/// - **recessed** — an unfocused Card, and every Result row or grid cell.
///   A neutral well sunk into the Slab. `cardSurface(focused: false)` and
///   `resultSurface(selected:)`.
///
/// Slabs and Cards both use `.glassEffect`, because both are top-level surfaces
/// floating over the desktop. Results are the one flat tier: they sit *inside*
/// the Results Slab, and glass stacked on glass loses the backdrop it exists to
/// reveal.
///
/// **Every surface draws its own shadow, and the window draws none.** A
/// `.shadow()` on a view that fills its window is clipped by the window bounds
/// and renders as a hard band down two edges rather than a falloff, which is why
/// there were no shadows at all until the Panel was sized larger than its
/// content. `PanelLayout.margin` is the empty space they fall off into; shrink it
/// and the band comes back. `FloatingPanel.hasShadow` stays `false` regardless —
/// AppKit deriving a window shadow from transparent glass traces a ragged
/// contour. `docs/DESIGN-HANDOFF.md` has the detail. A Card keeps a faint rim,
/// stroked *after* the clip so the hairline is not half cut away.
enum Style {

    // MARK: - Geometry

    /// The Results Slab. Lower than a Card on purpose: it is the larger, calmer
    /// surface, and matching the Cards' curvature made it look inflated.
    static let slabRadius: CGFloat = 18

    /// A Card. Cards are their own top-level surfaces — there is no Card Slab
    /// behind them — so this is chosen for the Card's own proportions rather
    /// than derived from a container.
    static let cardRadius: CGFloat = 22

    /// A Result row or grid cell.
    static let resultRadius: CGFloat = 10

    static let padding: CGFloat = 12
    static let gap: CGFloat = 12

    /// One device pixel's worth of rim at 1x, which is what a hairline means.
    static let hairline: CGFloat = 1

    /// The gap between two Cards.
    static let cardInset: CGFloat = 6
    /// A Result's own inset from the Slab edge, so its selection fill reads as a
    /// row inside the Slab rather than a band across it.
    static let resultInset: CGFloat = 6

    /// The icon in a Card. Smaller than it was: a 96pt glyph left no room for a
    /// label and made a Card read as one big picture.
    static let cardIcon: CGFloat = 64

    static let rowPaddingH: CGFloat = 10
    static let rowPaddingV: CGFloat = 7
    static let chipPaddingH: CGFloat = 7
    static let chipPaddingV: CGFloat = 3

    // MARK: - Loading Ring

    /// The Loading Ring's box. A `.small` `ProgressView` — the system spinner
    /// this replaced — occupies about 14pt, so nothing sized to fit that moves.
    static let ringDiameter: CGFloat = 13

    static let ringStroke: CGFloat = 1.5

    /// How much of the circle is lit: 270°, and a **constant** length. A ring
    /// that fills once and waits would be a progress claim, and neither Vision
    /// nor `mdfind` reports progress for it to be a measure of.
    static let ringArcFraction: CGFloat = 0.75

    // MARK: - Border Beam

    /// The lit segment's width. Half a point proud of the 1pt rim on either
    /// side, which is what lets it read as light running *down* the rim rather
    /// than as a second line beside it. 1pt disappears at this speed; 3pt and up
    /// becomes a bar.
    static let beamWidth: CGFloat = 3.5

    /// The lit segment's length, as a fraction of the Card's perimeter.
    ///
    /// A fraction rather than a length, and it stays one now that the beam runs
    /// on a Card. Every Card is `PanelLayout.cardWidth` × `cardHeight`, so a
    /// length would work too — but the drawing is shape-agnostic and there is no
    /// reason to make it less so. It was load-bearing on the Slab, which ran from
    /// about 280 × 70 to 800 × 360: a fixed length there was a third of the
    /// smallest Slab's rim and a tenth of the largest's.
    static let beamTailFraction: CGFloat = 0.35

    /// How many stepped sub-strokes build the tail's falloff.
    ///
    /// The falloff cannot be a gradient. A `LinearGradient` in a `.stroke` does
    /// not follow a path, and an `AngularGradient` is a constant *angular* rate,
    /// which races the long edges of a wide rectangle and crawls its corners.
    /// So the tail is this many equal slices *of path length*, each a flat
    /// colour, stepping from `beamTail` to `beamHead`.
    static let beamSegments: Int = 20

    /// How sharply the tail fades out, as an exponent on each slice's position
    /// along the lit segment.
    ///
    /// **Below 1 on purpose, and it is the difference between a beam and
    /// nothing.** A straight linear ramp — opacity 1/n, 2/n, 3/n … — is not a
    /// falloff, it is a deletion: it multiplies on top of colours that already
    /// carry alpha, so the first slices land near 0.05 effective alpha and the
    /// only thing left on screen is the leading slice, a fortieth of the rim.
    /// The rendered probe that caught it showed a 40pt sliver where 336pt of lit
    /// rim was intended. This pulls the whole tail back above the visibility
    /// floor while still falling off.
    static let beamFalloff: Double = 0.3

    /// Where the seam is: the point on the rim the head enters through and the
    /// tail leaves through, as a fraction of the perimeter from the start of
    /// `cardShape`'s own path.
    ///
    /// **This is not zero, and the reason is measured rather than assumed.**
    /// SwiftUI's `RoundedRectangle` path begins at the *right* edge's vertical
    /// midpoint and runs clockwise from there — right, bottom, left, top — so
    /// fraction 0 is the middle of the right-hand edge, 0.25 the middle of the
    /// bottom, 0.5 the middle of the left, 0.75 the middle of the top. The
    /// top-left corner therefore falls a little past 0.5.
    ///
    /// **And now it is exact, which it could not be while the beam was on the
    /// Slab.** The Slab's proportions vary — the same corner sat at 0.547 at
    /// 280 × 70 and 0.604 at 280 × 200 — so one constant was a compromise across
    /// a range, and 0.56 was the middle of it. Every Card is one size: the
    /// surface the beam strokes is `PanelLayout.cardWidth - cardInset * 2` ×
    /// `cardHeight - cardInset * 2`, 248 × 228, because `.padding(cardInset)`
    /// sits *outside* the surface. Probed by sweeping `trim` over that shape at
    /// `cardRadius` and taking the fraction whose point is nearest the rect's
    /// top-left: **0.619525**, landing at (6.41, 6.41) — the 45° midpoint of the
    /// corner's own curve, which is as close to a rounded corner as a point on it
    /// gets.
    ///
    /// Probed, not derived, on purpose: the corners shorten the path, so the
    /// sharp-cornered `(1.5h + w) / 2(w + h)` is only an estimate. It happens to
    /// land at 0.619748 here — within 0.0002, or about a tenth of a point of rim
    /// — which is luck at this radius and not a licence to compute the next one.
    ///
    /// Change `cardRadius`, `cardWidth`, `cardHeight` or `cardInset` and this has
    /// to be re-probed.
    static let beamSeamOffset: CGFloat = 0.6195

    // MARK: - Shadow

    /// How far a surface's shadow reaches, and how far it hangs below the
    /// surface. Both are bounded by `PanelLayout.margin`: the shadow needs to
    /// have fallen off to nothing before it reaches the window edge, or it is
    /// clipped into a hard band instead.
    static let shadowRadius: CGFloat = 16
    static let shadowY: CGFloat = 5

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
/// The two appearances are treated **asymmetrically on purpose**. A light
/// surface floats over a light wallpaper, where a blur alone leaves nothing to
/// see, so light gets a stronger tint into the glass and a darker rim to cut its
/// own edge. A dark surface has contrast for free and leans on the shadow
/// instead, so its tint stays thin and its rim is a light catch along the edge
/// rather than a border.
///
/// **There is no accent colour here, deliberately.** Focus and selection are
/// signalled by brightness and rim weight alone. An accent fill across a whole
/// Card turned the Panel into a coloured box, and a tinted selection fought
/// every app icon it sat next to.
///
/// The Border Beam's two colours are the one exception, and a deliberate one.
/// The ban `CONTEXT.md` records is on a *static* accent — something on screen
/// long enough to be a colour the app is. The beam is gone in 0.25s.
private struct Palette {

    /// The one colour every glass surface is tinted with.
    ///
    /// White in light, black in dark — and **nothing mixes the two**. An earlier
    /// version tinted a Slab with black 0.16 while tinting a focused Card with
    /// white 0.09, in the same appearance. Those are not two weights of one
    /// material, they are two different materials, and the Cards visibly did not
    /// belong to the Slab.
    let tint: Color

    /// The tint weight **every** surface shares: Slab, Card, focused or not.
    ///
    /// This is the value that makes the app look like one sheet of glass cut
    /// into pieces rather than a pile of unrelated panes. Every other surface
    /// weight below is this number plus a small delta — expressed as a delta
    /// precisely so it cannot drift into a different material again.
    let base: Double

    /// The focused Card's brightening, laid *over* the glass rather than mixed
    /// into its tint.
    ///
    /// It has to be a separate overlay, not a delta on `base`, because `tint`
    /// changes polarity between appearances. Adding to the tint brightens a
    /// white-tinted light Slab but *darkens* a black-tinted dark one — so
    /// `base + focusLift` made a focused Card in dark mode dimmer than its
    /// unfocused neighbour, which is backwards. Light brightens both.
    let highlight: Color

    /// Added for a Card holding editable body text.
    ///
    /// Added for a Card holding editable body text, which needs the most
    /// contrast of anything on screen. Much smaller than it was: the material
    /// carries legibility now, so this only has to nudge.
    ///
    /// Unlike focus, this one *is* a delta on `base`, and correctly so: more
    /// tint means more contrast against the body text in both appearances,
    /// because the tint's polarity already follows the text colour.
    let writingLift: Double

    let slabRim: Color
    /// An unfocused Card: present, but plainly not where the keyboard is.
    let cardRim: Color
    /// The focused Card — a touch more defined at the edge.
    let raisedRim: Color

    /// The selected Result. A neutral lift, strong enough to find at a glance
    /// and quiet enough to sit under a row of app icons.
    let selectionFill: Color

    /// Chip — keyboard hints, counts, badges.
    let chipFill: Color
    let chipRim: Color

    /// What a surface casts onto whatever is behind it.
    ///
    /// Black in both appearances — a shadow is an absence of light, so unlike
    /// `tint` it does not flip polarity. Only the weight differs, and it is
    /// heavier in dark: the falloff has to be visible against a dark desktop
    /// without turning into a halo on a light one.
    let shadow: Color

    /// The Border Beam's bright leading edge, and the colour its tail fades out
    /// through.
    ///
    /// Asymmetric between appearances for the same reason everything else here
    /// is, and more sharply. A near-white beam on a light Card — white-tinted
    /// glass over a light wallpaper — is invisible, so light carries the blue
    /// much further toward the head and puts a deeper blue in the tail. Dark
    /// gets a white head for free.
    let beamHead: Color
    let beamTail: Color

    // MARK: Derived surface tints

    /// Slab, focused Card and unfocused Card all share this. The Slab is not a
    /// different material from the Cards floating above it, and focus is an
    /// overlay on top rather than a different glass.
    var surfaceTint: Color { tint.opacity(base) }

    var writingTint: Color { tint.opacity(base + writingLift) }

    static let dark = Palette(
        tint: .black,
        // Still heavier than light's, because dark appearance draws primary
        // text in white and needs a dark ground for it. Far lower than it was
        // under clear glass, though: 0.58 was propping up legibility that the
        // material now provides, and it read as opaque rather than as glass.
        base: 0.26,
        // Deliberately faint. In dark appearance a white highlight is the one
        // thing that can lift a Card off the tint it shares with the Slab, and
        // a Card that reads lighter than the Slab both breaks that shared-sheet
        // look and takes white text back towards unreadable. The rim carries
        // most of the focus signal here instead.
        highlight: .white.opacity(0.06),
        writingLift: 0.14,
        slabRim: .white.opacity(0.10),
        cardRim: .white.opacity(0.12),
        raisedRim: .white.opacity(0.38),
        selectionFill: .white.opacity(0.13),
        chipFill: .white.opacity(0.09),
        chipRim: .white.opacity(0.10),
        shadow: .black.opacity(0.44),
        beamHead: .white.opacity(0.95),
        beamTail: Color(red: 0.45, green: 0.65, blue: 1.0).opacity(0.70)
    )

    static let light = Palette(
        tint: .white,
        base: 0.15,
        highlight: .white.opacity(0.30),
        writingLift: 0.18,
        slabRim: .black.opacity(0.08),
        cardRim: .black.opacity(0.10),
        raisedRim: .black.opacity(0.16),
        selectionFill: .black.opacity(0.07),
        chipFill: .white.opacity(0.62),
        chipRim: .black.opacity(0.07),
        shadow: .black.opacity(0.20),
        beamHead: Color(red: 0.62, green: 0.78, blue: 1.0).opacity(0.95),
        beamTail: Color(red: 0.30, green: 0.50, blue: 0.95).opacity(0.60)
    )

    static func of(_ scheme: ColorScheme) -> Palette {
        scheme == .dark ? .dark : .light
    }
}

// MARK: - Tier modifiers

/// Glass at one shared tint.
///
/// **`.regular`, and the tint kept low.** `Glass` offers two steps rather than a
/// dial — `.regular` and `.clear` — so "a little more frosted" is not directly
/// expressible. `.clear` let the desktop through so completely that the Panel's
/// own content was hard to read, and dark appearance had to push its tint to
/// 0.58 to keep white text legible, which read as opaque anyway. `.regular`
/// supplies the blur and the tints come down a long way behind it. Blur and tint
/// are separate levers; the earlier mistake was cranking both.
///
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

/// A Card is a top-level surface, not a fill inside a Slab.
///
/// There is no Card Slab behind the Cards, so each Card carries its own glass,
/// its own rim and its own shadow — the same construction as a Slab at a
/// different radius. A plain fill would have nothing to sit on.
private struct CardSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let focused: Bool
    let writing: Bool

    func body(content: Content) -> some View {
        let palette = Palette.of(scheme)
        let fill = writing ? palette.writingTint : palette.surfaceTint
        let rim = focused ? palette.raisedRim : palette.cardRim
        return content
            .glassEffect(glass(fill), in: Style.cardShape)
            // Focus brightens the Card by sitting a light fill *behind* the
            // glass, so the glass carries it and the Card's own content is not
            // washed over. Never by tinting the glass instead: the tint's
            // polarity flips between appearances and would dim the Card in dark
            // mode. Alpha is higher than it looks like it needs to be because
            // translucent glass eats most of it.
            .background {
                if focused {
                    Style.cardShape.fill(palette.highlight)
                }
            }
            .clipShape(Style.cardShape)
            .overlay {
                Style.cardShape.strokeBorder(rim, lineWidth: Style.hairline)
            }
            .shadow(color: palette.shadow, radius: Style.shadowRadius, y: Style.shadowY)
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

/// One slice of the Border Beam's tail: a Card's own rim shape, trimmed to
/// `from...to` and stroked at `Style.beamWidth`.
///
/// It lives here rather than in `BorderBeam.swift` because it is the only part
/// of the beam that is a *colour*, and `Palette` is private to this file. The
/// beam's geometry — where the lit segment is at a given moment, and how it is
/// sliced — is the modifier's business; which blue a slice is drawn in is this
/// file's, the same as every other colour in the app.
struct BeamSlice: View {
    @Environment(\.colorScheme) private var scheme

    let from: CGFloat
    let to: CGFloat

    /// Where this slice sits along the lit segment: 0 at the trailing end,
    /// 1 at the head. Both the colour and the opacity are functions of it, so
    /// the tail steps to fully transparent behind the beam.
    let position: Double

    var body: some View {
        let palette = Palette.of(scheme)
        return Style.cardShape
            .trim(from: from, to: to)
            .stroke(
                palette.beamTail
                    .mix(with: palette.beamHead, by: position)
                    .opacity(pow(position, Style.beamFalloff)),
                // `.butt`, never `.round`. A round cap bulges half the line
                // width past each slice's own trim range, so twenty translucent
                // slices overlap at nineteen joints and each overlap composites
                // twice — which renders as a row of regular bright beads down
                // the beam rather than a smooth falloff. Confirmed in a probe
                // render, not guessed at.
                style: StrokeStyle(lineWidth: Style.beamWidth, lineCap: .butt)
            )
    }
}

// MARK: - The API views use

extension View {

    /// A Slab: the outer glass surface. Own rim, own shadow, clipped to
    /// `Style.slabRadius`.
    func slabSurface() -> some View {
        modifier(SlabSurface())
    }

    /// A Card: a top-level glass surface with its own rim and shadow.
    ///
    /// - Parameters:
    ///   - focused: where the keyboard is. Signalled by a brighter fill and a
    ///     stronger rim, never by an accent colour or a system focus ring.
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
