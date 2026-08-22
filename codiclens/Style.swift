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

    /// Half the gap between two Cards, because it is a padding *outside* each
    /// Card's drawn surface: two adjacent Cards contribute one each, so the
    /// visible gutter is twice this.
    ///
    /// **24, and the Border Beam's glow used to be why. It is now 24 for nothing,
    /// and that is written down rather than acted on.** The beam's glow blurred
    /// *outward* from the rim for four passes, and the gutter was the room it had to
    /// fall off in: it must not reach a neighbouring Card's rim, which is
    /// `cardInset * 2` away, and the measured reach was **34pt** against 48pt of
    /// gutter. It went 6 → 12 → 24 for that.
    ///
    /// The fifth pass inverted the mask — see `BorderBeam.inward` — so the beam puts
    /// **zero** alpha outside the rim and needs no gutter at all. Going back to 12
    /// is therefore available and is a real gain: with `PanelLayout.cardWidth` and
    /// `cardHeight` held at 284 × 264 the drawn surface would grow 236 × 216 →
    /// **260 × 240**, which is 24pt of Card content in each direction handed back;
    /// alternatively, holding the surface and shrinking the cell would take the Panel
    /// from 968 × 732 to **872 × 708**. It is **not applied**, for one reason: the
    /// surface size is what `beamSeamOffset` is a function of, and moving
    /// `cardWidth - cardInset * 2` obliges a re-probe of a constant that has to be
    /// exact to a ten-thousandth. That is a separate change with its own
    /// verification, not a side effect of a paint fix.
    ///
    /// The history is worth keeping because the *second* step was the instructive
    /// one. It took its growth out of the **drawn surface**: the cell stayed
    /// 260 × 240 and the surface shrank 248 × 228 → 236 × 216, which is content the
    /// user paid for. The third grew `PanelLayout.cardWidth` and `cardHeight`
    /// 260 → 284 and 240 → 264 alongside the inset instead, so the surface stayed
    /// exactly 236 × 216 and the Panel got wider. The Panel is fixed and still never
    /// *resizes*; it is simply declared bigger, which is free, and it is why
    /// `beamSeamOffset` did not have to be re-probed.
    static let cardInset: CGFloat = 24
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

    /// How wide the comet's **core** is: the crisp line at the centre of the
    /// light, measured inward from the rim.
    ///
    /// **1pt, and it is a *visible* width rather than a stroke width.** The whole
    /// beam layer is masked to the region *inside* `cardShape` — see
    /// `BorderBeam.inward`, which is where the fifth pass's finding is written up —
    /// so the light lands on the Card's own glass rather than on the desktop. A
    /// `.stroke` is centred on the path it follows, so that mask takes the **outer**
    /// half away: what is stroked has to be wider than what is seen.
    /// `beamStrokeWidth` is the wider number, and it was probed rather than assumed.
    ///
    /// What survives is the band `[rim - 1, rim]`, which is exactly where
    /// `CardSurface`'s own `strokeBorder` hairline sits. That coincidence is the
    /// effect: the beam does not draw a second line inside the border, it lights the
    /// border.
    ///
    /// It was 3.5 when the beam was a bar. A comet is a light *source* travelling
    /// the rim, and a 3.5pt core with a blurred tail behind it reads as a fat
    /// smear; the crisp core is what keeps the glow behind it from being a smudge.
    static let beamWidth: CGFloat = 1

    /// What is actually handed to `StrokeStyle`, so that `beamWidth` survives the
    /// inward mask.
    ///
    /// Double, because a `.stroke` is centred on its path and the mask keeps the
    /// inner half. **The doubling is the arithmetic and it was still probed**, on
    /// the assumption that the mask's own antialiased edge would eat part of the
    /// innermost pixel row and 2.0 would come back measuring less than 1pt. It
    /// does not: rasterised at 2x, a 2.0pt stroke measures exactly 1.00pt of
    /// coverage on the kept side and 1.00pt of it at full alpha, because the mask
    /// edge and the stroke's far edge are the same curve and cancel rather than
    /// compound. 2.5 measures 1.25pt, which is a fatter head than was asked for.
    /// **Which half is kept flipped with the fifth pass's mask and the number did
    /// not move** — it is the same curve, cancelling the same way, from the other
    /// side: measured inward, the core reads alpha 194 on the pixel inside the rim
    /// against 172 outside it before.
    ///
    /// The measurement was taken on a straight edge, where the rim also happens to
    /// land on the pixel grid. Through a corner the inner edge feathers and the
    /// head reads a touch softer there. That is the corner, not the constant.
    static var beamStrokeWidth: CGFloat { beamWidth * 2 }

    /// The **core**'s blur radius at the very end of the tail.
    ///
    /// This is the core dissolving, not the glow. The trailing slices smear until
    /// the core has nothing left to end with. 6 rather than the 8 it was, because
    /// the glow layer now carries the reach and the core only has to stop being a
    /// line.
    ///
    /// The ramp from `beamCoreHeadBlur` to here is **linear** in the slice's
    /// position along the lit segment, deliberately: a linear ramp has no exponent
    /// to invent. (The glow's *opacity* ramp does have one, for reasons set out at
    /// `beamGlowRamp`; the two are not the same kind of thing.)
    static let beamCoreTailBlur: CGFloat = 6

    /// The **core**'s blur radius at the head, and it is **no longer 0**.
    ///
    /// **0 was the visible hard end, and it took a 3× zoom of a render to see
    /// it.** The core is `beamWidth` wide with `.butt` caps, so at blur 0 its
    /// leading tip is a 1pt square of alpha 250 with nothing either side of it:
    /// a dead-flat terminus at full contrast. Measured as the largest alpha step
    /// per half-point of arc, 1pt outside the rim, that tip scored **102** at the
    /// grow-in and **98** as the head reached the seam, against 1–4 anywhere along
    /// the beam's middle. It is the smallest artefact in the whole effect and it
    /// was the one the user could see: "the end where the beam thing stops looks
    /// bad because you can see where the border thing ends".
    ///
    /// 1.5 spreads that tip over about 4pt and takes the step to a fifth of what
    /// it was, and a 1pt line blurred by 1.5 is still unmistakably a line — probed
    /// at 3× on a white ground, the core reads as a hairline with the same
    /// near-rim alpha it had. It also flattens the worst of the per-slice banding:
    /// the core's blur ramp is quantised into `beamSegments` steps, and the steps
    /// nearest 0 are the ones the eye can see, because the alpha a 1pt line keeps
    /// falls off fastest there. Starting the ramp above 0 moves every step into the
    /// flat part of that curve.
    ///
    /// **The previous two passes both asserted 0 here, and the second one was
    /// right about its reason and wrong about the number.** "A crisp leading edge
    /// against a dissolving tail is the entire contrast the comet lives on" was
    /// used to justify a *single* layer with no halo, and correcting that to two
    /// layers left the 0 in place unexamined. The contrast the comet lives on is
    /// now the bloom against the tail. The core does not have to be razor sharp to
    /// be crisp, and being razor sharp is what gave it an end.
    static let beamCoreHeadBlur: CGFloat = 1.5

    // MARK: The glow layer

    /// How wide the **glow**'s source band is before it is blurred, measured
    /// inward from the rim.
    ///
    /// **This is the layer that makes the beam read as light coming off the Card
    /// rather than as a line drawn on it, and one layer could not do both.** A
    /// slice has one blur radius, so the crisp head and its halo cannot be the
    /// same stroke; the beam was one layer for exactly one release and the answer
    /// on screen was "there is not enough spread at all and it should be more
    /// clear that there even is a glow". Measured, that version put **zero**
    /// light more than 1pt outside the rim at the head — the halo was not small,
    /// it did not exist.
    ///
    /// 10, and it is wide *on purpose*. A 1pt line blurred by 20 is a hairline
    /// smeared to nothing: the blur spreads the same alpha over 40× the area, so
    /// the near-rim alpha collapses and the reach comes with no brightness. A
    /// 10pt band blurred by the same 20 keeps real alpha against the rim and
    /// still falls off over tens of points. Brightness near the source and reach
    /// away from it are set by the band's width and the blur radius separately,
    /// and that is the whole reason there is a width here at all.
    static let beamGlowWidth: CGFloat = 10

    /// What is handed to the glow's `StrokeStyle`, for the same reason
    /// `beamStrokeWidth` is doubled: the inward mask keeps the inner half of a
    /// centred stroke.
    static var beamGlowStrokeWidth: CGFloat { beamGlowWidth * 2 }

    /// The glow's blur radius **at the head**, and it is deliberately not 0.
    ///
    /// The one thing the previous version got wrong that reading could not catch.
    /// Its falloff ramped a single stroke's blur from 0 at the head to 8 behind
    /// it, and 0 at the head meant the brightest, most visible part of the whole
    /// effect was a bare 1pt line with no halo whatsoever. The glow is present
    /// along the *entire* lit segment, the head included, and the crisp core sits
    /// inside it: a bright line in a soft bloom, not a line that is soft at one
    /// end.
    ///
    /// 10 with `beamGlowHead`'s alpha at 0.80. Probed against three grounds in
    /// both appearances: at 8/0.85 the near-rim halo is stronger and the head's
    /// reach drops to 20pt; at 12/0.75 the reach is 28pt and the halo one point
    /// out is nearly half as bright. 10 is the middle and was chosen off the
    /// numbers.
    static let beamGlowHeadBlur: CGFloat = 12

    /// The glow's blur radius at the very end of the tail.
    ///
    /// **The ceiling used to be `cardInset * 2`, the gutter between two Card
    /// surfaces; it is now the Card's own interior.** For four passes the glow blew
    /// outward and the bound was that it must not reach a neighbouring Card's rim.
    /// Since the mask was inverted the glow spills *inward*, and what it must not do
    /// is wash over the Card's content: measured, it is still perceptible **33pt**
    /// in and gone by 40, on a 236 × 216 surface — so it dies at 30% of the way to
    /// the Card's centre, and nothing more than 36pt in ever sees alpha above **5**.
    ///
    /// What it does reach is the bottom-trailing `KeyHintChip`, which sits
    /// `Style.padding` (12) from two rims and takes up to alpha **77** as the head
    /// goes past. That is accepted rather than overlooked: the reference material's
    /// rim light spills over content near its own rim too, and the alternative is a
    /// glow that stops before it has started. A long app name is inset the same 12
    /// horizontally and gets the same treatment for the same fraction of a second.
    ///
    /// Raise this and re-measure that pair — the reach and the chip's alpha — rather
    /// than assuming either scales with the radius.
    ///
    /// It ramps *up* from `beamGlowHeadBlur` toward the tail, so the halo widens
    /// and thins as it trails — which is the tail dissolving without the glow
    /// ever going out.
    static let beamGlowTailBlur: CGFloat = 22

    /// The exponent that turns the glow from a **tube** into a **coma**.
    ///
    /// **This is the correction the third pass exists for, and it is the one
    /// thing here that reading could never have caught.** The glow's opacity was
    /// flat along the whole 303pt lit segment, on a rule that said the blur alone
    /// should carry the falloff. Rasterised, the near-rim alpha 4pt out ran
    /// 110, 109, 105, 99, 94, 93, 97, 100, 96, 87, 88, 93, 89 … from 15pt behind
    /// the head all the way to 180pt behind it. That is not a falloff, it is a
    /// glowing hose: nothing peaks anywhere, so there is no point for the light to
    /// be coming *from*, which is exactly what came back as "it should be more
    /// like a single area/point that a radial blue goes out from".
    ///
    /// So the glow — **and only the glow** — gets a per-slice opacity ramp,
    /// `position^beamGlowRamp`, peaking at the head and reaching nothing well
    /// before the segment's geometric end.
    ///
    /// **Why this is not `beamFalloff` coming back.** That exponent existed to
    /// undo a *linear* opacity ramp (1/20, 2/20, …) applied to the **only layer
    /// there was**, over colours already carrying alpha, which left 40pt of an
    /// intended 336pt on screen and made the beam invisible. Three things differ,
    /// and all three matter. There is now a separate crisp core carrying the
    /// beam's visibility, so the glow is *allowed* to fall to nothing — it is the
    /// bloom, not the beam. The ramp is deliberately steep rather than
    /// accidentally steep: killing the last fifth of the glow is the *point*,
    /// because a stroke that fades out before its own `.butt` cap has no cap to
    /// see. And it is measured across the beam as well as along it, which is the
    /// measurement the first pass never took.
    ///
    /// **2.4, raised from 1.4 for "the opacity of the start should be less so that
    /// it just looks more misty".** At 1.4 the near-rim alpha 4pt out read
    /// 155 / 111 / 85 / 75 / 58 at the head and 15, 30, 60 and 90 points behind it
    /// — a falloff, but a slow one, so the first third of the tail was still a band
    /// of paint. At 2.4 the same five places read **112 / 80 / 62 / 48 / 35**: the
    /// head against 90pt behind it goes from 2.7× to 3.2×, and the ratio to the far
    /// end of the segment from 7.4× to 8.6×.
    ///
    /// Intensity by position: 1.0 at the head, 0.19 a quarter back, 0.038 half way,
    /// 0.004 three quarters back — so more than half the stroked segment is
    /// effectively unlit glow and the visible comet is roughly 150pt of the 303
    /// that is stroked. That is the point rather than an accident; the crisp core
    /// still runs the whole length, which is what stops this being `beamFalloff`
    /// again.
    ///
    /// **The exponent is not the whole of the mist, and moving it alone would have
    /// been the wrong half.** The trailing end of the *glow* is already zero at any
    /// exponent — `position^ramp` is 0 at position 0 — so what is actually visible
    /// at the start of the beam is the **core**'s trailing colour, blurred by
    /// `beamCoreTailBlur`. Measured at the trailing terminus, alpha 1pt out went
    /// 22 → **14** only when `beamTail`'s own alpha came down 0.70 → 0.42. Raising
    /// this exponent thins the *body* of the tail; lowering `beamTail` thins its
    /// end.
    static let beamGlowRamp: Double = 2.4

    /// The glow's opacity multiplier for a slice at `position`.
    ///
    /// The core has no equivalent and must not get one: the core *is* the beam,
    /// and the reason a ramp is safe here is that something else is carrying
    /// visibility. See `beamGlowRamp`.
    static func beamGlowIntensity(at position: Double) -> Double {
        pow(min(max(position, 0), 1), beamGlowRamp)
    }

    // MARK: The head bloom

    /// The diameter of the **radial bloom** centred on the head, which is where
    /// the comet's light comes *from*.
    ///
    /// **A stroke, however blurred, is a lit line; it is never a light source.**
    /// The glow ramp above gives the comet a peak, and a peak on a band is still a
    /// band — what makes a glow read as emitted is a bloom with no edges at all in
    /// any direction, and a `RadialGradient` fill has none by construction. It is
    /// also what makes the head's terminus stop existing rather than merely
    /// soften: there is no end to see, because the brightest thing at the head is
    /// a circle rather than the end of a line.
    ///
    /// A `RadialGradient` used as a *fill* is not the stroke gradient this file
    /// has twice refused. An `AngularGradient` in a stroke sweeps at a constant
    /// *angular* rate and races a rectangle's long edges; a `LinearGradient` in a
    /// stroke does not follow the path at all. This one follows nothing — it is a
    /// disc, placed at a point.
    ///
    /// **96, and the constraint it was chosen against has moved without moving the
    /// number.** It used to be that the disc's geometric radius was exactly the
    /// gutter between two Card surfaces (`cardInset * 2` = 48pt) and nothing might
    /// reach a neighbouring Card's rim. Since the mask was inverted the disc's
    /// surviving half points *into* the Card, so the bound is the Card's own
    /// interior — 108pt to the centre from the long rim — and 96 is comfortably
    /// inside it. Either way the bound is the *measured* reach rather than the
    /// geometry: the gradient's outer stops are 0.02 and 0, so past about 30pt there
    /// is nothing there, and the whole beam's reach is **33pt**, essentially what it
    /// was outward. Raise this and re-measure the reach; do not reason from the
    /// radius.
    ///
    /// At 88 the head reads as a small bright spot rather than a glow; at 96 the
    /// halo eight points out measures Δ108 on white against Δ68 for the version
    /// this replaced, while total lit energy is down 46%. That pair is the whole
    /// brief: less light, further out.
    ///
    /// **Its alpha came down 0.76 → 0.48 with the fourth pass, and the diameter did
    /// not move.** The disc was the *densest* thing on screen in light appearance —
    /// rasterised over white it was a blue blob with the core's line lost inside it
    /// — and "no dense coloured halo anywhere" is the half of the reference the
    /// bloom was failing. Lowering the alpha rather than the diameter is deliberate:
    /// the diameter is what makes it have no edge, and 96 → 80 would have given back
    /// a findable rim. Turning the disc down and leaving it wide is what "misty"
    /// means here. Raising `beamGlowHeadBlur` 12 → 15 was tried in the same pass and
    /// reverted: it does lift the core's contrast against its own halo (rim / 4pt-out
    /// alpha 1.59 → 1.73) but it costs the halo everywhere — Δ at 4pt out on white
    /// fell 60 → 50 and the head's rim Δ 103 → 96 — and light appearance has none to
    /// spare.
    ///
    /// Half the disc is thrown away by the inward mask, which is correct — the light
    /// is on the Card's edge, spilling into the Card — and it is why the bloom's
    /// alpha is higher than a disc drawn whole would need. **Its alpha came down
    /// again with the inversion, 0.48 → 0.44 in dark and 0.48 → 0.28 in light**: the
    /// kept half now lands on the Card's own material rather than on a wallpaper, so
    /// the same disc reads considerably stronger, and in light appearance — where it
    /// is a *darkening*, see `Palette.beamHead` — a bloom at the old alpha rendered
    /// as a grey smudge inside the corner.
    static let beamBloomDiameter: CGFloat = 96

    /// Whether the glow layer is drawn at all.
    ///
    /// **Reduce Transparency drops the glow and keeps the sweep.** That is a
    /// separate switch from Reduce Motion and it means something different: Apple
    /// asks for opaque content rather than semi-transparent, and a blur is
    /// semi-transparent by definition. Reduce Motion removes the beam entirely
    /// (`BorderBeam` reads `Motion.isReduced`); this leaves the crisp core
    /// sweeping and takes the halo away. The two never fold into one another.
    ///
    /// The glow is dropped **whole** rather than un-blurred. Setting its blur to 0
    /// would leave a `beamGlowWidth`-wide flat band travelling the rim, which is
    /// not a quieter halo, it is a fat bar — and "a beam with no halo" is exactly
    /// what the accessibility answer has always said it should be.
    static var beamDrawsGlow: Bool { !Motion.isTransparencyReduced }

    /// The lit segment's length, as a fraction of the Card's perimeter.
    ///
    /// A fraction rather than a length, and it stays one now that the beam runs
    /// on a Card. Every Card is `PanelLayout.cardWidth` × `cardHeight`, so a
    /// length would work too — but the drawing is shape-agnostic and there is no
    /// reason to make it less so. It was load-bearing on the Slab, which ran from
    /// about 280 × 70 to 800 × 360: a fixed length there was a third of the
    /// smallest Slab's rim and a tenth of the largest's.
    ///
    /// In points, on the one size a Card is: the 236 × 216 surface's rim is about
    /// **866pt** after the corners are rounded off, so the comet is about
    /// **303pt** long and each of the `beamSegments` slices about **15pt**.
    static let beamTailFraction: CGFloat = 0.35

    /// How many sub-strokes build each layer of the tail.
    ///
    /// **This is the only way to vary a blur along a path.** The falloff cannot
    /// be a gradient — a `LinearGradient` in a `.stroke` does not follow a path,
    /// and an `AngularGradient` is a constant *angular* rate, which races the long
    /// edges of a rectangle and crawls its corners — and there is no API at all
    /// that makes a *blur* follow a path's arc length. But each slice is already
    /// its own view, so giving each one its own `blur(radius:)` is variable blur
    /// along a path, assembled out of the one primitive that *is* uniform in arc
    /// length: `trim`.
    ///
    /// Each slice's radius is a constant for the whole sweep — slice *i* is always
    /// the blur of its own position, and only its `from`/`to` move — so nothing
    /// here animates a blur radius. That is true of both layers.
    static let beamSegments: Int = 20

    /// The **core**'s blur radius for a slice at `position` along the lit segment,
    /// 0 at the trailing end and 1 at the head.
    ///
    /// Linear, from `beamCoreHeadBlur` at the head up to `beamCoreTailBlur` at the
    /// trailing end. It is never 0 — see `beamCoreHeadBlur`, which is where the
    /// two earlier versions of this were wrong.
    static func beamCoreBlur(at position: Double) -> CGFloat {
        let p = CGFloat(min(max(position, 0), 1))
        return beamCoreTailBlur + (beamCoreHeadBlur - beamCoreTailBlur) * p
    }

    /// The **glow**'s blur radius for a slice at `position`, ramping from
    /// `beamGlowHeadBlur` under the head *up* to `beamGlowTailBlur` at the
    /// trailing end.
    ///
    /// Never 0 anywhere the beam is lit. Under Reduce Transparency the layer is
    /// not drawn at all rather than un-blurred — see `beamDrawsGlow`.
    static func beamGlowBlur(at position: Double) -> CGFloat {
        let p = CGFloat(min(max(position, 0), 1))
        return beamGlowTailBlur + (beamGlowHeadBlur - beamGlowTailBlur) * p
    }

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
    /// `cardHeight - cardInset * 2`, **236 × 216**, because `.padding(cardInset)`
    /// sits *outside* the surface. Probed by sweeping `trim` over that shape at
    /// `cardRadius` and taking the fraction whose point is nearest the rect's
    /// top-left: **0.619221**, landing at (6.41, 6.41) — the 45° midpoint of the
    /// corner's own curve, which is as close to a rounded corner as a point on it
    /// gets.
    ///
    /// Probed, not derived, on purpose: the corners shorten the path, so the
    /// sharp-cornered `(1.5h + w) / 2(w + h)` is only an estimate. It happens to
    /// land at 0.619469 here — within 0.00025, or about a fifth of a point of rim
    /// — which is luck at this radius and not a licence to compute the next one.
    /// The proof that it is luck is sitting in this comment's own history: the
    /// surface was 248 × 228 before `cardInset` grew to 12, and the probe there
    /// read 0.619525 against an analytic 0.619748. Both pairs agree to four
    /// figures and neither agreement was predictable in advance.
    ///
    /// **It did not move when `cardInset` went 12 → 24 for the glow**, because
    /// `PanelLayout.cardWidth` and `cardHeight` went up by the same 24 and the
    /// drawn surface is still 236 × 216. This constant is a function of the
    /// *surface*, not of the cell: it is the cell that grew.
    ///
    /// Change `cardRadius`, or `cardWidth`, `cardHeight` or `cardInset` in a way
    /// that moves `cardWidth - cardInset * 2` or `cardHeight - cardInset * 2`, and
    /// this has to be re-probed. The probe is a `trim` sweep with successive refinement,
    /// taking the first point of `trimmedPath(from: f, to: f + ε)` — not
    /// `currentPoint` on `trimmedPath(from: 0, to: f)`, which returns the *end*
    /// of the sub-path and reads `nil` at f = 0.
    static let beamSeamOffset: CGFloat = 0.6192

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
/// long enough to be a colour the app is. The beam is gone in 0.55s.
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

    /// The Border Beam **core**'s bright leading edge, and the colour it fades
    /// out through.
    ///
    /// **The ground is the Card's own glass now, and that is the fifth pass and the
    /// only architectural change the beam has ever had.** For four passes the beam
    /// was masked to the region *outside* the rim, which is the gutter and then the
    /// Panel's transparent margin — the user's desktop. So none of the colour work
    /// below was ever measured against anything this app draws. Dark appearance's
    /// white head over a **white** desktop measured **Δ10/442**: invisible, and
    /// invisible for a reason no amount of retuning could reach. "Dark appearance"
    /// does not mean "dark ground". See `BorderBeam.inward`.
    ///
    /// Masked inward, the ground is `cardSurface(focused:)` — `.regular` glass at
    /// this palette's own `tint` and `base` — and it is *known*, in the only sense
    /// that matters: it is a material with a fixed polarity. Measured on the real
    /// composite, the Card's own luminance over a white desktop, a hazy grey-white
    /// one, a photograph and a near-black one:
    ///
    /// | | white | hazy | photo | near-black |
    /// |---|---|---|---|---|
    /// | dark appearance's Card | 166 | 145 | 62 | 22 |
    /// | light appearance's Card | 247 | 222 | 146 | 110 |
    ///
    /// `.regular` glass transmits, so neither row is a constant — but the two rows do
    /// not overlap, and that is enough to fix a polarity per appearance.
    ///
    /// **Dark appearance's core is white, which is the reference material exactly.**
    /// The reference — Tuna for Mac, in dark appearance — has a pale, crisp,
    /// near-white rim highlight and a Card whose **fill** is blue; reading that blue
    /// as belonging to the *light* is what sent two passes to a saturated core. The
    /// blue is in the fill. Measured off the crop, its Card's rim highlight sits
    /// around (150–185, 190–215, 225–248) over a fill of roughly (70, 120, 170), and
    /// its outer slab's rim around (165–180, 168–182, 172–188). Our core reads
    /// un-premultiplied **(248, 251, 255)** at own-colour saturation **0.026**, and
    /// composited over the Card it measures Δ87 / Δ104 / Δ174 / Δ256 across the four
    /// grounds above — against Δ17 / Δ27 / Δ95 / Δ270 outward. The floor went
    /// **17 → 87**.
    ///
    /// **Light appearance's core is a dark cool line, and that is the same idea
    /// rather than a retreat from it.** A highlight needs a ground darker than
    /// itself. Light appearance's Card is 247 over a white desktop, so a near-white
    /// line on it measures Δ5 — there is nothing brighter than white-tinted glass to
    /// be, which is the same sentence the old comment wrote about wallpaper, one
    /// layer in and now actually binding. So the polarity flips, exactly as every
    /// other edge in this appearance already does: `cardRim` is black 0.10 and
    /// `raisedRim` black 0.16. **(58, 68, 82)** un-premultiplied, own-colour
    /// saturation **0.293**, measuring Δ169 / Δ154 / Δ93 / Δ40 over the four grounds
    /// — against Δ89 / Δ63 / Δ59 / Δ204 for the blue it replaces.
    ///
    /// **What light appearance cannot do, and this time it is arithmetic rather than
    /// a hope.** Its Card spans 110 → 247 across wallpapers, a 137-unit range, so any
    /// colour on the grey axis is at most 68 units from one end or the other and a
    /// core keeps about 0.7 of that through the mask and its head blur: **~46 is the
    /// best worst-case a desaturated light core can have, and this one measures 40**,
    /// with its strong end at 169. Only saturation moves a colour off that axis, and
    /// a saturated blue is the thing this project shipped twice and withdrew twice.
    /// The old (0.50, 0.65, 0.98) measured 59–89 across all four grounds — flatter,
    /// and never good. Do not "fix" the 40 by saturating this again; that is the loop
    /// this comment exists to break, and do not fix it with a static lit rim, which
    /// has been declined.
    ///
    /// The trade is deliberate and it is the right way round: light appearance is now
    /// strongest over the *light* desktops most light-appearance users have, and
    /// weakest over a dark one, where the whole app is low-contrast anyway.
    let beamHead: Color
    let beamTail: Color

    /// The Border Beam **glow**'s colours — the halo under and behind the core.
    ///
    /// A second pair rather than the core's pair at a lower alpha, because the
    /// glow is a wider band and wants less saturation and less weight per pixel
    /// than the line at its centre.
    ///
    /// **Both alphas came down twice, because "too dense" was said twice.**
    /// 0.80 → 0.55, then 0.72 → 0.46, and dark's are now **0.52 → 0.16**. The tail's
    /// is the one that moved furthest, on purpose: "the opacity of the start should
    /// be less so that it just looks more misty" is a statement about the trailing
    /// end, and the head's halo is the part that has to stay.
    ///
    /// The saturation came down with them: dark's glow head is
    /// **(0.92, 0.96, 1.00)**, which is white with a hint, having been (0.88, 0.94,
    /// 1.00) and before that a real blue. The reference has no dense coloured halo
    /// anywhere in it, and a halo is where a colour is most obvious because it covers
    /// the most pixels.
    ///
    /// **Light's pair is now the other polarity and quieter again** — (0.26, 0.30,
    /// 0.38) at **0.34** and (0.34, 0.38, 0.46) at **0.10**, from 0.52 and 0.16. Two
    /// reasons, both measured. The kept half of the halo lands on the Card's own
    /// material instead of on a wallpaper, so the same alpha reads considerably
    /// stronger; and a *darkening* spread over 30pt of a light Card is a grey wash
    /// where the same thing in dark appearance is a mist. Rendered at 3× over a white
    /// desktop at 0.46 it read as a soft shadow band down the inside of the rim
    /// competing with the line; at 0.34 the line is the brightest thing in it.
    ///
    /// A ramp *is* multiplied over these now, and only over these:
    /// `Style.beamGlowIntensity(at:)`. That is a deliberate reversal of the "no
    /// computed ramp" rule, which was right while the glow was the whole beam and
    /// wrong once it was the bloom around a core. See `Style.beamGlowRamp` for why
    /// it is not the deleted `beamFalloff` returning.
    let beamGlowHead: Color
    let beamGlowTail: Color

    /// The **radial head bloom**'s colour: the light the comet comes out of.
    ///
    /// One colour rather than a pair, because a bloom has no head and tail — it
    /// is a disc. Its falloff is the gradient's own stops, in `BeamBloom`.
    ///
    /// Less saturated than `beamGlowHead` in both appearances and deliberately so:
    /// this is the widest, softest thing the beam draws, and a saturated wash
    /// across 38pt is the blue *paint* an earlier version was rejected for. In light
    /// appearance it is a *darkening* rather than a brightness — see `beamHead`,
    /// which is where the polarity is argued — and it carries the least of anything
    /// per pixel, because the widest soft thing is the one that reads as mud first.
    ///
    /// **0.76 → 0.48, and it is the single biggest reason the head stopped being a
    /// blob.** At 0.76 the disc was brighter than the core it sits under, so the
    /// crisp line was *inside* the brightest thing on screen and could not be seen
    /// as a line. The rim's alpha against the alpha 4pt out went 1.30 → **1.59**
    /// across this pass, which is the number that says the line reads.
    let beamBloom: Color

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
        beamHead: .white.opacity(1.0),
        beamTail: Color(red: 0.74, green: 0.85, blue: 1.0).opacity(0.42),
        beamGlowHead: Color(red: 0.92, green: 0.96, blue: 1.0).opacity(0.52),
        beamGlowTail: Color(red: 0.80, green: 0.88, blue: 1.0).opacity(0.16),
        beamBloom: Color(red: 0.88, green: 0.93, blue: 1.0).opacity(0.44)
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
        beamHead: Color(red: 0.22, green: 0.25, blue: 0.31).opacity(1.0),
        beamTail: Color(red: 0.32, green: 0.36, blue: 0.44).opacity(0.42),
        beamGlowHead: Color(red: 0.26, green: 0.30, blue: 0.38).opacity(0.34),
        beamGlowTail: Color(red: 0.34, green: 0.38, blue: 0.46).opacity(0.10),
        beamBloom: Color(red: 0.28, green: 0.32, blue: 0.40).opacity(0.28)
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

