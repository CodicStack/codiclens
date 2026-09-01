# Codiclens

macOS Spotlight-replacement launcher built with Swift, SwiftUI, and AppKit.

## Build

```bash
xcodebuild -project codiclens.xcodeproj -scheme codiclens -configuration Debug build
```

## Regenerating the emoji index

`codiclens/emoji-index.json` and `codiclens/emoji-data-license.txt` are generated,
not hand-edited. Rebuild them from the repository root:

```bash
swift Scripts/generate-emoji-index.swift
```

It downloads Unicode `emoji-test.txt` and both CLDR annotation files, joins them,
and reports the row count. Expect **1,914 rows, 2,030 skin-tone variants across
330 bases, 0 rows missing keywords** — it exits non-zero if any row comes out
keyword-less or any variant cannot be filed under a base. `--unicode` and
`--cldr` bump the versions; `--cache <dir>` reuses downloads. See
`docs/adr/0005-bundled-emoji-dataset.md`.

## Project Structure

```
codiclens/           # Main app source (Swift)
codiclensTests/      # Unit tests
Codiclens.app/       # Built app bundle
```

There are two targets, app and unit tests. There is no UI test target.
`codiclens/` is a `PBXFileSystemSynchronizedRootGroup`, so a new `.swift` file
needs no `project.pbxproj` edit.

## Rules

- No backwards compatibility hacks. Always migrate to the new solution.
- No timing hacks (asyncAfter, sleep, usleep) as bug fixes. Use event-driven or sequential solutions.
- FloatingPanel uses `.nonactivatingPanel` — never break this contract without restoring previous app focus.
- App scanning must be recursive to find apps in subdirectories (e.g., Adobe apps).
- `NSWorkspace.shared.open()` calls must be async (use `openAsync` helper) to avoid blocking the main thread.

### Visual layer

- **`Style.swift` owns every radius, material, tint and rim.** No view outside it holds
  one, and no view outside it branches on `colorScheme`.
- **A Card is native Liquid Glass plus three static, monochrome overlays, and the
  Lamp is one of them.** `CardSurface` layers a specular wash (top, behind the
  glass), an inner shadow (bottom, behind the glass) and the **Lamp** — a second
  hairline on the rim, full at the top edge, gone by `Style.lampReach` — over
  `.glassEffect`. Focus is the Lamp's weight plus the base rim's weight; the
  focused Card's brighter *fill* (`Palette.highlight`) is deleted, do not bring it
  back as a second focus signal. The Lamp was declined on 2026-08-22 and
  reopened on 2026-09-01: the decline assumed the Border Beam could carry the
  reference's look alone, and six passes showed it could not. ADR 0002 bans a
  hand-rolled *blur*, not light on top of the native material. The Slab gets none
  of the three — it is the tray, the Cards are the objects.
- **`Motion.swift` owns every curve, in two categories.** A **Transition** carries
  a change the user caused, and there are exactly three — `entrance`, `resize`,
  `snappy` — used only by the Panel appearing, the Panel dismissing and a surface
  resizing. Phase advances, Card content swaps and selection movement are
  instant *on purpose*: an animated highlight lags the keypress. A window frame
  change needs `Motion.resizeDuration` / `Motion.resizeTimingFunction`, because
  `NSAnimationContext` cannot take a SwiftUI `Animation`.
  **Decoration** is the second category — `beamSweep` and `ringSpin` — and it is a
  category rather than two more curves: the budget was never "three is the number",
  it was *do not animate information*. A decoration carries nothing learnable,
  delays nothing, is never given a threshold before it appears, and is **absent**
  under Reduce Motion rather than collapsed (it reads `Motion.isReduced` directly,
  because `collapsed(_:)` makes a cross-fade and a loop has nothing to cross-fade
  to). The next animation that "just needs to show that something is happening" is
  a transition wearing decoration's clothes and goes through the three curves. See
  `docs/adr/0003-motion-budget.md`.
  **`Motion.swift` also owns the app's only two AppKit accessibility reads, and
  they are independent.** `isReduced` is Reduce Motion plus the app's own
  animations preference, and its answer is that a decoration is absent.
  `isTransparencyReduced` is Reduce Transparency, which is a claim about
  legibility rather than about movement — Apple asks for opaque content over
  semi-transparent, and a blur is semi-transparent — and its answer is that the
  Border Beam **drops its halo (the glow layer *and* the head bloom) and keeps
  sweeping**. Do not fold the second
  into the first or give `isReduced` a second meaning: with Reduce Motion on there
  is no beam at all, with only Reduce Transparency on there is a beam with no halo,
  and neither switch implies the other. `Style.beamDrawsGlow` consults
  `Motion.isTransparencyReduced` rather than reading `NSWorkspace` itself, so both
  reads stay in the one file. The halo goes **whole**, not un-blurred — that was
  the answer while the beam was one layer, and un-blurring a `beamGlowWidth`-wide
  band is a flat 10pt bar travelling the rim rather than a quieter halo. There is
  no un-blurred version of a `RadialGradient` disc at all, which is a second
  reason the bloom goes with it rather than being turned down.
