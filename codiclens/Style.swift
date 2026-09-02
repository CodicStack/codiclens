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
/// - **raised** — the focused Card. Its **Lamp** is turned up: the static,
///   monochrome light along the top of the rim that every Card carries. No
///   accent colour, and no brighter fill: lamp weight is the focus signal.
///   `cardSurface(focused: true)`.
/// - **recessed** — an unfocused Card, and every Result row or grid cell.
///   A neutral well sunk into the Slab; a Card's Lamp is turned down, not off.
///   `cardSurface(focused: false)` and `resultSurface(selected:)`.
///
/// **A Card's glass has depth, and the depth is three overlays on native Liquid
/// Glass, not a hand-rolled material.** `docs/adr/0002` bans re-implementing the
/// *blur*; it says nothing about light. `.glassEffect` alone rendered a flat grey
/// rectangle with a faint lensing edge — measured over a flat 0.82 grey ground, the
/// focused and unfocused Cards were two greys and nothing else. So a Card is
/// `.glassEffect` plus: a **specular** wash behind the glass across its top
/// (`Style.specularReach`), an **inner shadow** behind the glass along its bottom
/// (`Style.innerShadowStart`), and the **Lamp** on the rim (`Style.lampReach`), all
/// lit from the top, all static, all monochrome. Together they are what the
/// reference (Tuna for Mac) reads as expensive; the Border Beam was asked to carry
/// that on its own for six passes and could not, because a light that is gone in
/// 0.55s is not what a surface *is*.
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

    // MARK: - Glass depth

    /// How far down the Card the Lamp reaches, as a fraction of its height. The
    /// rim's light is full at the top edge and gone by here; below it only the
    /// base rim (`Palette.cardRim` / `raisedRim`) defines the edge. Past about
    /// 0.7 the gradient reads as a lit rim with a dim bottom rather than a lit
    /// *top*, which is the lamp becoming a border again.
    static let lampReach: CGFloat = 0.62

    /// How far down the Card the specular wash reaches. Shorter than the Lamp on
    /// purpose: a wash across the whole top half is a fill, and a fill across a
    /// Card is what the accent ban was written against.
    static let specularReach: CGFloat = 0.42

    /// Where the inner shadow begins, as a fraction of the Card's height from the
    /// top. It is full at the bottom edge. What it is for: a sheet of glass lit from
    /// above is darker where the light has to travel through it, and without it the
    /// specular reads as a stain on a flat card rather than as depth.
    ///
    /// The ramp is **eased** — see `CardSurface` — with a mid stop at
    /// `innerShadowMid` of the full weight. A linear ramp from zero at this point
    /// rendered as a horizontal *line* across the Card where it began, because the
    /// eye finds the kink in a gradient's first derivative; and at 0.38 alpha in dark
    /// it turned the bottom two fifths of the Card into a flat band rather than a
    /// falloff. Measured over a 0.82 grey ground and a 0.08 one.
    static let innerShadowStart: CGFloat = 0.40
    static let innerShadowMid: Double = 0.30

    /// Half the gap between two Cards, because it is a padding *outside* each
    /// Card's drawn surface: two adjacent Cards contribute one each, so the
    /// visible gutter is twice this.
    ///
    /// **24, and the Border Beam's glow is why — again.** The beam's halo blurs
    /// *outward* from the rim, and the gutter is the room it has to fall off in: it
    /// must not reach a neighbouring Card's rim, which is `cardInset * 2` away, and
    /// the measured reach is **40pt** against 48pt of gutter. It went 6 → 12 → 24
    /// for that.
    ///
    /// The fifth pass inverted the mask, which briefly made this 24 for nothing and
    /// put a written-up proposal here to take it back to 12. **The sixth pass put the
    /// halo back outside and that proposal is deleted rather than left lying** —
    /// there is no version of this where a beam that blooms outward has 24pt of
    /// clearance to spare. Two things still hold from the argument that proposal was
    /// making, and they are the reason it was never applied: the surface size is what
    /// `beamSeamOffset` is a function of, so moving `cardWidth - cardInset * 2`
    /// obliges a re-probe of a constant that has to be exact to a ten-thousandth;
    /// and the drawn surface is 236 × 216 in both directions of that arithmetic.
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

    /// The comet's **core**: the crisp line at the centre of the light, stroked
    /// *centred on the rim* so half of it lands on the Card's glass and half of it
    /// outside.
    ///
    /// **2pt, and it is now the stroke width itself — `beamStrokeWidth` is deleted
    /// rather than kept at a doubling.** The whole beam used to be masked to one
    /// side of the rim, so a `.stroke` had to be twice as wide as the line anybody
    /// would see. The core is **unmasked** now, and that is the sixth pass's
    /// central decision: 1pt of it lies in `[rim - 1, rim]`, which is precisely the
    /// band `CardSurface`'s own `strokeBorder` hairline occupies, and 1pt of it lies
    /// in `[rim, rim + 1]`, outside.
    ///
    /// **Why straddling rather than one side or the other**, which is the choice the
    /// last two passes each got half right. Masked *outward* the core's visibility
    /// was staked entirely on the desktop, and in dark appearance over a white
    /// wallpaper it measured Δ10/442 — the bug that cost four passes. Masked
    /// *inward* it read Δ87 there but the halo had nowhere to go except over the
    /// Card's own content, which is the version the user rejected on sight ("it
    /// shouldn't be inside because that looks ass"). Centred on the rim, the inner
    /// half always composites against Liquid Glass with a known polarity, so the
    /// **line cannot disappear whatever the wallpaper is**, and the outer half is
    /// free light on top of that. The floor is the inward figure by construction:
    /// the inward pixel row is the same pixel row it was.
    ///
    /// The old objection to spill — that it makes the line's *width* wallpaper-
    /// dependent, 2pt over a dark desktop and 1pt over a bright one — is what the
    /// **colour** answers, and that link is the load-bearing sentence of this pass.
    /// A near-white core over a near-white sky has no outer half. A light blue has
    /// distance from every ground there is: Δ152 from white, Δ135 from mid-grey,
    /// Δ307 from near-black. See `Palette.beamHead`.
    ///
    /// It was 3.5 when the beam was a bar, and 1pt visible while it was masked. A
    /// comet is a light *source* travelling the rim, and a 3.5pt core with a blurred
    /// tail behind it reads as a fat smear; 2pt centred reads as one crisp line
    /// sitting on the border, which is what the reference material shows.
    ///
    /// **1.5 since 2026-09-02, with the smoke repaint.** The whole beam was "too
    /// thick" against the reference, whose line is a hairline with breath around it,
    /// and the core is where thickness reads first.
    ///
    /// **Bounded: this must stay ≤ 2 × `hairline`.** Since the same day's second
    /// instruction — "the beam should never go inside of the card, it should at max
    /// hit the edge" — the inner half of the core is the only light that touches the
    /// Card at all, and it is allowed to because it lies inside the Card's own 1pt
    /// rim: the border lights up, nothing behind it does. At 1.5 the inner half is
    /// 0.75pt, inside the hairline; at 2.5 it would cross it.
    /// `nothingIsLitInsideTheRim` is the check.
    static let beamWidth: CGFloat = 1.5

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
    static let beamCoreTailBlur: CGFloat = 3

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
    static let beamCoreHeadBlur: CGFloat = 1.0

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
    /// **The halo's outward reach ceiling, in points — a bound the tests hold, not a
    /// mask.** It was the inward band's width for one day (12, then 16 so the
    /// plume's own edge and not the mask's was what showed). Since the smoke moved
    /// outside there is no mask on its reach — `BorderBeam.outward` cuts at the rim
    /// and stops nothing beyond it — so this is where the head's light must have
    /// fallen to nothing (`theHeadHasAHaloAndACrispCore`), and the plume's furthest
    /// reach (`beamGlowBodyWidth` × `beamSmokeSpread`'s maximum, about 12pt, plus
    /// blur) is what it has to clear. The gutter between Cards is 48pt.
    static let beamGlowWidth: CGFloat = 16

    /// **Since 2026-09-01 the glow is INSIDE the rim, and `beamGlowWidth` is how far
    /// in it reaches.** Six passes and the aurora repaint all drew the halo outside
    /// the rim, on the gutter and the desktop, and on screen it read as "a drop
    /// shadow, which looks really bad" — which is exactly what a blurred coloured
    /// band outside a surface *is*: the same shape and offset as the Card's own
    /// shadow, in colour. Light in glass does the opposite: it is brightest at the
    /// edge and bleeds *across the surface*, refracted by the material. So the glow
    /// stroke is now centred on the rim and masked to the band inside it
    /// (`BorderBeam.inward`), the bloom sits under the same mask, and what remains
    /// outside is a thin **feather** (`beamFeatherWidth`) so the rim reads as lit on
    /// both sides rather than cut off. Pass five's inward halo failed because it was
    /// near-white, wide, and over the content; this is saturated, bounded at
    /// `beamGlowWidth`, and `Style.padding` plus the content's own inset keep it off
    /// the icon and the name. `nothingIsLitDeepInsideTheRim` is the bound.

    /// What is handed to the glow's `StrokeStyle`: double, because the glow **is**
    /// masked — outward — and a `.stroke` is centred on its path, so the mask keeps
    /// half of it.
    ///
    /// The core is not doubled and has no mask: it is narrow enough to live inside
    /// the Card's hairline rim (`beamWidth`). The halo is outside the Card, the line
    /// is on its edge.
    static var beamGlowStrokeWidth: CGFloat { beamGlowBodyWidth * 2 }

    // MARK: The glow, tight

    /// The glow's reach **outside** the rim, in points, before its blur. **3**, and
    /// constant along the whole comet.
    ///
    /// **This is the Tuna beam and nothing else (2026-09-02, third instruction of the
    /// day).** The reference is a hairline on the rim that lights up and fades along
    /// the edge, with a soft breath of light hugging the line a few points out — no
    /// plume, no nucleus, no colour, nothing that drifts. The smoke model that
    /// preceded it for a few hours (an expanding, turbulent, dissipating plume, then
    /// moved outside the rim) read on screen as "a tail thing … looks ass": a green
    /// wisp floating off the corner, detached from the line it was meant to belong to.
    /// The lesson is the one the file header already has in six other forms: **the
    /// light belongs to the line**. The glow is therefore a constant-width stroke
    /// whose only variation along the comet is the same fade the core has, so it
    /// cannot separate from the core anywhere.
    static let beamGlowBodyWidth: CGFloat = 3

    /// **The nose.** How much of the comet's length, ahead of its brightest point,
    /// the light takes to build up: 0 at the head point, full from `beamNoseFraction`
    /// behind it, as a smoothstep. Without it the leading slice is a butt-capped
    /// stroke at full alpha, and however small the blur the front reads as a bar's
    /// end — the oldest complaint about this beam. 0.08 of the comet is about 35pt.
    /// The core takes half of it, the glow all of it, so the line leads the light.
    static let beamNoseFraction: Double = 0.08

    static func beamNose(at position: Double) -> Double {
        let x = min(max((1 - position) / beamNoseFraction, 0), 1)
        return x * x * (3 - 2 * x)
    }

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
    /// **3.5 with the smoke: the head is the source, and a source is compact.** It
    /// was 14 while the halo was a wide outward bloom and 6 while it was the liquid
    /// band. Smoke that has just left the head has not diffused yet; the blur ramps
    /// up behind it (`beamGlowTailBlur`) and that ramp *is* the diffusion. Any lower
    /// and the head's slices show their edges again; the nose (`beamNose`) is what
    /// keeps the front soft at this radius, not the blur.
    static let beamGlowHeadBlur: CGFloat = 2.5

    /// The glow's blur radius at the very end of the tail.
    ///
    /// **The ceiling is the gutter between two Card surfaces again — `cardInset * 2`
    /// = 48pt — and it is load-bearing again.** The fifth pass masked the beam
    /// inward and the bound briefly became the Card's own interior; the sixth put
    /// the halo back outside, so what it must not do is reach a neighbouring Card's
    /// rim. Measured, the total reach is **40pt** at 24 — against 34 at 22 — and the
    /// clearance is 8pt. That is the number that stops this going any higher, and it
    /// is why `cardInset` stays at 24.
    ///
    /// It ramps *up* from `beamGlowHeadBlur` toward the tail, so the halo widens
    /// and thins as it trails — which is the tail dissolving without the glow
    /// ever going out.
    ///
    /// Raise this and re-measure the reach against the gutter rather than assuming
    /// it scales with the radius: the reach is where alpha falls under 8, and the
    /// glow's opacity ramp moves it as much as the blur does.
    ///
    /// **8 with the smoke — down from 10, then 12 — because diffusion has to leave
    /// the wisps something to be.** At 12 the turbulence in width and density was
    /// smeared into a smooth band by the far end of the tail and the plume read as a
    /// gradient again. 8 is where a wisp 55pt long still has an edge at age 0.7.
    static let beamGlowTailBlur: CGFloat = 5

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
    /// **1.4, then 2.4, and now 1.25 — and the round trip is not indecision, it is
    /// two different complaints about the same dial.** 2.4 was the answer to "the
    /// opacity of the start should be less so that it just looks more misty", which
    /// is a statement about the *tail*. 1.25 is the answer to "not just a dot that
    /// has a radial glow … spread it more out", which is a statement about the
    /// *length*, and it is the opposite direction on the same exponent. What makes
    /// them compatible rather than a loop is that the tail's own alpha came down
    /// with the first change and stayed down: `position^ramp` multiplies
    /// `beamGlowTail`, so the far end is quiet at 1.25 now in a way it was not at
    /// 1.4 then.
    ///
    /// Intensity by position — this is the whole of the "dot versus streak"
    /// argument, and it is arithmetic before it is a render:
    ///
    /// | position | 1 (head) | 0.75 | 0.5 | 0.25 |
    /// |---|---|---|---|---|
    /// | at 2.4 | 1.00 | 0.50 | 0.19 | 0.036 |
    /// | at 1.25 | 1.00 | 0.70 | 0.42 | 0.177 |
    /// | at 1.5 | 1.00 | 0.65 | 0.35 | 0.125 |
    /// | at 1.8 | 1.00 | 0.60 | 0.29 | 0.082 |
    ///
    /// **1.8 with the liquid wave.** The wave swells the glow's width by up to 42%
    /// at points along the tail, and `theGlowPeaksAtTheHeadAndDiesAtTheTail` now
    /// takes the *peak* across the band's depth so it is not fooled by a trough —
    /// which means a swell in the tail counts fully. At 1.5 that read 152 at the
    /// head against 41 at 280pt behind, 3.7×, under the 4× floor. 1.8 is the step
    /// that clears it; the visible comet is still about 250pt of the 433 stroked.
    ///
    /// **1.5 since 2026-09-01, and it moved with `beamTailFraction`, not on its own.**
    /// The lit segment went 0.35 → 0.50 of the perimeter (303pt → 433pt), so the
    /// same exponent put the 280pt-behind sample at position 0.35 instead of 0.08,
    /// and `theGlowPeaksAtTheHeadAndDiesAtTheTail` read head 139 against furthest 35:
    /// 3.97×, a hair under its 4× floor, which is the tube beginning. A longer tail
    /// has to fall faster per point to stay a comet; 1.5 is the smallest step that
    /// clears the floor with margin. The exponent and the fraction are one dial
    /// with two ends — change one, re-check the other.
    ///
    /// At 2.4 more than half the stroked segment was effectively unlit and the
    /// visible comet was about 150pt of the 303 that is stroked; at 1.25 it is about
    /// 260pt. **The invariant is that it still peaks at the head and falls
    /// monotonically** — a flat profile is the glowing tube this exponent was
    /// introduced to kill, and it is the failure mode to watch when lowering it.
    /// Measured 4pt outside the rim, at the head and 15/30/60/90pt behind it, the
    /// profile went **112 / 80 / 62 / 48 / 35** at 2.4 to **149 / 130 / 111 / 84 /
    /// 63** at 1.25, with head-to-far 8.9× → 5.0×. Below about 1 the ratio stops
    /// clearing `BorderBeamRenderTests`'s 4× floor and the thing becomes a hose.
    ///
    /// **Why this is not `beamFalloff` coming back.** That exponent existed to
    /// undo a *linear* opacity ramp (1/20, 2/20, …) applied to the **only layer
    /// there was**, over colours already carrying alpha, which left 40pt of an
    /// intended 336pt on screen and made the beam invisible. Three things differ,
    /// and all three matter. There is now a separate crisp core carrying the
    /// beam's visibility, so the glow is *allowed* to fall to nothing — it is the
    /// bloom, not the beam. The ramp is deliberately shaped rather than
    /// accidentally steep. And it is measured across the beam as well as along it,
    /// which is the measurement the first pass never took.
    ///
    /// **The exponent is not the whole of the mist, and moving it alone is the wrong
    /// half in either direction.** The trailing end of the *glow* is zero at any
    /// exponent — `position^ramp` is 0 at position 0 — so what is actually visible at
    /// the start of the beam is the **core**'s trailing colour, blurred by
    /// `beamCoreTailBlur`. Measured at the trailing terminus, alpha 1pt out only
    /// moved 22 → 14 when `beamTail`'s own alpha came down 0.70 → 0.42. This
    /// exponent sets the *body* of the tail; `beamTail`'s alpha sets its end.
    ///
    /// **1.5 for the Tuna beam (2026-09-02).** The reference's light fades a long
    /// way along the edge; steeper made a short bright bit and a dead rim, and 1.2
    /// left the far tail at 29 against a head of 98, under the 4× floor; 1.4 sat
    /// exactly on it. Smoke
    /// lingers: with the width expanding and the density modulated along the tail,
    /// a steeper exponent left nothing behind the first third for the wisps to be
    /// made of, and `theGlowPeaksAtTheHeadAndDiesAtTheTail` clears its 4× floor at
    /// 1.5 because the tail is now *wide and faint* rather than narrow and faint —
    /// the peak-inward measure reads the wisp's crest and the head is far brighter
    /// than any crest.
    static let beamGlowRamp: Double = 1.5

    /// The glow's opacity multiplier for a slice at `position`.
    ///
    /// The core has no equivalent and must not get one: the core *is* the beam,
    /// and the reason a ramp is safe here is that something else is carrying
    /// visibility. See `beamGlowRamp`.
    static func beamGlowIntensity(at position: Double) -> Double {
        pow(min(max(position, 0), 1), beamGlowRamp)
    }

    /// How far past the layer's own bounds the outward mask reaches.
    ///
    /// **Deleted by the fifth pass and back with the sixth, and it is not
    /// optional.** `BorderBeam.outward` is a `Rectangle` with the Card's shape
    /// punched out of it, and a `Rectangle` in an overlay is laid out at the
    /// *content's* size — which is the Card. The halo is drawn well outside that, so
    /// a mask stopping at the bounds clips the glow and the bloom into a hard square
    /// edge along all four sides. That artefact is documented from the second pass
    /// and there is no reason to rediscover it. While the mask was `cardShape`
    /// itself — a region entirely *inside* the bounds — there was no boundary to
    /// overrun and the constant was correctly deleted; going back outward brings the
    /// boundary back.
    ///
    /// Derived rather than chosen, so that raising a blur or the bloom cannot start
    /// clipping: three times the widest blur plus the glow's own stroke width, or the
    /// bloom's longest axis, whichever is larger. Three times a Gaussian's radius is
    /// past where it has anything left. Two instead of three measured no differently
    /// (1.40ms against 1.43 in an older harness, inside the noise) and is not worth
    /// the margin.
    static var beamMaskOutset: CGFloat {
        beamGlowTailBlur * 3 + beamGlowStrokeWidth
    }

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

    // MARK: - The beam's colour

    /// The light is `Palette.beamLight`, and it is **white** — because the reference
    /// is white (2026-09-02). The aurora ramp (teal, green, violet, pink) chosen on
    /// 2026-09-01 is deleted with the smoke it coloured: the reference's rim light
    /// has no hue, and a coloured tail was the thing that read as detached from the
    /// line. The *core* is pure white in both appearances. The glow is near-white in
    /// dark appearance and faintly cool in light — see `Palette.beamLight` for the
    /// one reason.

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
    static let beamTailFraction: CGFloat = 0.50

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
    ///
    /// **28 since the smoke repaint, from 20.** The turbulence's shortest wisp is
    /// about 55pt of a 433pt comet; at 20 slices (22pt each) it was two steps and
    /// read as banding, at 28 (15pt) it is three to four and reads as a wisp. Cost
    /// is three layers × 28 blurred strokes per sweeping Card, and only a sweeping
    /// Card pays it.
    static let beamSegments: Int = 28

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
/// **There is no accent colour here, deliberately.** Focus is signalled by the
/// Lamp's weight and the rim's weight; selection by a neutral lift. An accent
/// fill across a whole Card turned the Panel into a coloured box, and a tinted
/// selection fought every app icon it sat next to.
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

    /// The **Lamp**: the static light along the top of a Card's rim, at the
    /// weight the focused Card carries. White in both appearances — it is light,
    /// and light does not flip polarity with the tint.
    ///
    /// This replaces the focused Card's brighter *fill* (`highlight`, deleted).
    /// The fill was propping up what the rim could not carry: with a Lamp on the
    /// rim, a lifted fill underneath it was two focus signals saying the same
    /// thing, and the fill was the one that turned the Card into a lighter grey
    /// box. Focus is now the Lamp's weight and the base rim's weight, nothing
    /// else.
    ///
    /// **This is the "fixed lamp" that was declined on 2026-08-22 and reopened on
    /// 2026-09-01.** The decline was made while the Border Beam was expected to
    /// carry the reference's look alone; the reopening is the finding that it
    /// cannot. The ban `CONTEXT.md` records is on a static *accent colour*, and a
    /// monochrome light is not one.
    let lamp: Color

    /// The Lamp on an unfocused Card: turned down, never off. An unlit Card
    /// beside a lit one reads as switched off rather than as not selected.
    let lampDim: Color

    /// The specular wash behind the glass across a Card's top. Sits *behind* the
    /// glass, as `highlight` did, so the material carries it and nothing washes
    /// over the Card's content. Alpha is higher than it looks like it needs to be
    /// because translucent glass eats most of it.
    let specular: Color

    /// The inner shadow behind the glass along a Card's bottom. Black in both
    /// appearances, like `shadow`, and for the same reason.
    let innerShadow: Color

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

    /// The Border Beam's **weights** — alphas only. Its **colours** are not in the
    /// Palette at all: since 2026-09-01 the beam is a *hue ramp* along its own
    /// length, `Style.beamHue(at:)`, the same in both appearances, and a Palette
    /// is where light and dark diverge.
    ///
    /// The record of how the colour got here is worth keeping in one paragraph.
    /// It was near-white and vanished over a bright wallpaper (Δ10/442, pass five),
    /// because outside the rim is the desktop. It became one light blue, chosen
    /// for distance from both a white sky and a dark desktop. Then a white core on
    /// a blue halo, the comet's natural order. On screen over a light desktop in
    /// light appearance that read as "the blue does not do the job": a single
    /// pastel has one distance from the ground, and a light ground eats it. A ramp
    /// through several saturated hues always has *some* stop far from any ground,
    /// which is the aurora / Apple Intelligence look asked for by name — and it is
    /// spatial, per slice, along arc length: not a conic gradient, which ADR 0003
    /// bans for racing the long edges, and not a gradient in a stroke, which does
    /// not follow a path. The slices were always the way to do this.
    ///
    /// The core's leading edge is still white. `theCoreIsWhiteHot` bounds it.
    let beamGlowHeadAlpha: Double
    let beamGlowTailAlpha: Double
    /// The core's alpha at its trailing end; it is 1 at the head.
    let beamCoreTailAlpha: Double

    /// The glow's colour. **Near-white in dark appearance, a faint cool white in
    /// light**, and the split exists for exactly one reason: the glow is outside the
    /// rim, so over a white desktop in light appearance a white glow is nothing —
    /// the Δ10 finding, accepted rather than fought for the *core*, which lights the
    /// rim itself from `cardRim` to white and is what the eye tracks. The glow needs
    /// a little distance from white to be a breath at all there; this is the least
    /// tint that clears `theBeamReadsAgainstAWhiteDesktop`'s floor and it is far
    /// from the saturated blue that was rejected twice.
    let beamLight: Color

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
        // Dark appearance has contrast for free, so the Lamp can be a real light
        // catch without the Card reading as lighter than the Slab: it is on the
        // rim, not in the fill. The specular is faint for the reason `highlight`
        // used to be — a wash that lifts the whole top of a dark Card takes white
        // text back towards unreadable.
        lamp: .white.opacity(0.72),
        lampDim: .white.opacity(0.30),
        specular: .white.opacity(0.14),
        innerShadow: .black.opacity(0.24),
        writingLift: 0.14,
        slabRim: .white.opacity(0.10),
        cardRim: .white.opacity(0.12),
        raisedRim: .white.opacity(0.38),
        selectionFill: .white.opacity(0.13),
        chipFill: .white.opacity(0.09),
        chipRim: .white.opacity(0.10),
        shadow: .black.opacity(0.44),
        // The Border Beam's five colours are the **same in both appearances**, which
        // is new with the sixth pass and is the whole of what makes an outward beam
        // viable. See `beamHead`. They are declared in both tables rather than
        // hoisted out of `Palette` because a colour belongs to a palette here, and a
        // future pass that has to split them again should not have to move them
        // back in first.
        beamGlowHeadAlpha: 0.85,
        beamGlowTailAlpha: 0.12,
        beamCoreTailAlpha: 0.20,
        beamLight: Color(red: 0.94, green: 0.98, blue: 1.0)
    )

    static let light = Palette(
        tint: .white,
        base: 0.15,
        // A white Lamp over a light Card is nearly invisible against a light
        // desktop, and that is accepted rather than fought: in light appearance
        // the top edge *dissolving* into the light is the lamp, and the darker
        // base rim at the bottom is what defines the edge. The specular does the
        // rest of the work here, which is why it is four times dark's.
        lamp: .white.opacity(0.95),
        lampDim: .white.opacity(0.55),
        specular: .white.opacity(0.55),
        innerShadow: .black.opacity(0.07),
        writingLift: 0.18,
        slabRim: .black.opacity(0.08),
        cardRim: .black.opacity(0.10),
        raisedRim: .black.opacity(0.16),
        selectionFill: .black.opacity(0.07),
        chipFill: .white.opacity(0.62),
        chipRim: .black.opacity(0.07),
        shadow: .black.opacity(0.20),
        // Identical to dark's, and that is the point — see `beamHead`. The polarity
        // flip that used to live here (a dark cool line, because a light Card is
        // lighter than any highlight) belonged to the inward mask and is deleted with
        // it. Outside the rim there is no such ceiling, and a light blue is far from
        // a light desktop as well as a dark one.
        beamGlowHeadAlpha: 0.85,
        beamGlowTailAlpha: 0.12,
        beamCoreTailAlpha: 0.20,
        beamLight: Color(red: 0.62, green: 0.80, blue: 1.0)
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
        let lamp = focused ? palette.lamp : palette.lampDim
        return content
            .glassEffect(glass(fill), in: Style.cardShape)
            // Depth sits *behind* the glass, so the material carries it and the
            // Card's own content is not washed over. Never by tinting the glass
            // instead: the tint's polarity flips between appearances and would
            // dim the Card in dark mode. Both are static and monochrome — see the
            // file header for why they exist and `Palette.lamp` for why the
            // focused Card's brighter fill does not any more.
            .background {
                Style.cardShape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: palette.specular, location: 0),
                            .init(color: palette.specular.opacity(0), location: Style.specularReach)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
            .background {
                Style.cardShape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: palette.innerShadow.opacity(0), location: Style.innerShadowStart),
                            .init(
                                color: palette.innerShadow.opacity(Style.innerShadowMid),
                                location: Style.innerShadowStart + (1 - Style.innerShadowStart) * 0.55
                            ),
                            .init(color: palette.innerShadow, location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
            .clipShape(Style.cardShape)
            // The base rim first, uniform, then the Lamp over it: a second
            // hairline whose light is full at the top edge and gone by
            // `lampReach`. Two strokes rather than one gradient so the bottom
            // edge is always defined by the base rim whatever the Lamp does —
            // a single gradient from light to nothing left the bottom edge
            // undrawn against a matching ground.
            .overlay {
                Style.cardShape.strokeBorder(rim, lineWidth: Style.hairline)
            }
            .overlay {
                Style.cardShape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: lamp, location: 0),
                            .init(color: lamp.opacity(0), location: Style.lampReach)
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: Style.hairline
                )
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
        // The glow's ramp — the *only* computed ramp in the beam — times the nose.
        // See `Style.beamGlowRamp` for why it is safe here and was not safe as
        // `beamFalloff`.
        case .glow: palette.beamLight
            .opacity(
                (palette.beamGlowTailAlpha
                    + (palette.beamGlowHeadAlpha - palette.beamGlowTailAlpha) * position)
                    * Style.beamGlowIntensity(at: position)
                    * Style.beamNose(at: position)
            )
        // White, fading along the tail, and half the nose at the front: the line
        // is the one thing that may reach the head point, but it arrives at half
        // strength so its front is not the beam's front.
        case .core: Color.white
            .opacity(
                (palette.beamCoreTailAlpha + (1 - palette.beamCoreTailAlpha) * position)
                    * (0.5 + 0.5 * Style.beamNose(at: position))
            )
        }
        let width = switch layer {
        // The glow's is doubled because the glow is masked outward and a `.stroke`
        // is centred on its path; the core's is not, because the core is unmasked
        // and lives inside the hairline. See `Style.beamWidth`.
        case .glow: Style.beamGlowStrokeWidth
        case .core: Style.beamWidth
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