/// Which of the comet's two layers a slice belongs to.
///
/// **Two layers, because one slice can only have one blur radius.** The comet
/// wants a crisp line *inside* a soft bloom, and a single sliced stroke whose
/// blur ramps along the segment structurally cannot be both at once — which is
/// how it came to ship with a head whose blur was exactly 0 and therefore no halo
/// at all. The glow is drawn first and underneath; the core is drawn on top.
enum BeamLayer {
    /// The bloom. Wide, always blurred, present along the whole lit segment
    /// including under the head.
    case glow
    /// The crisp line at the centre of the light. 1pt visible, and *barely*
    /// blurred at the head rather than unblurred — see `Style.beamCoreHeadBlur`,
    /// where 0 was the visible hard end three times over.
    case core
}

/// One slice of one layer of the comet: a Card's own rim shape, trimmed to
/// `from...to`, stroked and blurred according to which layer it is and how far
/// behind the head it sits.
///
/// It lives here rather than in `BorderBeam.swift` because it is the part of the
/// beam that is a *colour*, and `Palette` is private to this file. The beam's
/// geometry — where the lit segment is at a given moment, and how it is sliced —
/// is the modifier's business; which blue a slice is drawn in is this file's, the
/// same as every other colour in the app.
///
/// **Exactly one computed opacity ramp, and it is the glow's.**
/// `Style.beamGlowIntensity(at:)` multiplies `position^beamGlowRamp` into the
/// glow's colour and nothing else's. The core has none and must not get one: the
/// core *is* the beam, and the reason a ramp is safe on the glow is that
/// something else is carrying visibility. The deleted `Style.beamFalloff` was a
/// ramp on the **only layer there was**, over colours that already carried alpha,
/// and it put the trailing slices near 0.05 effective alpha and left a 40pt sliver
/// of an intended 336pt of lit rim — see `Style.beamGlowRamp` for the full
/// distinction. The head-to-tail colour *mix* below is neither of those; it is two
/// named colours and an interpolation between them, and it is what the beam has
/// always done.
struct BeamSlice: View {
    @Environment(\.colorScheme) private var scheme