- **The Border Beam belongs to a *Card* and means nothing.** It sweeps around
  a Card that becomes about something new — `cardBeam(identity:)` on all three,
  applied *between* `.cardSurface(...)` and `.padding(Style.cardInset)`, because
  the padding sits outside the surface and a beam applied after it draws on the
  wrong bounds. `CardBeam` is the policy, `borderBeam(trigger:)` the primitive;
  keep them apart. It is **not** tied to OCR, to `isOCRInFlight`, to searching, or
  to any in-flight state; that misreading is the way this feature gets broken —
  OCR Text sweeps the Subject Card because the *Subject was replaced*, and nothing
  in `BorderBeam.swift` reads an in-flight flag.
  **The trigger is a pure function of coordinator state — `CardBeamIdentity` —
  and its hard rule is that a moving *selection* must never change a token.**
  Arrowing through Results, re-ranking on a keystroke, and `mdfind` filling in
  Targets all have to leave the tokens alone, or the Panel strobes; `AGENTS.md`
  and ADR 0003 both say selection movement is instant on purpose.
  `CardBeamIdentityTests` has eight negative cases pinning that, and they are the
  half of the suite that matters. One trap in particular: `moveUp`/`moveDown`
  **clear** `selectedSubject` while the Clipboard is browsed, so a token that read
  it in a browsing Phase would sweep on the first arrow key after Enter —
  `previewsASelection` is the gate that stops it.
  A token cannot tell an arrival from a departure, so `ActionCard.holdsKeyboard`
  changes on the way out too: Tab from Action to Target sweeps both Cards. That is
  the one unasked-for sweep here, and it is the price of the trigger being pure —
  the alternative silently loses the Shift+Tab-back sweep.
  `CardBeam` keeps an unconditional `onAppear` bump as well as `onChange`, because
  `CardContainerView` inserts the Action and Target Cards on `cardCount`, so a
  fresh view's `@State` starts at 0 and its `onChange` never fires. That
  `onAppear` — not the old focus edge — is why the Action Card was the only one
  ever seen sweeping.
  **It was twice wrong before this, and neither was catchable by reading.** It was
  built on the Slab and triggered by the Slab arriving, which fires once per
  summon on the first keystroke and so was invisible in use; widening the trigger
  left the surface wrong. Do not move it back to the Slab, and do not narrow the
  trigger to arrival. A Card focused across a dismiss-and-resummon sees no
  false→true edge and no `onAppear`, so it does not sweep on that summon — known,
  documented on `CardBeam`, not a bug to fix twice.
  `Style.beamSeamOffset` is **exact** (0.6192), because every Card is one
  size — it was a compromise across the Slab's variable proportions. Probe it, do
  not compute it: the analytic `(1.5h + w) / 2(w + h)` happens to land within
  0.00025 at radius 22 and that is luck, not a method — it also landed within
  0.0002 at the *previous* surface size, and neither agreement was predictable.
  It is a function of the **drawn surface**, not of the Card's cell: it did not
  move when `cardInset` went 12 → 24, because `PanelLayout.cardWidth` and
  `cardHeight` went up by the same amount and the surface stayed 236 × 216.
  **Re-probe it whenever `cardRadius` moves, or whenever a change to `cardWidth`,
  `cardHeight` or `cardInset` moves `cardWidth - cardInset * 2` or
  `cardHeight - cardInset * 2`** — by sweeping `trim` and taking the fraction whose
  point is nearest the rect's top-left; at 236 × 216 that is 0.619221, landing at
  (6.41, 6.41), the 45° midpoint of the corner's own curve. Read the *first* point
  of `trimmedPath(from: f, to: f + ε)` — `currentPoint` on
  `trimmedPath(from: 0, to: f)` gives the sub-path's end and is `nil` at f = 0.
  **`BorderBeam.headPoint(in:at:)` reads a point off the rim the same way and is
  deliberately *not* exact.** `beamSeamOffset` has to be, because it decides where
  the beam enters the rim and an error there is a visible discontinuity every lap;
  the head bloom is a 96pt soft disc, so being a point or two along the rim from
  the core's tip is invisible. It is one `Path` build and one `trimmedPath` per
  frame with a plain `epsilon` and no refinement loop, and it must stay that cheap.
  It shares one stroke primitive with the
  Loading Ring — an animated `trim` along a stroked path — and nothing else.
  Two things the *stroke* must not become: a rotating **conic gradient**, which
  sweeps at a constant *angular* rate and so races a wide rectangle's long edges
  and crawls its corners; and a **stroke gradient**, which does not follow a path.
  A `RadialGradient` used as a **fill**, which is what the head bloom is, is
  neither of those and is fine. `trim` *is*
  uniform in path length — verified: `cardShape`'s path starts at the right edge's
  vertical midpoint and runs clockwise, which is why the top-left corner falls a
  little past 0.5.
- **THE HALO IS OUTSIDE THE RIM AND THE CORE STRADDLES IT, AND THE COLOUR IS WHY
  THAT IS ALLOWED.** For four passes the whole comet was masked *outside*
  `Style.cardShape`, on a rule that reads as obviously right — a blur spreads both
  ways, so cut the inward half and nothing washes over the Card's icon, name and
  chips. Outside a Card's rim is `cardInset`'s gutter and then `PanelLayout.margin`,
  and the Panel is a borderless, transparent, non-activating `NSPanel`: **outside the
  rim is the desktop.** So the effect's visibility was staked on a ground the app
  does not own, and a near-white beam over a bright hazy wallpaper measured
  **Δ10/442** against Δ270 over a near-black one. **"Dark appearance" does not mean
  "dark ground"** — the appearance sets the Card's tint and has nothing to do with
  the wallpaper — and **a measurement against a synthetic swatch is not a measurement
  against the real composite**. Both of those still hold, and together they are
  exactly **why the halo must be chromatic rather than near-white**: only a colour
  with real distance from a white sky *and* from a near-black desktop can be drawn
  outside the rim at all. That causal link is the load-bearing sentence here.
  **Since 2026-09-01 the core is white and the halo is a hue ramp** — `Style.beamHue(at:)`
  through `BeamPalette.current.hues`, head first, evaluated per slice so it follows
  arc length. This is *not* the conic gradient ADR 0003 bans (that races the long
  edges) and not a gradient in a stroke (that does not follow a path): the slices
  were always the way to do it. The beam's colours live in `BeamPalette`, not in
  `Palette`, because they are the same in both appearances. `beamPalette`
  (`UserDefaults`, `aurora` | `intelligence`) switches live while the choice is
  open. No near-white stop at the head of the ramp: the core is the white, and a
  white halo over a white desktop is the Δ10 failure again (measured Δ36 with one).
  The white core on a coloured halo is the comet's natural order and the reverse
  of what six passes did. The Δ10 near-white
  failure was a white core *alone* on the desktop; a white core on a blue glow is
  not alone, and `theCoreIsWhiteHot` plus `theBeamReadsAgainstAWhiteDesktop` are
  the pair that keep both halves honest. Do not fix a weak ground by making the
  core blue again — turn the *halo* up.
  **The halo also spills a few points onto the Card's glass** — `BeamLayer.spill`,
  under `BorderBeam.inward`, a `Style.beamSpillWidth` band inside the rim. This is
  not pass five returning: pass five put the *whole* halo inward and over the
  content; the spill is a 6pt band and `Style.padding` is 12.
  **`beamLoop`** — a `UserDefaults` key, no UI — makes every Card sweep on a fixed
  period so the beam can be judged live. It ships inert.
  The fifth pass answered the Δ10 by masking everything **inward**, onto the Card's
  own glass. That fixed the number and was rejected on sight — the halo over the
  Card's content "looks ass" — with the glow wanted outside, bigger, blue, and the
  rim line kept. So now: **glow and bloom masked outward (`BorderBeam.outward`), core
  unmasked and centred on the rim.** `Style.beamWidth` is 2 and is the stroke width
  itself, so 1pt lies inside the rim — the band `CardSurface`'s own `strokeBorder`
  occupies, which is what lights the *border* rather than drawing a second line — and
  1pt lies outside. `beamStrokeWidth` is deleted; only the glow still doubles.
  The old argument for **no outward spill** — that it makes the line's *width*
  wallpaper-dependent — is what the chromatic colour answers, and it is deleted
  rather than qualified. The inward half is the part no wallpaper can take away, and
  it is the floor: Δ46/49 on its own, Δ83/86 with the outward half over a white
  desktop, against Δ74/174 masked inward and Δ17/89 masked outward and near-white.
  `BorderBeamRenderTests.theBeamReadsAgainstAWhiteDesktop` is that as an inequality
  and it is the most important test in the file.
  `Style.beamMaskOutset` is **back**, derived as
  `max(beamGlowTailBlur * 3 + beamGlowStrokeWidth, beamBloomLength)`: an overlay's
  mask is laid out at the content's size, so a mask stopping at the bounds clips the
  halo into a hard square edge. It was correctly deleted while the mask was
  `cardShape` — a region inside the bounds has no boundary to overrun — and going
  outward brings the boundary back.
  `cardInset` stays **24** and the gutter is load-bearing again: the halo must not
  reach a neighbouring Card's rim, 48pt away, and the measured reach is 37pt. The
  fifth pass's written-up proposal to take it back to 12 is deleted.
- **The beam is a *comet* in THREE parts: a radial bloom at the head, a glow that
  peaks under it and dies away behind, and a crisp core on top.** This is the
  shape of the thing and the part most likely to be "simplified" back into a bug.
  Each part exists because the version without it was rejected on screen, and the
  three rejections are the most useful thing in this file:
  **One layer cannot do it.** A slice has one blur radius, so a crisp line and a
  bloom around it are two strokes or they are nothing. It shipped as one layer
  once, with the core's blur "exactly 0 at the head, because the crisp leading
  edge against a dissolving tail is the entire contrast the comet lives on" — a
  sentence that reads like taste and was architecture. Measured on the real
  modifier, that version put **zero** light more than 1pt outside the rim at the
  head. Do not merge the layers.
  **A stroke at constant opacity is a tube.** The two-layer version ran the glow
  at flat opacity down the whole 303pt segment, on an explicit rule that blur
  alone should carry the falloff. Rasterised 4pt outside the rim it read
  **92 at the head, 100 sixty points behind it, 91 at 180 and 62 at 280** — the
  near-rim alpha *rose* behind the head and then went flat for 200pt. Nothing
  peaked anywhere, so there was no point for the light to be coming from, and the
  answer was "it should be more like a single area/point that a radial blue kinda
  goes out from … less dense". `Style.beamGlowRamp` (**1.25**) is a per-slice opacity
  ramp, `position^ramp`, and it is **the glow's alone**. It went 1.4 → 2.4 for
  "misty" and **2.4 → 1.25** for "spread it more out" — the opposite direction on
  the same dial, and compatible because `beamTail`'s own alpha came down with the
  first change and stayed down, so the far end is quiet at 1.25 now in a way it was
  not at 1.4 then. Measured 4pt out, head and 15/30/60/90 behind: 112/80/62/48/35 at
  2.4, **115/96/79/54/42** at 1.25. Below about 1 the head-to-far ratio stops
  clearing the render test's 4× floor and it becomes a hose again.
  **A lit line is not a light source, however carefully it is ramped.** The head
  is `BeamBloom`, and it is an **ellipse** — `Style.beamBloomLength` (168) *along*
  the rim by `beamBloomThickness` (96) across it, an `EllipticalGradient` rotated
  onto the rim's own tangent at the head by `BorderBeam.head(in:at:)`. It was a
  96pt circle for two passes, and **a circle centred on a line is a dot on that
  line**: "not just a dot that has a radial glow … spread it more out". All of the
  growth went along the rim and none across it, because the gutter bounds the
  across axis and nothing bounds the along axis. A gradient has no edges in any
  direction by construction, which is what makes the head's terminus stop existing
  rather than merely soften. `EllipticalGradient` rather than a `RadialGradient` in
  a stretched frame: only the former takes its radii from the frame. A gradient
  used as a **fill** is not the stroke gradient this file twice refused: an
  `AngularGradient` in a stroke sweeps at a constant *angular* rate and races a
  rectangle's long edges, and a `LinearGradient` in a stroke does not follow a
  path at all. This one follows nothing; it is an ellipse at a point.
  **`Style.beamFalloff` is still deleted and the ramp above is not it coming
  back**, and the distinction is load-bearing. `beamFalloff` was an exponent
  invented to undo a *linear* opacity ramp (1/20, 2/20, …) applied to the **only
  layer there was**, over colours already carrying alpha; it left 40pt of an
  intended 336pt on screen. The glow's ramp is safe for three reasons that must
  all stay true: a separate crisp core carries the beam's visibility, so the glow
  is *allowed* to fall to nothing; killing the trailing fifth is the **point**,
  because a stroke that fades out before its own cap has no cap to see; and it
  was measured both along the beam and across it. If the core ever loses its own
  visibility, this ramp becomes that bug again.
  **Core:** `Style.beamWidth` 2, the stroke width itself, **unmasked and centred on
  the rim** — 1pt inside, 1pt outside. `beamStrokeWidth` is deleted. Blur ramps
  `beamCoreHeadBlur` (**1.5, no longer 0**) → `beamCoreTailBlur` (6).
  **0 at the head was the visible hard end**, and it took a 3× zoom of a render
  to find: an unblurred 1pt `.butt` cap is a 1pt square of alpha 250 with nothing
  beyond it, and as the largest alpha step per half-point of arc half a point
  outside the rim it measured **170** against a mid-segment control of 7. It measured
  **6** against 3 at that blur, and **9** against 2 once the glow beneath the head
  came down to mist. Starting the blur ramp above 0 also flattens the
  per-slice banding, which was visible as ~15pt bright/dim steps down the core:
  the steps nearest blur 0 are the ones the eye can see, because the alpha a 1pt
  line keeps falls off fastest there.
  **Glow:** `beamGlowWidth` 10 before blurring, `beamGlowStrokeWidth` doubled
  because the glow *is* masked and a stroke is centred, blur ramping
  `beamGlowHeadBlur` (**14**) up to `beamGlowTailBlur` (**24**), never 0 anywhere the beam is lit, opacity ramped by `beamGlowRamp`. The
  band is wide on purpose: brightness at the rim comes from the band's width and
  reach comes from the radius, so a hairline source cannot buy brightness with
  radius.
  Both strokes are `Style.beamSegments` (20) equal slices of path length, one
  slice list drawn twice, one `BorderBeam.outward` mask over the glow and the
  bloom and none over the core,
  because there is **no API that makes a gradient or a blur follow a path's arc
  length** and per-slice blur out of the one arc-length-uniform primitive
  (`trim`) is the only way to vary one.
  **`BorderBeam.slices` takes each slice's `position` from the *unclamped*
  travel, and that is a bug fix, not a tidy-up.** It used to be `(i + 1) / count`,
  which renormalises the whole head-to-tail range onto whatever is currently on
  screen. `trimRange` pins the lit segment's leading end at 1 from phase 0.741
  onward while the trailing end keeps advancing, so for the last quarter of every
  lap — 0.14s — the leading slice was position 1: full brightness, zero blur, and
  **stationary at the top-left corner**. Peak alpha across the render at phases
  0.74/0.80/0.86/0.92/0.97 read 249, 249, 248, 249, 248. Measured against the
  travel it reads 218, 174, 126, 79, 46. `trimRange` itself did **not** change and
  `BorderBeamTests` did not move; the arithmetic is *identical* while the segment
  is fully extended and differs only at the two ends, which is the whole point.
  The bloom's opacity is `span / tail` for the same reason — 0 at both ends of the
  sweep, 1 whenever the segment is fully extended — because a gradient has extent
  even when the lit segment has none.
  **`.butt` caps on both strokes, and the reason on the glow is no longer
  beading.** A round cap bulges half a line width past each slice's own trim
  range. On the 2pt core that produced the documented row of bright beads. On the
  20pt glow it was **re-measured with the opacity ramp in place and does not
  bead** — 0–4 turns in the along-beam profile, the same as `.butt` — and is
  rejected for something worse: each slice's 10pt bulge overlaps its neighbours,
  so every slice's opacity is smeared into the ones either side and the ramp
  flattens back into the tube. `.round` on the glow read 153 thirty points behind
  the head against 194 at the head (a ratio of 1.3) where `.butt` reads 96 against
  175 (1.8), and raised total lit energy 53%. The falloff is what the caps protect.
  **The ceiling on the halo is the gutter again.** Measured reach is **37pt
  outward** against 48pt between two Card surfaces, so `cardInset` stays 24. Inward,
  only the core's own half reaches anything: alpha stops entirely by 13pt in and
  nothing past 10pt in exceeds 4, so the Card's content is untouched — which is what
  `nothingIsLitDeepInsideTheRim` bounds now that neither "nothing inside" nor
  "nothing outside" is true.
  **Normal compositing, never additive.** `.plusLighter` was measured and rejected:
  over a white ground it saturates every covered pixel, so the profile at the head
  and at three points down the tail come back *identical* and the falloff stops
  existing. In light appearance it has nowhere to go at all, because nothing is
  brighter than a white wallpaper.
  `Motion.beamSweep` is 0.55s and stays `easeOut` — the visible *end* of a sweep is
  the tail draining through the seam, and easeOut spends its last frames there. It
  has not changed through any paint change, including this one: the lit segment is
  still `beamTailFraction` (0.35) of the same perimeter, so there is exactly as much
  rim to travel. A longer-*looking* comet is not a longer journey.
  **All of it was found by rasterising with `ImageRenderer`**, because
  `BorderBeamTests` pins the trim geometry and passed the whole time the beam was
  invisible. `BorderBeamRenderTests` is the pixel-level counterpart and the only
  test here that looks at pixels. It pads what it rasterises by
  `cardInset + beamGlowTailBlur`, it asserts zero beam pixels **outside** the rim,
  it asserts the head has a halo *and* a crisp core, it asserts the beam still
  reads on a Card composited over a **pure white desktop** — which is the fifth
  pass's whole finding as an inequality — and it asserts the two things
  that have each shipped broken once: **`theGlowPeaksAtTheHeadAndDiesAtTheTail`**
  (monotone along the beam, and a 4× head-to-far ratio, which the tube failed on
  both counts) and **`neitherEndOfTheLitSegmentIsAHardEdge`** (bounded tangential
  gradient at both termini, plus a drain-out whose peak alpha falls by more than
  3×). The ratio in that last one is not decoration: with the travel-based
  `position` reverted but this pass's blur left in, the drain-out is still monotone
  — 218, 203, 186, 166, 149 — and monotone-only would have passed a terminus three
  times too bright.
  **This is the sixth pass, and the first five each measured something true and
  irrelevant.** The first profiled the falloff *along* the beam and never across
  it, and shipped a head with no halo while reporting a monotone falloff. The
  second profiled it *across* and never along, and shipped a halo of constant
  opacity — a tube — while reporting a real halo at every distance. The third took
  both profiles *and* rendered PNGs and looked at them at 3×, which is what found
  the core's cap and the per-slice banding; neither is visible in any number the
  first two passes were taking. The fourth measured the core's **absolute colour
  and its saturation** rather than a Δ, which is the measurement a delta hides: a
  saturated blue and a desaturated near-white can measure the same contrast against
  the same ground and are not the same thing at all. The fifth found that all four
  had measured the beam against **synthetic grounds** and never against the thing it
  was actually drawn on, which turned out not to be the Card at all — see the bullet
  above. The sixth measured all of that correctly and found the answer was the
  *placement*: the fix for a beam drawing on a wallpaper is not to move it onto the
  Card, it is to give it a colour that survives a wallpaper and let it straddle the
  edge. **A render test proving light is on screen cannot
  say whether it reads as the thing it is for**, and a render test measuring the
  right quantity against the wrong ground cannot say anything. The lesson is not
  "measure more", it is *choose the measurement that corresponds to the complaint*,
  **and composite it over the real surface** — a visible terminus is a large local
  gradient, "it should be white" is an absolute colour, and "I cannot see it" is a Δ
  against whatever is really behind it.