    let from: CGFloat
    let to: CGFloat

    /// Where this slice sits along the lit segment: 0 at the trailing end,
    /// 1 at the head. The colour and the blur radius are both functions of it,
    /// so the tail warms toward the head's colour as it sharpens into it.
    let position: Double

    let layer: BeamLayer

    var body: some View {
        let palette = Palette.of(scheme)
        let tint = switch layer {
        // The glow's ramp, and the *only* computed ramp in the beam. It is what
        // turns a constant-opacity band into a coma with a peak — see
        // `Style.beamGlowRamp` for why it is safe here and was not safe as
        // `beamFalloff`.
        case .glow: palette.beamGlowTail.mix(with: palette.beamGlowHead, by: position)
            .opacity(Style.beamGlowIntensity(at: position))
        case .core: palette.beamTail.mix(with: palette.beamHead, by: position)
        }
        let width = switch layer {
        case .glow: Style.beamGlowStrokeWidth
        case .core: Style.beamStrokeWidth
        }
        let blur = switch layer {
        case .glow: Style.beamGlowBlur(at: position)
        case .core: Style.beamCoreBlur(at: position)
        }
        return Style.cardShape
            .trim(from: from, to: to)
            .stroke(
                tint,
                // `.butt` on both layers, and the reason is no longer beading.
                // A round cap bulges half the line width past each slice's own
                // trim range. On the *core*, whose stroke is 2pt, that produced
                // the row of bright beads this comment used to describe. On the
                // *glow*, whose stroke is 20pt, it was re-measured with the
                // opacity ramp in place and does **not** bead — 0–4 turns in the
                // along-beam profile, the same as `.butt` — and is rejected for a
                // different and worse reason: each slice's 10pt bulge overlaps its
                // neighbours, so every slice's opacity is smeared into the ones
                // either side and the ramp flattens back into the tube it was
                // introduced to fix. Measured, `.round` on the glow put the alpha
                // 30pt behind the head at 153 against the head's 194 (a ratio of
                // 1.3) where `.butt` reads 96 against 175 (1.8), and raised the
                // total lit energy 53%. The falloff is the thing being protected.
                style: StrokeStyle(lineWidth: width, lineCap: .butt)
            )
            .blur(radius: blur)
    }
}