- **The light is ONE LIGHT BLUE, the same in both appearances, and the reference's
  own white light is recorded rather than copied.** The reference material — Tuna for
  Mac, in dark appearance over a dark wallpaper — has a thin, crisp, desaturated
  near-white rim highlight over a Card whose **fill** is blue: rim around
  (150–185, 190–215, 225–248), fill roughly (70, 120, 170). Reading that blue as
  belonging to the *light* sent two passes to a saturated core, and both were
  rejected as "too dense" and a "blue blob". Reading its white as **portable** sent
  one pass to an invisible beam, because its white works on a ground it owns and half
  of ours lands on a desktop we do not.
  So `beamHead` is **(0.50, 0.68, 1.00)@1.0** in *both* palettes, own-colour
  saturation **0.50**; `beamTail` (0.68, 0.82, 1.00)@0.42; `beamGlowHead`
  (0.62, 0.78, 1.00)@0.52; `beamGlowTail` (0.74, 0.86, 1.00)@0.18; `beamBloom`
  (0.66, 0.81, 1.00)@0.46 — each wider element less saturated than the one inside
  it, because a halo covers the most pixels and is where a colour is most obvious.
  Contrast is about `0.7 × dist(colour, ground)`, so **what binds is the worst
  ground**: this blue sits 152 from white, 135 from mid-grey and 307 from near-black,
  where a near-white sits 0 / 128 / 239 and the withdrawn saturated blue sat
  178 / **112** / 213. `theCoreIsADesaturatedHighlight` bounds the saturation from
  **both** sides — above 0.60 is the blue blob, below 0.20 is the invisible
  near-white.
  **The per-appearance polarity is deleted with the inward mask.** Light appearance's
  core was a dark cool line because a light Card is lighter than any highlight; there
  is no such ceiling outside the rim, and a light blue is far from a light desktop as
  well as a dark one. Composited peak Δ across the rim band, over a white desktop, a
  hazy grey-white one, a photograph and a near-black one: dark **83 / 61 / 111 / 227**,
  light **86 / 62 / 110 / 227**. The floor across all eight is 61, against 40 for the
  inward version and 10 for the near-white outward one.
  Do not close a weak ground by saturating this again — that is the loop these
  entries exist to break — and do not close one with a static lit rim, which is the
  fixed lamp and has been declined.
- **"Misty" and "spread it more out" are the same dial pulled opposite ways, and
  both are `Style.beamGlowRamp`.** 1.4 → 2.4 thinned the *body* of the tail;
  2.4 → **1.25** put the length back. `position^ramp` is 0 at position 0 either way,
  so the glow contributes nothing at the trailing end at any exponent — what is
  visible there is the **core**'s trailing colour blurred by `beamCoreTailBlur`,
  which is why the trailing terminus only moved 22 → 14 when `beamTail`'s alpha came
  down 0.70 → 0.42. The exponent sets the body; `beamTail`'s alpha sets the end. Glow
  alphas are 0.52 → 0.18 (they were 0.80 → 0.55, then 0.72 → 0.46) and `beamBloom`
  0.46 (was 0.76): the elongated bloom spreads the same alpha over more area, so
  nothing had to come back up.
  **The line reading as a line is one number**: the alpha half a point outside the
  rim against the alpha 4pt out, **176 / 115 = 1.53**, and it must stay above about
  1.3. At `beamBloom` 0.76 the bloom was brighter than the core it sat under and the
  crisp line was inside the brightest thing on screen.
- **The Card's own black shadow and the beam's halo share the band outside the rim
  again.** `Style.shadowRadius` 16 of black falloff sits there, and so does the halo.
  Measured when they last overlapped, the shadow cost the halo 13% on white and
  *bought* it Δ91 over a light backdrop, so it is load-bearing rather than in the
  way. Still do not suppress a Card's shadow while its beam sweeps: it would couple
  `Style` to a decoration's state for no gain.
- **The Loading Ring is not a progress indicator.** A constant-length 270° arc that
  turns, in both of the Panel's waiting states. Neither Vision nor `mdfind` reports
  progress, so a ring that *fills* would be claiming something the app cannot back.
- **`FloatingPanel.hasShadow` must stay `false`.** AppKit derives a window shadow
  from the content's alpha mask. This Panel's content is transparent glass with soft
  edges, and that derivation traces a ragged wavy contour around it plus a ghost
  second outline. Separation is the content's job: each Slab and Card draws its own
  SwiftUI shadow.
- **No `.shadow()` on a view that fills its window.** It is clipped by the window
  bounds and renders as a hard band down two edges instead of a falloff. This is why
  `PanelLayout.margin` exists: the Panel is deliberately larger than its content, by
  enough for the entrance animation's 1.04 overshoot *and* `Style.shadowRadius`
  beyond it. Shrink the margin and both artefacts come back. `PanelLayoutTests`
  asserts the relationship.
- **The empty space inside the Panel must not be hit-testable.** The margin and the
  gap between the Slabs belong to the window, and click-outside-to-dismiss depends on
  a click there counting as outside. Three things cooperate:
  `PanelHitRegions` (where the surfaces actually are, reported by the layout),
  `FloatingPanel`'s content view declining to hit-test outside them, and a *local*
  mouse monitor in `PanelController` — the global monitor never sees these clicks,
  because the window is ours.
- **Stroke a rim *after* clipping, not before.** `overlay { strokeBorder }` followed
  by `clipShape` cuts the hairline in half and aliases along the curve.
- **A tint heavy enough to read as a colour stops glass being glass.**
  `.regular.tint(.white.opacity(0.58))` is a white wash over a blur — that is what
  "material" looks like. The blur and specular edge of `.regular` are the effect; a
  tint is only ever a nudge for legibility.
- **A Slab inside a window sized to the worst case must carry a *definite*
  height.** `maxHeight` is flexible, so a Slab given one takes every point the
  Panel reserved for it — which is how the Results Slab came to be a mostly-empty
  pane with the Query field floating under the divider. The Slab hugs
  (`fixedSize(vertical:)`) and the scrolling area inside it is given a definite
  `PanelLayout.resultsAreaHeight(contentHeight:chromeHeight:)`. That also keeps the
  proposal definite all the way down to the `LazyVStack`: hugging a lazy container
  by proposing it an unspecified height makes it build all 1,914 cells to answer,
  so the content heights are **arithmetic** (`EmojiGridView.contentHeight`,
  `PanelLayout.listContentHeight`), not measurements. Where an intrinsic piece of
  furniture has to appear in that arithmetic it is rounded *up* — see
  `PanelLayout.resultsHeaderHeight`. `PanelLayoutTests` pins the sums.
- **The Query field is a bar, not a row.** `PanelLayout.queryFieldHeight` and
  nothing else, pinned along the Slab's bottom edge in every Mode; the Results
  area above it takes all the variable height. It is also the **only** place the
  Query is spelled out — the results header, the empty and searching states and
  the Action and Target Card placeholders all used to repeat it, which put the
  same string on screen twice and wrapped a long Query over three lines. One
  Query on screen at a time; everything else names what it *matched*.
- **"No results" is a claim, and a Mode has to be entitled to it.**
  `CommandCoordinator.canReportNoResults` is that entitlement and
  `isSearchInFlight` is the "Searching…" one. Clipboard, Emoji and Action search
  match in memory, so zero matches is true the instant the key lands and the
  message must not be delayed. Subject search matches the app Index, and until
  the first scan lands the Slab shows the Query bar **alone** — no message row,
  which is the shortest Slab there is (`PanelLayout.queryOnlyResultsHeight`).
  Target search answers out of process and says "Searching…" instead, and OCR
  — which is not a search at all — says "Reading text…" off
  `CommandCoordinator.isOCRInFlight`. Subject
  Results used to be withheld for 600ms by a debounced visibility flag on top of
  all that, which left "No results" as the only thing the Slab could draw in the
  meantime: every search said no and then changed its mind. A debounce cannot
  fix that, because a debounce is what it was.
- **A matched name is marked with an underline, in `highlightedName`.** Weight
  was tried and is no difference at all against a selected row, whose title is
  already bold. The subsequence tier only marks up when the *whole* Query is a
  subsequence of the name, so an Emoji found by its keywords — which have nothing
  to underline in the CLDR name — degrades to plain text instead of marking the
  two characters that happen to line up. A Result's subtitle is marked up only
  where it names the thing; `ResultDisplayItem.highlightsSubtitle` decides, and
  it is false for a derived subtitle like a clipboard entry's relative
  timestamp.
- **Emoji glyphs go through `EmojiRenderer`.** Apple Color Emoji is a bitmap font
  with strikes at 20/26/32/40/48px; an off-strike point size resamples and reads
  soft. The largest strike is 48, so a glyph slot much above 64pt looks soft unless a
  larger strike is added. `EmojiRenderer.image` is cached on the glyph **and** the box
  size — it is called from a view body, and two call sites ask for two sizes.
- **A `ForEach` id has to move when its contents do.** `EmojiSearchVM.Section` hashes
  its whole contents into its id. Every Query produces a section titled "Results", and
  while the id was the title alone a `LazyVStack` was entitled to keep the cells it
  had already built — so a filtered grid went on showing the previous Query's results
  while the Subject Card showed the right one. `ResultDisplayItem.id` is a `String`
  taken from the source for the same reason: it was a `UUID` and one initialiser
  minted a fresh one per call, re-identifying every row on every keystroke.