/// The comet's nucleus: a radial bloom, drawn at the head.
///
/// **This is the piece that makes the effect read as light rather than as paint,
/// and it is not a fourth tuning of the stroke.** A stroke has ends. Blur them
/// and they are soft ends; ramp them and they are faint ends; they are still
/// ends, and "you can see where the border thing ends" is what came back twice.
/// A `RadialGradient` fill has no ends in any direction by construction — it
/// fades to nothing everywhere — so the head stops having a terminus rather than
/// having a well-hidden one. It is also, straightforwardly, what was asked for:
/// "a single area/point that a radial blue kinda goes out from".
///
/// It lives here rather than in `BorderBeam.swift` for the same reason
/// `BeamSlice` does: `Palette` is private to this file, and which blue a thing is
/// drawn in is this file's business. Where the head *is* at a given phase is the
/// modifier's.
///
/// The stops are a hand-rolled Gaussian-ish shoulder rather than a two-stop
/// linear fade. A linear `RadialGradient` reads as a disc with a visible rim at
/// its own edge — the falloff is constant, so the eye finds the boundary where it
/// reaches zero. Front-loading it (1.00, 0.62, 0.30, 0.11, 0.02, 0) puts most of
/// the light in the inner third and lets the outer half approach nothing
/// asymptotically, which is what has no edge.
///
/// **Masked inward with everything else.** A disc centred on the rim spreads
/// outward exactly as far as inward, so half of it is thrown away either way; what
/// changed with the fifth pass is *which* half. It used to be the inner one, on the
/// rule that nothing may wash over the Card's content — which also meant the disc
/// only ever landed on the user's wallpaper. It is now the outer one, so the disc's
/// light falls on the Card's own glass and spills into the Card. See
/// `BorderBeam.inward`.
struct BeamBloom: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let bloom = Palette.of(scheme).beamBloom
        return RadialGradient(
            stops: [
                .init(color: bloom, location: 0),
                .init(color: bloom.opacity(0.62), location: 0.16),
                .init(color: bloom.opacity(0.30), location: 0.34),
                .init(color: bloom.opacity(0.11), location: 0.56),
                .init(color: bloom.opacity(0.02), location: 0.78),
                .init(color: bloom.opacity(0), location: 1)
            ],
            center: .center,
            startRadius: 0,
            endRadius: Style.beamBloomDiameter / 2
        )
        .clipShape(Circle())
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