- **The grid and the Subject Card must draw the same glyph.** Both go through the tone
  in force — `EmojiSearchVM.displayed` for a cell, `resolvedSelection` for the Card.
  Toning is presentation only: selection, ordering and identity stay with the base,
  because a variant is never a Result.
- **Nothing builds a `ResultDisplayItem` for an Emoji.** In grid Mode a Result is a
  cell. `EmojiSearchVM.displayResults` is empty on purpose.
- Deployment target is **26.4**. Liquid Glass is unconditional — no `#available`.
- `ConcentricRectangle` exists and derives nested radii from an enclosing
  `containerShape`, but it is a `Shape` and **not** an `InsettableShape`, so it has no
  `strokeBorder`. Verified against the SDK.

## Architecture: How Components Connect

## Boot Sequence

```
codiclensApp (@main)
  └─ AppDelegate (NSApplicationDelegateAdaptor)
       ├─ Registers Cmd+Space hotkey (Carbon EventHotKey)
       ├─ Creates PanelController
       └─ Handles QLPreviewPanel responder chain
```

## Core Components

### PanelController — Window orchestrator
Owns the AppKit half: where the window sits, when it appears and disappears, who has
activation, and which clicks count as outside. Creates and manages:
- **panel** (FloatingPanel) — the *one* window, fixed at `PanelLayout.panelWidth` ×
  `panelHeight`, never resized
- **PanelPresentation** — the two values the SwiftUI content and the controller pass
  between them: `visible` (drives `Motion.panelEntrance`) and `hitRegions`
- **CommandCoordinator** — all business logic
- **QuickLookHelper** — QLPreviewPanel data source/delegate

Wires runner callbacks:
- `onHide` → `hidePanel()` — the animated dismissal
- `onPasteAndHide` → `pasteAndHide()` — `hideImmediately()`, then hands activation
  back, then fires the paste. **Never animated**: a Panel still on screen takes the
  synthesised Cmd+V.
- `onQuickLook` → `showQuickLook()` — activates app, shows QLPreviewPanel
- `onSavePanel` → `showSavePanel()` — NSSavePanel for file export
- `onShowSettings` → `showSettings()` — settings window
- `onOCRText` → `coordinator.receiveOCRText(_:)` — the OCR Text coming back the
  other way. The only callback that answers the coordinator rather than doing
  something to the window, and the reason `CommandCoordinator` neither imports
  Vision nor `await`s. See `docs/adr/0007-async-action-behind-the-effect-seam.md`.

`coordinator.onPhaseChange` is **not** wired. It used to resize the card window; the
window no longer resizes, and the Card row's width is a SwiftUI animation driven by
`coordinator.cardCount`.

Show and hide:
- `showPanel()` centres the *Card row* on the screen the mouse is on, renders once at
  `visible == false`, then flips it inside `withAnimation(Motion.entrance)`
- `hidePanel()` drops the observers and hands activation back immediately, and lets
  only the `orderOut` wait for the exit animation's completion. `isShowing` and
  `showGeneration` are what stop a re-show racing a pending completion
- `hideImmediately()` is the no-animation path: paste, save panel, settings, teardown

Focus lifecycle lives in **FocusHandoff** — `capture`, `restore`, `yield`. Every
`previousApp` read and write in the app is in that one file.

### CommandCoordinator — State machine + execution
Owns four view models, one per search phase:
- **SubjectSearchVM** — app discovery (recursive FileManager scan) + fuzzy matching
- **ActionSearchVM** — context-sensitive actions based on selected subject
- **TargetSearchVM** — file/app targets via `mdfind` subprocess
- **ClipboardSearchVM** → **ClipboardManager** — clipboard history

Phase state machine:
```
searchingSubject ──Enter──→ executeDefaultAction + hide
       │                      (app/file/folder/text)
       │Tab
       ▼
  pickingAction ──Enter──→ executeAction + hide (final actions)
       │                      or advance to pickingTarget (non-final)
       │Tab (non-final)
       ▼
  pickingTarget ──Enter──→ executeAction + hide

searchingSubject ──"Clipboard"──→ browsingClipboard ──Enter──→ paste item
                                        │Tab
                                        ▼
                                   pickingAction (clipboard-specific)
```

A file becomes a Subject two ways, and neither is a file browser — see
`docs/adr/0008-a-file-can-be-a-subject.md`. A **Path Subject** is a Query
beginning `/` or `~`, resolved by `PathSubject` to exactly one file or folder;
those two prefixes cannot collide with an app name, so none of the Index's
gates move for one. **Use as Subject** is a non-Final Action that promotes a
file-or-app Target into the Subject and lands back on `.pickingAction`. Files
are deliberately *not* ranked alongside apps in Subject search.

OCR is the one Action that takes time. It returns `[.ocr(url)]` and **no
`.hide`** — the OCR Text lands *in* the Panel — and `EffectRunner` awaits
Vision and answers through `onOCRText`. `isOCRInFlight` gates a second Enter
and is what the Slab's "Reading text…" row reads.

Text mode: activates only when fuzzy search returns zero app matches
(result-dependent, not input-dependent) — **and only once the Index has
answered**. `SubjectSearchVM.isIndexReady` is that gate. Before the first scan
lands there are zero matches because nothing was searched, and standing a text
Subject in for that turned every character of a cold start into prose.

### FloatingPanel — Non-activating NSPanel
```swift
styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView]
```
Critical contract: the panel floats over other apps WITHOUT stealing macOS activation. This means the previously active app stays frontmost, which is required for paste simulation (CGEvent Cmd+V targets the frontmost app).

When Quick Look is shown, `NSApp.activate()` breaks this contract. PanelController captures `previousApp` and restores it event-driven before pasting.

### CardContainerView — Keyboard input capture
Contains a hidden `TextField` that captures all keyboard input, and the Card row.
**The keyboard lives here and nowhere else** — the Query field in the Results Slab is
display-only. Routes to coordinator:
- Enter → `submit()`, ⌥Enter → `toggleSkinTonePicker()`
- Tab → `advancePhase()` / Shift+Tab → `retreatPhase()`, both unconditional.
  **Shift+Tab does not arrive as `.tab`, and testing for it that way is why it did
  nothing at all for a while.** AppKit gives a back-tab its own control character
  — `NSText.h` spells them `NSTabCharacter = 0x0009` and
  `NSBackTabCharacter = 0x0019` — and SwiftUI passes it straight through, so
  `press.key` is U+0019 and a `press.key == .tab && press.modifiers.contains(.shift)`
  test is false for every Shift+Tab ever pressed. `KeyEquivalent` has no `.backTab`,
  so the scalar literal is the only spelling. Apple documents none of this and
  `KeyPress.characters` — "the characters generated by the pressed key as if no
  modifier key applies" — reads like a promise that the back-tab normalises back
  down to a tab, which is **wrong**: a probe logging both fields recorded
  `key=U+0019 characters=U+0019 modifiers=0x0002[shift]`, against `U+0009` in both
  with no modifiers for a plain Tab. The `.shift` test that remains is not
  redundant — U+0019 is also Ctrl+Y, which would otherwise retreat the Phase.
  Shift+Tab is the inverse of **Tab**, not of Ctrl+L: it is unconditional, so in
  Emoji Mode it leaves the grid rather than walking a cell left.
- Up/Down → `moveUp()` / `moveDown()`
- Left/Right → `moveLeft()` / `moveRight()`, which mean something only in a grid
- Escape → `handleEscape()`
- Shift+Space → `triggerQuickLook()`
- Ctrl+E / Cmd+E → `toggleTextSubjectEdit()` — **any** text Subject, not just a
  Clipboard Item: OCR Text and a transform's output too
- Ctrl+J/K → `moveDown()` / `moveUp()`
- Ctrl+H/L → `moveLeft()` / `moveRight()` **first**, and only `retreatPhase()` /
  `advancePhase()` when the horizontal move meant nothing. Routing them straight to
  the Phase took Ctrl+H and Ctrl+L out of Emoji Mode. Both spellings of a
  Control-modified key are accepted, via `ControlKey.letter`.

### View Cards
- **SubjectCardView** — shows app icon/name, text preview, emoji glyph, or clipboard
  content, plus the corner chips
- **ActionCardView** — shows available actions for selected subject
- **TargetCardView** — shows file/app targets for selected action

Each Card carries a `KeyHintChip` in its bottom-trailing corner while it has the
keyboard, and only where its action has an obvious key.

### PanelView / ResultsListView — the Panel's contents
`PanelView` is the Card row, a real gap, and the Results Slab. The Slab animates in
when there are Results and out when there are not, with `Motion.resize` — except in
Emoji Mode, where the grid is never empty and the Slab is unconditional. A
display-only Query field is pinned along its bottom, because the Subject Card shows
what the Query *matched* rather than what was typed.

The Slab is **sized to its content**, up to `PanelLayout.maxResultsHeight`: ten
matching Emoji make a Slab two grid rows tall, and "No results" plus the Query bar
makes the shortest one there is (`PanelLayout.minResultsHeight`). Growing and
shrinking is the same `Motion.resize`, applied to the Results area's own frame with
`hardCut()` on the content inside it, so the surface springs while the cells cut.
`hitRegions.results` follows because the layout *reports* the Slab's frame — the
space the Panel reserved and the Slab did not use has to dismiss on a click.

### ClipboardHistory / PasteboardWatcher — clipboard capture
Polls `NSPasteboard.general` every 0.5s. Stores up to 100 items as JSON in Application
Support. Images saved as PNG files in `codiclens/images/`. Text previews for Quick Look
in `codiclens/previews/`. The pasteboard is only ever read on the main thread; the
PNG re-encode goes through `ImageReencoder`, off-main in the app and inline in tests.

### QuickLookHelper — QLPreviewPanel bridge
Data source and delegate for system Quick Look. Handles keyboard events (j/k navigation, Shift+Space dismiss). Reports dismissal via `onDismiss` callback.

## Data Flow: Paste

```
User selects clipboard item → Enter
  → CommandCoordinator.submit()
  → pasteClipboardItem(): writes to NSPasteboard.general
  → onPasteAndHide callback
  → PanelController.pasteAndHide():
      1. Hide the Panel (orderOut, no animation)
      2. If codiclens stole activation (Quick Look was used):
         - Activate previousApp
         - Wait for didActivateApplicationNotification (event-driven)
         - Then fire simulateAction
      3. Else: fire simulateAction immediately
  → simulatePaste(): CGEvent Cmd+V to cgSessionEventTap
```

## Data Flow: App Launch

```
User types query → Enter
  → CommandCoordinator.submit()
  → onHide callback (panel hides FIRST)
  → executeDefaultAction(): openAsync(url)
      → Task { NSWorkspace.shared.open(url, configuration:) }
```

## Key Files

| File | Role |
|------|------|
| `codiclensApp.swift` | @main entry, AppDelegate adaptor |
| `AppDelegate.swift` | Hotkey registration, QLPreviewPanel responder |
| `PanelController.swift` | The one window: show/hide, focus lifecycle, observers, hit test |
| `PanelView.swift` | The SwiftUI content of the Panel: Card row, gap, Results Slab |
| `PanelLayout.swift` | The Panel's fixed geometry, the margin, and `PanelHitRegions` |
| `FocusHandoff.swift` | Who had activation, and how it is given back |
| `ControlKey.swift` | Folding a Control-modified key press onto its letter |
| `KeyHintChip.swift` | The keyboard hint in a Card's bottom-trailing corner |
| `CommandCoordinator.swift` | State machine, execution, paste simulation |
| `FloatingPanel.swift` | Non-activating NSPanel subclass |
| `CardContainerView.swift` | Hidden TextField keyboard capture |
| `SubjectSearchVM.swift` | Recursive app discovery + fuzzy search |
| `ActionSearchVM.swift` | Context-sensitive action loading |
| `TargetSearchVM.swift` | File/app target search via mdfind |
| `ClipboardHistory.swift` / `PasteboardWatcher.swift` | Clipboard storage, and the pasteboard poller that feeds it |
| `ClipboardSearchVM.swift` | Clipboard search/filter |
| `QuickLookHelper.swift` | QLPreviewPanel data source/delegate |
| `Subject.swift` | Subject model (app/file/folder/text/builtIn) |
| `PathSubject.swift` | A Query beginning `/` or `~`, and the one URL→Subject resolver |
| `OCR.swift` | The whole of the app's Vision use: URL → OCR Text |
| `SubjectAction.swift` | Action model, text transforms, action handlers |
| `FuzzyMatch.swift` | Fuzzy scoring (exact/prefix/substring/subsequence/levenshtein) |
| `Emoji.swift` | Emoji model, SkinTone, default-tone preference, glyph→NSImage rendering |
| `EmojiIndex.swift` | Bundled emoji dataset: lookup, grouping, skin-tone variants |
| `EmojiSearchVM.swift` | Emoji ranking, grid sections, grid keyboard model |
| `EmojiRecentsStore.swift` | Emoji Recents persistence (Application Support) |
| `EmojiGridView.swift` | Results Slab in grid Mode |
| `Style.swift` | Every radius, material, tint and rim, and all three of the Border Beam's parts — the two strokes' widths, blurs and ramps, and `BeamBloom`. The only `colorScheme` branch |
| `Motion.swift` | The three transition curves, the two decorations, the Reduce Motion and Reduce Transparency reads, entrance/shake/hardCut |
| `BorderBeam.swift` | A Card's one-lap comet: over-travel geometry, slicing and the travel-based `position`, the head point and tangent the bloom is placed on, the outward mask over the halo, `CardBeam`'s identity policy |
| `LoadingRing.swift` | The app's own spinner, in place of a system `ProgressView` |
| `AppIndex.swift` | The app Index: background scan, atomic swap, lazy icons |
| `AppDirectoryWatcher.swift` | FSEvents watch over the application directories |

## Known issues

Real, unfixed, none urgent.

- Signing teams are inconsistent. Both targets override `DEVELOPMENT_TEAM` to
  `L256GR2793`, while the project-level default is `HHNPP7C8GB`. Will bite on a clean
  checkout.
- **A Subject Card outside a Query Phase shows `selectedSubject`, not
  `subjectVM.results[selectedIndex]`.** `SubjectCardView.isQueryPhase` is the
  switch. The two values are only the same while the Query is still the question
  being asked; once a Subject has been *chosen* they diverge, and reading the
  results is how "Use as Subject" left Finder on the Card after promoting a file
  out of it. `retargetedText` solved the same bug for OCR Text and a transform's
  output and was `.text`-only, so a promoted file fell straight through it. The
  name is marked up against the Query only in a Query Phase, for the same reason:
  a chosen Subject's name is not what the Query matched.
- `SubjectCardView.textSubjectEditor` takes focus from a `.task`, which is the first
  main-actor turn after the editor is inserted. That is ordering, not a delay — but it
  is still the weakest link in the focus story, and if the clipboard editor ever comes
  up unfocused, this is why.
- `Motion.resizeDuration` and `Motion.resizeTimingFunction` are unused. They are the
  AppKit spelling of `resize`, kept for the next time something animates a window
  frame; nothing does now that the Panel never resizes.
- **Ranking the whole emoji dataset is the remaining per-keystroke cost.**
  `EmojiSearchVM.rank` runs `fuzzyScore` over 1,914 names and ~15,000 keywords on the
  main thread. Measured on this dataset: **26–52 ms per keystroke unoptimised, 6–10 ms
  optimised** (it was 2× worse before `fuzzyScore` learned to reject on the length
  difference before building the Levenshtein matrix). Debug builds feel it; Release
  does not. The next move, if it is ever needed, is to stop allocating a `lowercased()`
  pair per call — the dataset is already lowercase — or to move ranking off the main
  thread. Do not "optimise" it by loosening the scoring: `FuzzyMatchTests` pins the
  tiers, and app search shares the function.
- **The Border Beam's own cost is small and the absolute figure is
  harness-dependent.** Rasterising the beam layer with `ImageRenderer` over a
  34-frame sweep, the head bloom — a `GeometryReader`, one `Path` build, one
  `trimmedPath` and one `RadialGradient` fill per frame — costs **3.98 → 4.03 ms
  in Release** and **4.50 → 4.67 ms in Debug**, so about 1% and 4%. Those numbers
  are three times the 1.4 ms this note used to quote, and the difference is the
  harness rather than the beam: the same file's lit-pixel figure reproduces the
  old 8,115 exactly, so the drawing is the same and the timing loop is not
  comparable across passes. **Measure before and after in one harness and ignore
  the absolute value.** Tab sweeps two Cards at once, which is the worst realistic
  case. `ImageRenderer` is a CPU rasteriser with a bitmap allocation per frame, so
  on-screen compositing should be cheaper. The remedy if it is ever needed is
  measured and deliberately not applied: `Style.beamSegments` 20 → 12 costs about
  22% less and coarsens the falloff without breaking it.
  **The fourth pass moved no geometry and cost nothing**: the same harness reads
  **1.59 ms Release** and **2.40–2.49 ms Debug** before and after, because a colour
  and an exponent are free — 20 `pow` calls per frame — and `beamGlowHeadBlur` went
  back to 12 after being tried at 15. Those absolutes are again not comparable with
  the figures above; the *lit-pixel* count out of the same file reproduced the old
  5,197 exactly, which is how the harness was checked rather than assumed.
  **The fifth pass cost nothing either, and it deleted a compositing group.**
  Measured in one run with the mask flipped between them, the inward mask reads
  **0.97–1.00 ms Release / 1.10 ms Debug** against the outward mask's
  **0.97–1.00 / 1.11–1.13** — identical inside the noise, which is the expected
  answer: `Style.cardShape` on its own replaces a `Rectangle`, a
  `.blendMode(.destinationOut)` shape and a `.compositingGroup()`. Those absolutes
  are a *third* harness and comparable with neither set above; the standing
  instruction is to measure before and after in one run and ignore the number.
  **The sixth pass splits the mask and pays about 15% for it.** Same paint, measured
  in one run: the halo masked outward with the core drawn unmasked outside it reads
  **2.67–2.85 ms Debug / 1.77 ms Release**, against **2.34 ms Debug** with everything
  under one `cardShape` mask. That is the `Rectangle` +
  `.blendMode(.destinationOut)` + `.compositingGroup()` coming back, plus one more
  layer outside the mask. Absolutes are not comparable with any set above.
  **And the harness's own noise is now understood.** `glassEffect` does not
  rasterise deterministically under `ImageRenderer` **in Debug**: two renders of the
  same unlit Card differ by up to Δ36 on most pixels, a dither. In Release the same
  pair is bit-identical. That is what the old "Δ87 in Debug and Δ68 in Release for
  the same code" note was seeing without the cause. Every composited Δ is therefore
  a mean of several renders — `BorderBeamRenderTests.composited` averages six, which
  brings the residual under Δ5 — and Debug and Release then agree to about Δ5. The
  test floor stays 50 to clear both.
- **Release-configuration tests fail and have nothing to do with the Panel.** Run
  with `-configuration Release SWIFT_ENABLE_TESTABILITY=YES` (Release lacks
  testability, so `@testable import` will not resolve without it), the
  `PasteboardWatcherTests` cases in `ClipboardHistoryTests.swift` abort the test
  host, which marks every suite scheduled after them failed at 0.000s. Every suite
  passes when run on its own, and the whole suite passes in Debug. The documented
  command is the Debug one.
- The Panel's runtime behaviour has not been verified on screen from this environment:
  screen recording is not granted, so no screenshot was possible, and Cmd+Space is
  taken by Spotlight so the hotkey could not be driven either. The geometry and the
  hit-test rule are covered by `PanelLayoutTests`; the show/hide *window* sequence is
  not covered by anything.

### Two deliberate exceptions to the no-timing-hacks rule

Both are device or API constraints, not fixes. Do not "clean them up".

- `FocusHandoff.yield` arms a 0.5s `asyncAfter` as the deadline on
  `didActivateApplicationNotification`. The normal path is the notification, which
  cancels it. It exists because an OS notification may never arrive.
- `EffectRunner.keystrokeInterval` is a 10ms `usleep` between synthesised keystrokes,
  off the main thread. `CGEvent.post` has no delivery acknowledgement, and an unpaced
  burst outruns the receiving app's text input system, so characters go missing. It is
  the emulated device having a plausible key rate.
