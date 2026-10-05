---
status: accepted
---

# Animate the Panel, not its contents

Only three things animate: the Panel appearing, the Panel dismissing, and a Slab changing size. Phase advances, Card content swaps, and selection movement are **instant, deliberately**.

This came from measuring the reference app frame-by-frame at 60fps. Its show is blur + fade + scale together in ~100ms with a 1.04 overshoot; its hide is ~120ms with a one-frame scale-*up* anticipation kick. Everything inside its panel hard-cuts. That combination is what reads as "responsive and native without being overly animated" — the quality we're chasing.

The trap this ADR exists to prevent: animating phase transitions feels like an obvious polish win and is actively wrong. An animated selection highlight lags the keypress; an animated card swap delays information the user already asked for.

## Consequences

- Exactly three **transition** curves exist, in `Motion.swift`: `entrance`
  (show/hide), `resize` (Slab size), `snappy` (scroll-to-selection). Every
  animation that carries a change the user caused references one of the three;
  nothing declares its own.
- Reduce Motion and the user-facing animations toggle both collapse all three in one place.
- A horizontal shake signals no-match, replacing today's silent fallback to a text Subject.

## Amendment: decoration is a second category, and it carries nothing

This **replaces** an earlier amendment which permitted a system `ProgressView`
beside the "Reading text…" row on the grounds that a system control is "no more
this app's motion vocabulary than an SF Symbol is its iconography". That
reasoning is gone, and it had to go the moment the app drew its own spinning arc:
a hand-rolled loop *is* this app's vocabulary, and the escape hatch closes behind
it.

What survives is the argument the budget was always actually making. It was never
"three is the number". It was **do not animate information** — an animated
selection highlight lags the keypress, an animated Card swap delays an answer the
user already asked for. A decorative loop touches none of that. So the budget
gains a second *category* rather than a fourth and fifth curve, and the
distinction is load-bearing rather than cosmetic:

**Transitions.** `entrance`, `resize`, `snappy`. Still exactly three. Each one
starts, finishes and is gone, and each one carries a change the user caused. The
original consequences above apply to these and only these.

**Decoration.** `beamSweep`, `ringSpin`. A second, explicitly separate section of
`Motion.swift`, under three rules, none of them optional:

- **It carries no information.** If a user could learn something by watching it,
  it is not decoration and does not belong here. This is the rule that keeps the
  category from becoming a loophole: the next animation that "just needs to show
  the user that something is happening" is a transition wearing decoration's
  clothes, and it goes through the three curves or it does not ship.
- **It delays nothing.** No decoration is ever waited on, gated on, or given a
  threshold before it appears. In particular this forecloses the `asyncAfter`
  that a "don't flash the ring on fast images" threshold would need — already
  rejected once, during the OCR grilling, and rejected here permanently.
- **It stops under Reduce Motion.** `Motion.collapsed(_:)` turns an `Animation`
  into a cross-fade, which is meaningless for a loop and meaningless for a
  travelling highlight — so the collapse cannot be delegated to it. Decoration
  reads `Motion.isReduced` directly and is simply absent. Whatever the surface
  said without it, it still says.

**Reduce Transparency is a fourth thing and not a fourth rule.** It is a separate
system switch from Reduce Motion, and Apple's guidance for it is about legibility
rather than movement: content should be opaque rather than semi-transparent. A
blur is semi-transparent by definition, so the Border Beam's comet answers it by
**dropping its halo — the glow layer and the head bloom together — and going on
sweeping**; the crisp core still travels the rim. That is not a weaker version of
Reduce Motion's answer, it is a different answer to a different question, and the
two must stay independent: with Reduce Motion on there is no beam at all, and with
only Reduce Transparency on there is a beam with no halo. Folding the read into
`Motion.isReduced` would make those two cases indistinguishable, and there is no
state in which one implies the other. The halo is dropped *whole* rather than
un-blurred — that was the answer while the beam was one layer, and it stopped
being right when the glow got its own 10pt-wide source band: un-blurring that is
not a quieter halo, it is a flat bar travelling the rim. The bloom has no
un-blurred form at all, being a `RadialGradient`, which is a second reason it
leaves with the glow rather than being turned down.

Both reads live in `Motion.swift` — `isReduced` and `isTransparencyReduced` —
because that file is already the single place the app reads AppKit accessibility
state, and one slightly-misnamed home beats two files each holding one. This is
the only rule in this ADR that is about a *switch* rather than about motion, and
it is recorded here because the alternative is it being rediscovered in
`Style.swift`.

### The two members

**The Border Beam** belongs to a **Card** — Subject, Action or Target — and it
sweeps around that Card when the Card **becomes about something new**. It means
nothing. It is emphatically **not** tied to OCR, to `isOCRInFlight`, or to any
waiting or in-flight state — that misreading is the single most likely way this
feature gets wrong later, which is why it is written here and in `GLOSSARY.md`
both. OCR Text sweeps the Subject Card because the *Subject was replaced*; that
it happens when OCR finishes is a coincidence of the same event, and nothing in
`BorderBeam.swift` reads an in-flight flag. It shares a drawing primitive with
the Loading Ring — an animated `trim` along a stroked path — and nothing else.

The trigger is a **pure function of coordinator state**: `CardBeamIdentity`
builds a token per Card and `CardBeam` sweeps when the token changes. Three
things move the Subject Card's token — the summon, the Phase, and the chosen
Subject — so a Tab that advances the Phase *and* chooses a Subject is one change
and one sweep. `CardBeam` is that policy and `borderBeam(trigger:)` is the
primitive underneath; the split is deliberate, so the sweep itself knows nothing
about Phases.

**A selection moving must never move a token.** This is the constraint the
tokens are shaped around, and it is the same principle as the opening argument:
selection movement is instant on purpose, and a beam per arrow key would be a
Panel that strobes while the user reads a list. `CardBeamIdentityTests` carries
eight negative cases for it. The subtle one is worth naming: `moveUp`/`moveDown`
*clear* `selectedSubject` while the Clipboard is browsed, so a token that read
the chosen Subject in a browsing Phase would sweep on the first arrow key after
Enter — the Phases that preview a selection deliberately contribute no Subject to
the token at all.

Two consequences of the trigger being pure, both recorded rather than hidden. A
token cannot tell an arrival from a departure, so the Action Card sweeps as the
keyboard *leaves* it as well as when it arrives — Tab from Action to Target
sweeps both Cards. The alternative loses the Shift+Tab-back sweep silently, which
is worse than one sweep too many. And `CardBeam` keeps an `onAppear` bump
alongside `onChange`, because the Action and Target Cards are *inserted* on
`cardCount`: a fresh view's state starts at zero and its `onChange` never fires.

An earlier version of this fired on a **focus edge** instead, and missed
everything that changes a Card without moving focus: Enter into the Clipboard
(both Phases are ones where the Subject Card holds the keyboard), OCR Text
landing, a transform's output, and every summon after the first. That version
looked like it worked because the Action Card's `onAppear` was firing — the focus
edge was doing almost nothing.

**That trigger sits closer to this ADR's thesis than anything else in the
Decoration category, and it is recorded rather than glossed.** The opening
argument here is that animating a Phase transition "feels like an obvious polish
win and is actively wrong". A beam on every Tab is not exempt from that by being
decoration — it is exempt because of *what* it animates. The named harms are an
animated highlight lagging the keypress and an animated Card swap delaying
information the user already asked for; the beam runs on the Card's rim, the
Card's *contents* hard-cut exactly as they always did, and the Phase has already
moved by the time the sweep starts. Nothing is waited on and nothing is late.

**Two earlier versions of this are worth keeping, because both were wrong in
ways that reading could not catch.**

It was first built on the **Results Slab**, and triggered by the Slab arriving.
That trigger was wrong on contact: the Slab arrives once per summon, on the first
keystroke, so Tab, Enter and entering Clipboard produced nothing at all. Not a
wrong *idea* — an untraced one. "The Slab arriving" sounds frequent and is not.
Widening it to every Phase move fixed the frequency and left the surface wrong:
the effect belongs on the Cards, which is where the reference material had it all
along. A still frame cannot distinguish a travelling beam from a fixed gradient
rim, and that ambiguity cost two rebuilds.

The Slab's own hairline rim was wired up during the first version, because a beam
wants an existing edge to run along. When the beam moved to the Cards that rim
was reverted with it — the Cards already have rims, and giving the Slab one was
never asked for. `Palette.slabRim` is still declared and still unused, as it was
before any of this.

If a sweep per Tab turns out to be too much once someone can see it, the narrower
trigger is Mode changes only — entering Clipboard, entering Emoji, OCR Text
landing. That is a change to `CardBeam` and to nothing else here.

It is driven the way the shake is driven: an `Animatable` modifier carrying a
`progress`, stepped by an `Int` trigger inside `withAnimation`. No per-frame
clock, no `TimelineView`. A `trim` along the shape's own path, never a rotating
conic gradient: the Slab is a wide rectangle, and a constant *angular* rate races
the long edges and crawls the corners.

### The beam is a comet, and the paint changed four times — and then the ground did

It was a 3.5pt bright bar with a stepped opacity falloff. Then it was a **comet**
in one layer: a crisp 1pt head, a per-slice blur ramping from 0 at the head, one
sliced stroke, masked outward. Then it was a comet in **two layers** — a crisp
core inside a soft glow of constant opacity. Then a comet in **three parts**: a
radial bloom at the head, a glow that peaks under the bloom and dies away behind
it, and the crisp core on top of both. Then the light went **white** rather than
blue and the halo became mist rather than a cloud. It is still those three parts,
still that paint.

**The fifth and sixth changes are the only structural ones, and they are one
argument in two halves.** Through all four paint steps the beam was masked to the
region *outside* the rim, so it never composited against anything this app draws —
outside a Card's rim is the gutter and then the Panel's transparent margin, which is
the user's desktop. The fifth pass inverted the mask entirely: everything inward,
onto the Card's own glass. That fixed the ground and was rejected on sight, because
the halo was then over the Card's content.

**The sixth pass is where it landed: the halo outward, the crisp core *straddling*
the rim, and the light a light blue.** That last part is not a paint preference — it
is the enabling condition. Half the core and all of the halo composite against a
desktop the app does not own, and the fifth pass's own measurement is why that is
survivable only for a chromatic colour: a **near-white** beam over a bright hazy
wallpaper measured Δ10/442, where a light blue is 152 from white, 135 from mid-grey
and 307 from near-black. The half of the core on the glass is the floor no wallpaper
can take away. Every measurement in the four sections below was taken against a
synthetic swatch and is therefore a measurement of the beam and not of the effect;
they are kept because their *shape* arguments — a coma not a tube, a bloom not a lit
line, `.butt` caps, the travel-based position — all still hold.

**Nothing in the decision above moved, through any step.** Same `trim`, same
over-travel geometry, same `Animatable` drive with no clock, same one lap, same
"it means nothing", same absent-under-Reduce-Motion. These are paint changes,
which is why they are recorded here rather than in ADRs of their own — a second
ADR would restate this one and leave two documents disagreeing about who owns the
beam.

**The one thing worth reading if nothing else is read.** All four paint passes
measured carefully, reported true numbers, and were rejected on sight — and the
fifth found out why: every one of them measured the light against a synthetic
rectangle, and the surface it was actually landing on was not in the app at all. See
"The inward comet, and the blue one after it" at the end of this section; if you read one thing here, read
that. The first
profiled the falloff *along* the beam and never across it, and shipped a head
with no halo at all while reporting a monotone falloff. The second profiled it
*across* and never along, and shipped a halo of constant opacity — a glowing tube
— while reporting a real halo at every distance. The third took both profiles
*and* rasterised PNGs and looked at them, at 3×, which is the only thing that
found the core's flat cap and the per-slice banding in it. The fourth is the one
worth dwelling on, because its miss was not a missing profile: every number it
inherited was a **delta against a ground**, and a delta cannot tell a saturated
blue line from a desaturated near-white one. Both can measure Δ200 on the same
backdrop. The reference material's rim light is white and the blue in the image
belongs to its Card's *fill*; two passes read that blue as belonging to the light
and pushed the core further into saturation to make it "read", which is the exact
opposite of what was being asked for. The lesson is not "measure more". It is
**choose the measurement that corresponds to the complaint** — "you can see where
it ends" is a large local gradient, "it should be white" is an absolute colour and
a saturation, and in both cases nobody had measured the quantity being complained
about. Where the complaint is about how something *looks*, the closing check has
to be a picture.

#### Why the one-layer comet failed on screen while measuring correctly

This is the most useful thing in this section and it goes first.

The one-layer comet was measured, rasterised, and pinned by a pixel-level test. It
was internally consistent: the falloff was monotone, the tail survived its blur,
nothing landed inside the rim, the trim geometry was exact. Every number in the
paragraphs below was real. And the answer on a real screen was *"this is not near
the image I gave you... I want it to kind of almost look like it is glowing out
from the card itself, instead of just being a line. There is not enough spread at
all and it should be more clear that there even is a glow."*

Three separate causes, and the first is the one worth remembering:

**A slice has one blur radius, so one sliced stroke cannot be crisp and bloomed at
the same time.** The falloff ramped blur from **exactly 0** at the head, on the
stated grounds that "the crisp leading edge against a dissolving tail is the entire
contrast the comet lives on". That sentence is half right and the half it gets
wrong deletes the effect: a crisp core is right, and a crisp core with *nothing
behind it* is a line. Measured on the real modifier, the head put alpha 247 one
pixel outside the rim and **zero** at every distance beyond it, in both
appearances. The halo at the head was not small. It did not exist. And no amount of
retuning a single layer could have produced one, because the same slice cannot
carry two radii — which means this was an architectural mistake wearing the clothes
of a tuning decision, and the sentence that justified it read as a taste
judgement.

**The spread was an order of magnitude too small, and the geometry capped it.**
`beamTailBlur` was 8 with a ceiling of `cardInset` (12) — a 1pt line blurred by 8
reached 11.5pt. That is a hairline halo. It also could not simply be turned up: a
1pt line blurred by 20 spreads the same alpha over 40× the area and comes back
*fainter as well as wider*. Reach and near-rim brightness are two levers, and one
stroke of one width only offers one.

**The colours were wrong in the appearance the user was actually in**, which the
previous pass measured, wrote down as an open question, and shipped. Recorded
honestly there and still wrong to ship: a beam whose brightest element measures
Δ43/765 is not a "known issue", it is the feature not working.

The lesson that generalises: **a render test proved the beam was on screen and
could not tell anyone it was too small to notice.** "You can see it" and "it reads
as the thing it is for" are two more different claims, and the second one still
needs an eye. What a render *can* do — and now does — is fail when the head has no
halo at all, because that is a measurable absence rather than a matter of degree.

#### The two-layer comet — the step that fixed the halo and invented the tube

*Everything in this sub-section was true of the version that shipped second, and
the parts of it that have since been reversed are called out where they appear.
The reversals are all in the sub-section after it.*

**Two layers, glow under core.** The glow is its own sliced stroke:
`Style.beamGlowWidth` (10) wide before blurring, blurred by
`beamGlowBlur(at:)`, which ramps from `beamGlowHeadBlur` (10) **under the head**
*up* to `beamGlowTailBlur` (20) at the trailing end, and is never 0 anywhere the
beam is lit. The core is the layer on top, unchanged: 1pt visible,
`beamStrokeWidth` doubled for the mask, blur ramping 0 → `beamCoreTailBlur` (6).
One list of slices, drawn twice at two widths and two blurs, one mask over both.

The glow's band is **wide on purpose**, and that is the part that is easy to get
wrong twice. Brightness against the rim comes from the width of the source band;
reach away from the rim comes from the blur radius. A hairline source cannot buy
brightness with radius, which is exactly how the one-layer version ended up with
neither. 10pt blurred by 10–20 keeps real alpha on the rim *and* falls off over
tens of points.

Measured, against three grounds in both appearances, at the head:

| | before, head | after, head at 1pt | after, at 8pt | after, at 20pt | reach |
|---|---|---|---|---|---|
| light on white | Δ78, then **0** | Δ71 | Δ62 | Δ19 | 24pt |
| light on mid-grey | Δ161, then **0** | Δ55 | Δ44 | Δ12 | 20pt |
| dark on near-black | Δ393, then **0** | Δ135 | Δ110 | Δ31 | 24pt |

(Perceptual RGB distance out of 442; "reach" is the last distance at which the
glow still measures Δ8 or more, which for the tail slices runs to 34pt.) The
before column is one number and then a row of zeroes, which is the whole story.

**The head is now a bright core inside a bloom rather than a line with a soft end.**
Rasterised in light appearance over white, the pixel on the rim is (57, 119, 254)
against a ground of (230, 230, 230) — a saturated blue line — and the next pixel
out is (171, 194, 240), fading to (244, 246, 252) 24pt away. In dark over
near-black the rim pixel is (246, 247, 248) against (16, 16, 16), and the halo
behind it runs (79, 93, 107) down to (27, 28, 30). `BorderBeamRenderTests`
`theHeadHasAHaloAndACrispCore` is that pair of claims as an assertion, and it is
the one test in the file that would have failed on the version that shipped.

**Additive blending was tried and rejected on measurement, not on taste.**
`.plusLighter` would be the obvious way to make a glow read as emitted light. In
dark appearance it does look stronger. What it also does is destroy the comet: over
a white ground, additive saturates every covered pixel to white, so the measured
profile becomes *identical* at the head, at 0.725, at 0.475 and at 0.225 along the
tail — 95, 92, 87, 81, … the same row four times. The falloff the effect is built
on stops existing, and what is left is a uniform white smear whose shape is
coverage geometry. In light appearance it is worse than useless: nothing is
brighter than a white wallpaper, so an additive glow on a light ground has nowhere
to go. Normal source-over compositing in both appearances.

**Saturation, not lightness, is what survives an unknown backdrop.** The previous
pass concluded that "no single opaque colour reads against both a white and a
mid-grey backdrop", having measured a candidate at Δ236 on white and Δ1 on
mid-grey. That conclusion was right about its candidates and wrong about the
space: every candidate it tried was reaching for *brightness*, and a pale colour is
near white while a deep one is near black. A mid-luminance **saturated** blue is
far from both — (0.20, 0.45, 1.00) is 247 units from white and 255 from black in
the same RGB metric — so light's `beamHead` went from a pale blue to that, and
measures Δ207 on white, Δ149 on mid-grey and Δ250 on near-black. One colour, three
grounds, no inversion. The open question is closed.

**That paragraph is the single most expensive sentence in this document and the
fourth pass had to unpick it. Read it with the correction below.** It is true as
arithmetic and it answered the wrong question. Nobody had asked for a colour that
maximises contrast on an unknown backdrop; the reference material shows a
*white* line, and a saturated blue is what "reads against every backdrop" gets you
if contrast is the only thing being optimised. The fourth pass also found the
arithmetic itself was over-stated: the binding ground for a saturated blue is
mid-grey rather than white, so **desaturating cost 18% of worst-case contrast, not
the inversion this paragraph feared.** See "The white comet" below.

The consequence worth naming: on a light ground the beam's **luminance delta is
negative** — it darkens by 260/765 at the head. That is not a defect, it is the
only option. Light appearance's glow is a saturated colour halo rather than a
bright one, the way any light-mode focus bloom is, because there is nothing
brighter than a white wallpaper to be.

Four more things are worth writing down, because each was a decision with an
obvious wrong alternative.

**Per-slice blur is not an implementation detail, it is the only way to vary a
blur along a path.** There is no API — checked — that makes a gradient or a blur
follow a path's arc length. `trim` is the one primitive that *is* uniform in arc
length, which is why the falloff was already cut into `Style.beamSegments` slices;
each slice is already its own view, so giving each one its own `blur(radius:)`
makes the blur vary along the path out of parts that already existed. The
rejected alternatives are the same ones the stepped falloff rejected, for the same
reasons: an `AngularGradient` in a stroke sweeps at a constant *angular* rate and
so races long edges and crawls corners, and a stroke gradient does not follow a
path at all. A `layerEffect` shader was considered and rejected on a stronger
ground: SwiftUI shaders are stateless with no memory of the previous frame, so a
shader argument does not animate under `withAnimation` and would force the clock
this whole design does not have.

**Blur is the falloff and no computed opacity ramp is stacked on it, in either
layer, and `Style.beamFalloff` stays deleted.** Blur already dims: it spreads the
same alpha over more pixels. Multiplying an opacity ramp on top of that is the
exact double-multiplication that once left only the leading slice on screen — 40pt
of an intended 336pt — and `beamFalloff` existed *solely* to undo a multiplication
of that kind. Both blur ramps are **linear** in the slice's position precisely so
there is no exponent to invent.

**That rule was half right and the wrong half made the tube.** It is correct for
the core, which is the layer whose visibility the whole effect depends on, and it
is wrong for the glow, which is the bloom around it. A constant-opacity,
constant-width blurred band is a glowing hose: it peaks nowhere, so there is no
point for the light to come from. The glow now carries
`Style.beamGlowIntensity(at:)` and the reversal is set out in full below.
`beamFalloff` itself stays deleted — the distinction between it and the glow's
ramp is the substance of the next sub-section, not a technicality.

**The core's blur is still exactly 0 at the head, and that is now correct rather
than merely defensible**, because the halo is a different layer. What was wrong
was not the crisp core; it was there being nothing else.

**Also half right, and the wrong half was the visible hard end.** A crisp core is
right. A core whose blur is *exactly* 0 has a 1pt `.butt` cap at full alpha with
nothing beyond it — a flat terminus at maximum contrast — and that is what "you
can see where the border thing ends" was about. `Style.beamCoreHeadBlur` is 1.5
now. See below.

**Both layers are masked outward, together.** Because a blur spreads inward as
much as outward, the whole beam — glow and core — is masked to the region *outside*
`Style.cardShape`, after the blur rather than before it, so no part of it washes
over the Card's icon, name or chips. That mattered when the thing being masked was
a 2pt stroke blurred by 8; it matters more now that it is a 20pt stroke blurred by
up to 20. Still no `.shadow` anywhere in it — a `.shadow`-as-bloom walks straight
into "no `.shadow()` on a view that fills its window". The hard inner edge that
the mask leaves sits exactly on the rim, and the crisp core sits on top of it,
which is why making the glow much brighter did not turn that cut into an artefact:
rasterised, the pixel row immediately outside the rim is the core at near-full
alpha in both appearances, so what abuts the Card's own edge is a line and not the
sheared-off face of a bloom. The "densest at the border" reading is still what the
cut gives. What it costs is half of each stroke, because a `.stroke` is centred on
its path, and both `beamStrokeWidth` and `beamGlowStrokeWidth` double for that.

**This paragraph is the bug, and it is the most expensive one in this document.**
Everything in it is internally consistent and every measurement in it is real. What
none of it says is *what the light lands on*, and the answer is that outside a
Card's rim there is nothing of this app's at all: `Style.cardInset`'s gutter, then
`PanelLayout.margin`, then a transparent borderless `NSPanel` — the desktop. So
"no part of it washes over the Card's icon, name or chips" was bought by excluding
the only ground the app owns, and four passes of colour work were tuned against a
wallpaper nobody had rendered. The mask is inverted; the "densest at the border"
reading survives the inversion unchanged, because the cut is at the rim either way
and the core is what abuts it either way. See the last sub-section below.

**The gutter grew twice, and the second time the Panel grew with it.**
`Style.cardInset` went 6 → 12 → 24, so the visible gap between two Card surfaces
went 12 → 24 → **48pt**. The bound is the same each time and it is not the inset
but the *gutter*: the glow must not reach a neighbouring Card's rim, which is
`cardInset * 2` away, and the measured reach is 34pt against 48.

The two steps differ in where the growth came from, and that difference is the
correction. The first took it out of the **drawn surface** — the cell stayed
260 × 240 and the surface shrank 248 × 228 → 236 × 216 — on the reasoning that
"the Panel is fixed and does not resize for a decoration". That reasoning confused
two things: the Panel never *resizes*, but it is free to be *declared* bigger, and
the alternative it was avoiding cost the user Card content. So this time
`PanelLayout.cardWidth` and `cardHeight` went 260 → 284 and 240 → 264 alongside
the inset, the drawn surface stayed **exactly 236 × 216**, and the Panel is 968 ×
732 instead of 896 × 708. `PanelLayoutTests` needed no change: every assertion in
it is relational — the margin against the entrance overshoot and the shadow, the
Panel against its content, the Slab's sums — and none of them names a Card's size.
`Style.beamSeamOffset` needed no re-probe either, and that is the point of keeping
the surface fixed: it is a function of the surface, and the surface did not move.
It stays **0.6192**, landing at (6.41, 6.41), the 45° midpoint of the corner's own
curve.

`PanelLayout.margin` did not have to grow for the glow, and that was checked
rather than assumed, because a glow clipped by the window edge is precisely the
"hard band down two edges" artefact the margin exists to prevent. Every rim has
more than 34pt between it and anything that could cut it: 82pt from the outermost
Card's rim to the window edge, 72pt above the top rim, and 36pt from the bottom rim
to the Results Slab — which is the one clearance the glow comes close to using, and
the Slab is a later sibling in the `VStack`, so it would draw *over* the glow
rather than clip it even if it did.

#### The three-part comet — the step that fixed the tube and the visible end

The answer to the two-layer version, on screen and in light appearance, was: *"the
blue color is too dense in a sense. it should be more like a single area/point
that a radial blue kinda goes out from, which gives kind of an effect that
something is glowing down from it. also the end where the beam thing stops looks
bad because you can see where the border thing ends … more like the tunaformac
that has that kinda radial blur looking vibe instead of one continues same amount
of blur out from the whole line/beam/strokelength."*

Four causes, and none of them was "the numbers are a bit high".

**1. The glow's opacity was flat, so it was a tube.** This is the important one
and it was measurable the whole time; nobody had taken the measurement. Rasterised
4pt outside the rim, the near-rim alpha behind the head ran

| arc behind head | 0 | 15 | 30 | 60 | 90 | 120 | 150 | 180 | 240 | 300 |
|---|---|---|---|---|---|---|---|---|---|---|
| before | 70 | 110 | 109 | 99 | 93 | 100 | 87 | 93 | 85 | 43 |
| after | 175 | 128 | 96 | 75 | 66 | 59 | 46 | 44 | 30 | 13 |

The before row *rises* behind the head and then sits flat for 200pt. It is not a
falloff at all; it is a hose with soft sides. `Style.beamGlowRamp` — 1.4 at this
step, 2.4 now — is a per-slice opacity ramp, `position^ramp`, multiplied into the
glow's colour and **nothing else's**.

**Which is a reversal of the "no computed opacity ramp" rule above, and the
distinction matters more than the rule did.** `Style.beamFalloff` — the exponent
this project deleted — existed to undo a *linear* opacity ramp applied to the
**only layer there was**, over colours that already carried alpha; it left 40pt of
an intended 336pt visible. Three things make the glow's ramp a different animal,
and all three have to stay true or it becomes that bug again. There is a separate
crisp core carrying the beam's visibility, so the glow is *allowed* to fall to
nothing: it is the bloom, not the beam. Killing the trailing fifth is the point
rather than the accident — a stroke that has faded out before its own `.butt` cap
has no cap to see. And it was measured along the beam *and* across it, which is
the pair of profiles neither earlier pass took together.

**2. There was no light source, only a lit line.** "A single area/point that a
radial blue goes out from" is a coma, and no amount of ramping a stroke produces
one, because a stroke has ends in the direction it runs. `BeamBloom` is a
`RadialGradient` disc, `Style.beamBloomDiameter` (96) across, placed on the rim
point the head currently occupies by `BorderBeam.bloom`. A radial fill has no
edges in any direction by construction, which answers "radial blur looking vibe"
and destroys the head's terminus rather than softening it. Its stops are a
front-loaded shoulder (1.00, 0.62, 0.30, 0.11, 0.02, 0) rather than a linear fade,
because a linear `RadialGradient` reads as a disc with a findable rim: the falloff
is constant, so the eye locates the boundary where it reaches zero.

A `RadialGradient` used as a **fill** is not the stroke gradient this ADR twice
refused, and the difference is not a loophole. An `AngularGradient` in a stroke
sweeps at a constant *angular* rate and so races a rectangle's long edges and
crawls its corners; a `LinearGradient` in a stroke does not follow the path at all.
The bloom follows nothing. It is a disc at a point, and the point comes from
`BorderBeam.headPoint(in:at:)` — one `Path` build and one `trimmedPath` per frame,
reading the *first* point of a short sub-path, which is the same trap
`Style.beamSeamOffset` records having been walked into once. It is deliberately
**approximate**: the seam offset has to be exact to a ten-thousandth because it
decides where the beam enters the rim, and a 96pt soft disc a point or two along
the rim from the core's tip is invisible.

**3. The visible end was two things, and the smaller one was easier to find.** The
travelling head's terminus was the core's `.butt` cap at `beamCoreHeadBlur` = 0: a
1pt square of alpha 250 with nothing beyond it. As the largest alpha step between
adjacent pixels half a point outside the rim, scanned ±24pt around the head, it
measured **170** against a mid-segment control of 7; it now measures **6** against
3. It was found by rasterising a PNG and looking at it at 3× — no number anyone was
taking showed it, and the same zoom showed a second artefact nobody had reported:
the core's blur ramp is quantised into `beamSegments` steps, and the steps nearest
0 band visibly, because the alpha a 1pt line retains falls off fastest there.
Starting the ramp at 1.5 fixes both. **The claim that 0 at the head was "now
correct rather than merely defensible" was wrong for the third time in this
document's history, and each time for a different reason.** A crisp core does not
have to be razor sharp; being razor sharp is what gave it an end.

The larger cause had nothing to do with caps. `BorderBeam.trimRange` pins the lit
segment's leading end at 1 from phase 0.741 onward while the trailing end keeps
advancing — that is the drain-out, and it is correct — but `BorderBeam.slices` took
each slice's `position` from **its index in the current span**. That renormalises
the whole head-to-tail range onto whatever is on screen, so the leading slice was
always position 1: full brightness, zero blur, and for the last quarter of every
lap *stationary at the top-left corner* for 0.14s. Peak alpha across the render at
phases 0.74 / 0.80 / 0.86 / 0.92 / 0.97 read 249, 249, 248, 249, 248 — a parked
head. Measuring `position` against the **unclamped travel** instead —
`position = 1 - (u - x) / tail`, where `u` is `phase * (1 + tail)` and keeps going
after the path runs out — reads 218, 174, 126, 79, 46. `trimRange` did not change
and `BorderBeamTests` did not move: the arithmetic is *identical* while the segment
is fully extended and differs only at the two ends, which is the whole point. The
grow-in improves for the same reason — it now draws the front of the comet rather
than a compressed copy of all of it. The bloom's own opacity is `span / tail`,
which is 0 at both ends of the sweep and 1 whenever the segment is fully extended,
because a disc has extent even when the lit segment has none.

**4. It was too dense.** The previous pass had pushed light's colours to a
saturated mid-luminance blue to fix a measured inversion, and *this* pass left the
**core** at (0.20, 0.45, 1.00)@0.95 on the grounds that the saturation argument was
settled — which is exactly the mistake the fourth pass had to undo, and it is worth
noting that "the core has not moved" was written twice in a row as a reassurance.
What this pass changed was the **glow**, at (0.28, 0.52, 1.00)@0.80 → (0.14, 0.36,
0.92)@0.55 spread flat over 303pt. It went to (0.38, 0.60, 1.00)@0.72 → (0.24,
0.46, 0.96)@0.46 — lighter, less saturated, lower alpha — with `beamBloom` at
(0.32, 0.56, 1.00)@0.76, less saturated again because it is the widest and softest
thing drawn. Dark's glow moved the same way. Measured at mid-sweep in light
appearance over white:

| | before | after |
|---|---|---|
| total perceptual energy | 534,554 | 290,850 (−46%) |
| lit pixels over the Card's rim | 8,115 | 5,197 (−36%) |
| peak per-pixel saturation | 0.776 | 0.643 |
| head's halo, Δ at 8pt out | 68 | **108** |
| head's halo, Δ at 20pt out | 19 | **49** |
| head's halo, Δ at 28pt out | 3 | **20** |

**Less total light, further out, coming from a point.** Either half of that alone
would mislead: the density numbers went down 40-odd percent while the halo the user
was asking to see got two to seven times stronger. Reach is unchanged at 34pt
against the 48pt gutter, so `Style.cardInset`, `PanelLayout.cardWidth`/`cardHeight`
and `beamSeamOffset` all stayed exactly where they were. `Style.beamMaskOutset` is
now `max(beamGlowTailBlur * 3 + beamGlowStrokeWidth, beamBloomDiameter)`, derived
so that raising either cannot start clipping — a clipped bloom would be a new hard
edge, which is the bug being fixed.

**`.round` caps on the glow were tried and rejected, and not for the documented
reason.** The `.butt` finding was made on the core, whose 2pt stroke beaded
visibly at nineteen joints. Re-measured on the 20pt glow *with the opacity ramp in
place*, `.round` does **not** bead — 0 to 4 turnarounds in the along-beam profile,
the same as `.butt`. It is rejected for something worse: each slice's 10pt bulge
overlaps its neighbours, so every slice's opacity smears into the ones either side
and the ramp flattens back into the tube. `.round` on the glow read 153 thirty
points behind the head against 194 at the head — a ratio of 1.3, where `.butt`
reads 96 against 175, a ratio of 1.8 — and raised total lit energy 53%. The caps
are `.butt` on both layers; on the glow the falloff is what they now protect.

The bloom costs, in the same harness, 3.98 → **4.03 ms** per frame per Card in
Release and 4.50 → **4.67 ms** in Debug: about 1% and 4%. Those absolutes are three
times what the two-layer section below reports, and the difference is the timing
harness rather than the drawing — the lit-pixel figure reproduces the older 8,115
exactly. Measure before and after in one harness and ignore the absolute value.

`Motion.beamSweep` went 0.25s → 0.55s with the first paint change, and stayed
`easeOut`. It **stayed 0.55 through the second**, which was decided rather than
skipped: the glow got wider *outward*, not longer along the rim. The lit segment is
still `beamTailFraction` of the perimeter, so there is exactly as much rim to
travel and exactly as much of it lit at once, and duration answers segment length
and perimeter. A bigger halo is easier to see, not slower to read. **It stayed
0.55 through the third as well**, for the same reason turned the other way: the
halo got quieter and more concentrated at the head, so the *visible* comet is
shorter than the 303pt that is stroked — but a shorter visible comet is not a
shorter journey, and the rim is the same length. The
perceived-speed argument below still holds, and it now has a second reason: with
the over-travel geometry the last thing a sweep does is drain the tail out through
the seam, so the end of the curve is a blurred glow emptying rather than a head
arriving. `easeOut` spends its final frames slowly, which is where that glow wants
to be spent. Linear would arrive and stop.

**Two tradeoffs, both chosen knowingly.**

The sweep is a **constant duration** over what was, on the Slab, a **variable
perimeter**: 280 × 70 to 800 × 360 is a 700pt rim to a 2,320pt one, so the beam
travelled 3.3× faster on the largest Slab than the smallest. Constant *speed* was
the alternative and was rejected for a good reason: a normalized 0 → 1 progress
is the only thing a curve can shape, and constant speed makes easing impossible
by definition. Expressiveness won over uniformity. **The tradeoff is now moot and
the reasoning is not** — every Card is one size, so the rim is one length (866pt)
and the speed is one speed. It is kept because it is the argument that would have
to be re-lost if the beam ever ran on a surface that changes size again.

At 0.25s the beam was also well past the ~1,000–2,000 pt/s that the eye tracks
comfortably, so it read as a whip rather than as a segment you follow. That was
the intent for a bar — "fast and snappy" was the brief — and it is why the curve
is `easeOut` rather than `easeInOut`: perceived speed is set by the velocity at
the *start* of a motion, and `easeOut` leaves the mark at full speed. `easeInOut`
reads as mass and considered weight, which is a different quality than the one
asked for, and slower-feeling because it spends its first frames accelerating.
**The whip is what the comet gave up.** 0.55s over an 866pt rim is about
1,600 pt/s, inside the trackable band on purpose: a 300pt tail that dissolves has
something to look at, and at whip speed it would have been a flash. The curve did
not change, only the duration.

**The Loading Ring** replaces the system `ProgressView` in **both** of the
Panel's waiting states — "Reading text…" and "Searching…". Once the app draws its
own loop, a system spinner two cases down the same `if` is the inconsistency, not
the ring. It is decorative in the strict sense above: Vision reports no
recognition progress and `mdfind` reports none either, so there is nothing for it
to be a measure of. It is a constant-length 270° arc, rotating. **Never a ring
that fills once and waits**, which would be a progress claim the app cannot back.

Two things carry over from the amendment this replaces, unchanged:

- **It never appears alone.** A bare spinner does not say what it is waiting for.
  The row's text is the content; the ring is beside it.
- **It flashes on a fast image**, and that was chosen with the flash known: OCR
  on a small screenshot finishes in well under 200ms. The alternative is a
  threshold, which is an `asyncAfter`, which the second rule above now forbids
  outright rather than merely discouraging.

#### The white comet — the step that took the blue out of the light

The answer to the three-part version, on screen and in light appearance, was: *"the
opacity of the start should be less so that it just looks more misty and then the
line should be highlighted exactly like i have shown you 100 times now with the
tunafor mac. just see if you can replicate it 1:1"*, with a tight crop of the
reference's slab and the tops of its two Cards.

**The single most useful thing in this document is what that crop actually shows.**
Its rim highlight is a thin, crisp, **desaturated near-white** line. Measured off
the crop: the Card's rim light sits around (150–185, 190–215, 225–248) over a Card
**fill** of roughly (70, 120, 170), and the outer slab's rim around
(165–180, 168–182, 172–188), a light warm grey. The blue in that image belongs to
the Card's fill, not to the light. Any glow around the line is very faint and
diffuse; there is no dense coloured halo anywhere in the frame. Codiclens's Cards
are not blue, so its beam has no blue to borrow, and every pass that read that
image as "a blue light" was reading a fill as a lamp. Two passes did, and the
second of them wrote down that the core "has not moved" as though that were
reassurance.

**The core.** Near-white and desaturated in both appearances. Own-colour saturation
at the head's rim pixel: **0.738 → 0.477** in light, **0.158 → 0.056** in dark.
Composited, dark over near-black reads **(172, 178, 183)** — the middle of the
reference's slab-rim band — and light over white reads **(169, 198, 253)**, inside
its Card-rim band on red and green and a hair over on blue. `beamHead` is
(0.50, 0.65, 0.98)@1.0 in light and white@1.0 in dark; `beamTail` (0.38, 0.54,
0.90)@0.42 and (0.74, 0.85, 1.00)@0.42.

**What desaturating cost, and why the previous section over-stated it.** The beam's
contrast against a ground is `0.7 × dist(colour, ground)` — the 0.7 is the coverage
a 1pt core keeps through the outward mask and its own head blur — so what matters
is the **worst** of the three grounds, and for a saturated blue that ground is
mid-grey rather than white. Old (0.20, 0.45, 1.00): Δ178 on white, **Δ112** on
mid-grey, Δ213 on near-black. New: Δ103, **Δ92**, Δ214. Worst case 112 → 92: **18%
of contrast for 35% of saturation.** The high blue channel is what buys mid-grey
back, which is why it stays at 0.98 while red and green come up — a fully neutral
grey core measures Δ84 at best.

**What light appearance cannot do, stated plainly because it has been "fixed" twice
already.** On a ground lighter than the light the luminance delta is negative: the
beam *darkens*, by 145/765 at the head over white, and nothing is brighter than a
white wallpaper. Over a light-**grey** wallpaper (0.86, where a great many light
desktops sit) the new core measures about Δ60/442 — the pale blue this project
shipped and withdrew measured Δ30 there, so the margin over invisible is a factor
of two rather than ten. Rendered as PNGs and looked at: in **dark** appearance the
result is the reference's character — a thin crisp near-white line on the rim with
a faint diffuse mist outside it and a small bloom at the head. In **light**
appearance over white the line is present but quiet, and what carries the effect is
the mist; over mid-grey it reads cleanly. **1:1 with the reference is a
dark-appearance result, and the user is in light appearance.** The two ways to
close that gap are both closed: saturating the core again is the loop this section
exists to break, and a static lit rim is the fixed lamp, which has been declined.

**The mist is two dials and the exponent is the wrong half on its own.**
`Style.beamGlowRamp` 1.4 → **2.4** thins the *body* of the tail: near-rim alpha 4pt
out at the head and 15/30/60/90pt behind it went 155/111/85/75/58 →
**112/80/62/48/35**, and head-to-far 7.4× → **8.6×** — a fainter tail is a steeper
comet, not a weaker one. But `position^ramp` is already 0 at position 0, so the
glow contributes nothing at all at the trailing end whatever the exponent is; what
is visible there is the **core**'s trailing colour, blurred by `beamCoreTailBlur`.
The trailing terminus's alpha 1pt out only moved 22 → **14** when `beamTail`'s own
alpha came down 0.70 → 0.42. Glow alphas are now **0.52 → 0.16** and `beamBloom`
**0.48**, down from 0.76.

**The bloom's diameter did not move, and that was a decision.** 96 is what gives it
no findable edge; 96 → 80 would hand one back. Turning the disc *down* and leaving
it *wide* is what "misty" means. At 0.76 the bloom was brighter than the core it sat
under, so the crisp line was inside the brightest thing on screen and could not be
seen as a line at all — which is the other half of "the line should be highlighted".
The number that says the line reads is the rim's alpha against the alpha 4pt out:
**1.30 → 1.59**.

**One thing was tried and reverted, with numbers.** `beamGlowHeadBlur` 12 → 15
lifts that same ratio to 1.73 — a thinner near-rim halo does make the core stand
out — and costs the halo everywhere else: Δ at 4pt out on white 60 → 50, the head's
rim Δ 103 → 96, and the hard-edge step at the head 9 → 10. Light appearance has no
contrast to spare, so it went back to 12.

| light over white, mid-sweep | two-layer | three-part | white comet |
|---|---|---|---|
| total perceptual energy | 534,554 | 290,850 | −64% again |
| lit pixels over the rim | 8,115 | 5,197 | **3,782** |
| peak per-pixel saturation | 0.776 | 0.643 | **0.361** |
| core own-colour saturation | — | 0.738 | **0.477** |

Reach is **34pt**, unchanged, against the 48pt gutter — so `Style.cardInset`,
`PanelLayout.cardWidth`/`cardHeight` and `beamSeamOffset` all stayed exactly where
they were, and the drawn surface is still 236 × 216. The hard-edge step at the head
went 6 → **9** against a control of 2 and a threshold of 40: a brighter line inside
a fainter halo has a steeper edge by construction, and that is the price of the line
reading as a line. `Motion.beamSweep` stayed 0.55s for the fourth time — nothing
about the rim's length or the lit segment's length moved.

Cost: **nothing**. The same harness reads 1.59 ms per frame per Card in Release and
2.40–2.49 ms in Debug before and after, because a colour and an exponent are free —
twenty `pow` calls per frame — and no geometry moved. Those absolutes are again not
comparable with the figures in the sections above; the *lit-pixel* count out of the
same file reproduced the old 5,197 exactly, which is how the harness was checked
rather than assumed.

`BorderBeamRenderTests` gains **`theCoreIsANearWhiteHighlight`** — renamed
`theCoreIsADesaturatedHighlight` by the fifth pass, which gave light appearance the
opposite polarity and left the old name lying — the only
assertion in the suite about a colour: the beam's own-colour saturation at the
head's rim, in both appearances, bounded below the rejected 0.738. It is a bound
rather than a target — a future pass may legitimately trade a little saturation
back for contrast on a light ground — and it exists because "it went saturated blue
again" is now a repeat failure rather than a hypothetical one. The rim-alpha floor
in `theHeadHasAHaloAndACrispCore` came down 170 → **155**, re-measured against 178
rather than scaled, and `theTailSurvivesItsOwnFalloff`'s floor of 3,000 stayed put
while the measurement fell to 3,782 — it is a floor on the beam *existing*, and it
is now the tightest it has ever been, so a fifth pass that takes the mist down
again has to re-measure it rather than assume there is room.

#### The inward comet, and the blue one after it — the steps that found the beam was drawing on the desktop

The answer to the white comet, on screen, was that **nothing showed up at all** —
summoning, Tab, typing, no beam. And the user is in **dark** appearance, where every
number this document had was strongest: `PanelController.updatePanelAppearance()`
sets `panel.appearance = .darkAqua`, the Card draws dark glass with white text, the
core is `white@1.0` and `beamGlowHead` is (0.88, 0.94, 1.00)@0.52. Near-white light,
in the appearance the reference material is from, reported at Δ400 on near-black.

**The cause is one sentence: outside a Card's rim there is nothing of this app's.**
`Style.cardInset`'s gutter, then `PanelLayout.margin`, then a borderless,
transparent, non-activating `NSPanel`. The beam was masked to that region for four
passes, so it never composited against a surface Codiclens draws — it composited
against the wallpaper. The user's wallpaper is a New York cityscape whose top half is
a bright hazy grey-white sky. Near-white light on a near-white sky.

**"Dark appearance" does not mean "dark ground", and that is the whole error.** The
appearance decides the Card's tint. It has no bearing at all on what is behind a
beam drawn *outside* the Card. Every measurement in the four sections above was taken
against a synthetic white, mid-grey or near-black rectangle — a perfectly good way to
characterise a colour, and blind to which of those three the effect would actually
land on. Worse: the previous pass's own results table already contained the answer.
"Dark core over a **white** ground: Δ19, down from 42." It was written down, it was
correct, and it was read as a curiosity for a whole iteration because dark appearance
was assumed to imply a dark backdrop.

**A measurement against a synthetic swatch is not a measurement against the real
composite.** That is the transferable lesson and it is worth more than any constant
here. The fifth pass rendered `cardSurface(focused: true)` — real `Style` values, real
`glassEffect` — over four backdrops in both appearances, and the bug fell out of the
first table it printed:

| Δ at the head, composited | white desktop | hazy grey-white | the user's photo | near-black |
|---|---|---|---|---|
| dark appearance, masked **outward** | **10** | 27 | 95 | 270 |
| dark appearance, masked **inward** | **87** | 104 | 174 | 256 |
| light appearance, masked **outward** | 89 | 63 | 59 | 204 |
| light appearance, masked **inward** | 169 | 154 | 93 | 40 |

The floor across all eight went **10 → 40**, and the floor in the appearance the user
is actually in went **10 → 87**.

**And then the halo went back outside, which is the sixth pass, because the inward
version was rejected on sight** — "it shouldn't be inside because that looks ass",
with the glow wanted outside, bigger, blue and spread out, and the rim line kept.
What makes that possible rather than a return to Δ10 is two changes taken together:
the core **straddles** the rim, so half of it is always on Liquid Glass, and the
light is a **light blue** rather than a near-white, so the other half and the whole
halo have real distance from a bright wallpaper as well as a dark one. Re-measured
the same way, over the same four backdrops (means of several renders, see the
harness note below): dark **83 / 61 / 111 / 227**, light **86 / 62 / 110 / 227**.
The floor across all eight went 40 → **61**, and the part of it no wallpaper can
touch — the core's inward half by itself — is Δ46/49.

**The reference does the same thing, and that is why it reads in every frame.** Tuna
for Mac's rim highlight is bright against its Card's own dark blue **fill** — it is lit
from the inside edge. Codiclens's was lit from the outside edge, into thin air.

##### Where the light sits, exactly — and the two inversions it took

`BorderBeam.outward` became `BorderBeam.inward` (`Style.cardShape` and nothing
else), and then came back as `outward` with the **core left unmasked**. What is drawn
now: the glow and the bloom masked to the region outside the rim, and a
`Style.beamWidth` (2) stroke centred on the rim, so 1pt lands in `[rim - 1, rim]` —
precisely the band `CardSurface`'s `strokeBorder` occupies, which is what lights the
*border* rather than drawing a second line — and 1pt lands outside. `beamStrokeWidth`
is deleted; the glow still doubles, because the glow is still masked.

**The "no outward spill" argument is deleted rather than qualified.** It said a spill
would make the line's *width* wallpaper-dependent, 2pt over a dark desktop and 1pt
over a bright one. That is true of a near-white line and false of a chromatic one,
which reads against a white sky as well as a dark one — so the objection was really
an argument about the colour. Composited peak Δ across the rim band over four
backdrops: dark **83 / 61 / 111 / 227**, light **86 / 62 / 110 / 227**, against
74 / 100 / 180 / 257 and 174 / 155 / 95 / 40 masked inward. The floor across all
eight went 40 → **61**, and the wallpaper-independent part of it — the inward half of
the core, alone — is Δ46/49. `theBeamReadsAgainstAWhiteDesktop` still passes with the
halo outside, which is the single most important fact in the pass.

**`Style.beamMaskOutset` is back, and it was right to delete it and right to restore
it.** It exists because an overlay's mask is laid out at the *content's* size while
the halo is drawn tens of points beyond it, so a mask stopping at the bounds clips
the glow and the bloom into a hard square edge. While the mask was `cardShape` — a
region entirely inside the bounds — there was no boundary to overrun. It is derived,
`max(beamGlowTailBlur * 3 + beamGlowStrokeWidth, beamBloomLength)`, so raising a blur
or the bloom cannot start clipping.

The radial cut at the rim is not an artefact, for a better reason than before: the
core straddles it, so the boundary has a line drawn over it on both sides. The step
per half point across the rim reads **70**, against 178 outward and 194 inward. The
metric that has to stay bounded is the *tangential* step — a terminus with no line to
be the edge of — and it reads 9 against a control of 3 at half a point out, against a
threshold of 40.

**Inward, only the core's own half reaches anything.** Alpha stops entirely by 13pt
in and nothing past 10pt in exceeds 4, so the icon, the name and the middle of the
Card are untouched — `nothingIsLitDeepInsideTheRim` bounds that, now that neither
"nothing inside" nor "nothing outside" is a true claim. Outward the reach is **37pt**
against the 48pt gutter, so `cardInset` stays 24.

##### The polarity, and the one thing light appearance cannot have

The ground is now *known*, in the only sense that matters — a material with a fixed
polarity — but it is not constant, because `.regular` glass transmits. Measured, the
Card's own luminance across the four backdrops:

| | white | hazy | photo | near-black |
|---|---|---|---|---|
| dark appearance's Card | 166 | 145 | 62 | 22 |
| light appearance's Card | 247 | 222 | 146 | 110 |

The rows do not overlap, and that is enough. **Dark appearance's core stays white** —
un-premultiplied (248, 251, 255), own-colour saturation 0.026 — which is the reference
material exactly, because dark appearance's Card is darker than the light at every
wallpaper. **Light appearance's core becomes a dark cool line**, (58, 68, 82) at
saturation 0.293: its Card is *lighter than any highlight*, 247 over a white desktop,
where a near-white line measures Δ5/442. This is the same sentence the "white comet"
section wrote about wallpaper — "nothing is brighter than a white wallpaper" — one
layer in, and now actually binding. It is also the polarity light appearance already
uses for every other edge: `cardRim` is black 0.10, `raisedRim` black 0.16.

**And light appearance's floor is arithmetic rather than a hope.** Its Card spans
110 → 247, a 137-unit range, so any colour *on the grey axis* is at most 68 units from
one end and a 1pt core keeps about 0.7 of that through the mask and its head blur:
**~46 is the best worst case a desaturated light core can have.** This one measures
**40**, with its strong end at 169. The blue it replaces measured 59–89 across all four
grounds — flatter, and never good. Only saturation leaves the grey axis, and a saturated
blue is what this project shipped twice and withdrew twice. The trade is the right way
round: light appearance is now strongest over the light desktops most light-appearance
users have, and weakest over a dark one, where the whole app is low-contrast anyway.

##### What moved and what did not

Nothing in the drive, the trigger, the geometry or the falloff. Same `trim`, same
over-travel, same `Animatable` with no clock, same one lap, same `CardBeamIdentity`,
same `trimRange`, same travel-based `position`, same `.butt` caps, same
`beamSeamOffset` at 0.6192 on the same 236 × 216 surface, same `Motion.beamSweep` at
0.55s — **the fifth time that duration has been left alone**, and for a new reason:
which side of the rim the light falls on is not a distance.

**The palette is one light blue in both appearances now**, which is simpler than
what it replaced and is what was asked for ("a light blue for both white and black").
`beamHead` (0.50, 0.68, 1.00)@1.0, `beamTail` (0.68, 0.82, 1.00)@0.42, `beamGlowHead`
(0.62, 0.78, 1.00)@0.52, `beamGlowTail` (0.74, 0.86, 1.00)@0.18, `beamBloom`
(0.66, 0.81, 1.00)@0.46 — each wider element less saturated than the one inside it.
The **per-appearance polarity** the fifth pass introduced (a dark cool line in light
appearance, because a light Card is lighter than any highlight) is deleted with the
inward mask that required it: outside the rim there is no such ceiling, and a light
blue is far from a light desktop as well as a dark one. Own-colour saturation is 0.50,
bounded from *both* sides by `theCoreIsADesaturatedHighlight` — above 0.60 is the blue
blob rejected twice, below 0.20 is the near-white that measured Δ10.

**The stretch is two dials.** `beamGlowRamp` 2.4 → **1.25** lifts the body of the
tail — 4pt out, at the head and 15/30/60/90pt behind it, 112/80/62/48/35 → 115/96/79/
54/42, and 100pt behind 15 → 25 — while leaving both ends alone, because the far end
is the core's own trailing colour rather than the glow at any exponent. And the bloom
is an **ellipse along the rim** instead of a circle: `beamBloomLength` 168 by
`beamBloomThickness` 96, rotated onto the rim's tangent, extent 56pt along its long
axis against 32 across in isolation and 63pt of lit rim ahead of the head in situ.
All the growth went along the rim because the gutter bounds only the across axis.
`beamGlowHeadBlur` 12 → **14** and `beamGlowTailBlur` 22 → **24** are the rest of
"bigger"; the 15 that was tried and reverted once was reverted because it cost the
halo the contrast the *line* needed, and the straddling core pays for that separately
now.

`Style.cardInset` stays **24**, and the fifth pass's written-up proposal to take it
back to 12 — on the grounds that an inward halo needs no gutter — is deleted. The
halo is outward again, the gutter is the room it falls off in, and the measured reach
is 37pt against 48. The drawn surface is still 236 × 216, so `beamSeamOffset` needed
no re-probe.

Cost: the split mask is about **15%** dearer. Same paint, measured in one run: the
halo masked outward with the core drawn unmasked outside it reads **2.67–2.85 ms
Debug / 1.77 ms Release** against **2.34 ms Debug** with everything under one
`cardShape` mask — the `Rectangle`, the `.blendMode(.destinationOut)` and the
`.compositingGroup()` coming back, plus one more layer outside the mask. Absolutes are
a fourth harness and comparable with none of the sets above; measure before and after
in one run and ignore the number.

**A harness finding worth more than the cost figure: `glassEffect` does not
rasterise deterministically under `ImageRenderer` in Debug.** Two renders of the same
unlit Card differ by up to Δ36 on most of their pixels — a dither — which is most of
`theBeamReadsAgainstAWhiteDesktop`'s own floor arriving as noise. In Release the same
pair is bit-identical. That is what the earlier "Δ87 in Debug and Δ68 in Release for
the same code" note was seeing without the cause. Every composited Δ quoted here is
a mean of several renders; the test averages six, which puts the residual under Δ5,
and Debug and Release then agree to about Δ5.

##### What the renders look like

Rendered with `ImageRenderer` at 3× and looked at, per appearance and per backdrop —
the standing instruction for this feature, and the only reason the last three
artefacts were ever found.

**Over the user's own wallpaper** the head is a blue vertical streak outside the rim,
soft on both sides, with a thin light line on the rim running through it and the halo
trailing away behind. It reads as light coming *off* the edge, which is what was
asked for, and the streak is unmistakably longer along the rim than it is thick —
the circle read as a dot and this does not. **Over a white desktop**, in both
appearances, the halo is a pale blue wash outside the rim with the line visible
through it; quiet, and present, where the near-white version was absent. **In light
appearance** the halo is the same blue rather than the shadow the inward version drew,
and the line is the quietest thing in any of these renders — the halo carries the
effect there.

##### The one number that is a risk

The floor is Δ**61**, on a hazy grey-white sky in dark appearance. That is a bright
ground under a mid-grey Card and it is the ground the halo has least distance from.
It is six times the Δ10 that was invisible, and the levers if it ever needs closing
are the two that stay closed: saturation is the withdrawn blue, and a static lit rim
is the fixed lamp.

##### The smoke comet — the step that made the plume a plume (2026-09-02)

The liquid halo was rejected against the reference with two sentences: "think about
it as a smoke simulation", and "the beam that runs on the edge should not be too
thick". Both are about the *tail*, and the liquid wave could not answer either. One
sinusoid on a stroke's width is a band that breathes; it has the same reach behind
the head as under it and the same density everywhere the ramp allows, so it read as
a thick tube with a pulse, and thinning it only made a thinner tube.

Smoke is a model, not a look: light emitted at the head that **ages** as it trails.
Three things happen to it and each is one dial in `Style` — it **expands**
(`beamSmokeExpansion`, the glow three times as wide at the tail as under the head),
it **diffuses** (`beamGlowHeadBlur` 3.5 → `beamGlowTailBlur` 8) and it
**dissipates** (`beamGlowRamp` 1.5). And it is **turbulent**:
`beamSmokeTurbulence(at:travel:)` is three incommensurate sinusoids in the slice's
position and the sweep's travel, which is the cheapest thing that has no visible
period, and it modulates the glow's width (`beamSmokeWisp`) and density
(`beamSmokeDensity`), both scaled by age so the head stays compact and the tail does
the billowing. The travel term moves the wisps as the light goes round. It is a pure
function of `(position, travel)` — no state, no clock, no randomness — so every frame
is reproducible and the render tests still measure something.

**The nose is the part that was not in the ask and answers the oldest complaint.**
Smoke has no density at its source; it thickens just behind it. `beamNose(at:)` is
a smoothstep over the leading `beamNoseFraction` (0.08, about 35pt) of the comet,
from 0 at the head point to 1 behind it, on the glow and the feather in full and on
the core at half. Without it the glow's leading slice is a butt-capped stroke at
full alpha, and every earlier attempt to hide that end — a bigger bloom, a blurred
core, a longer ellipse — was a way of covering a bar's front. With it the front is
a taper and the brightest point sits behind the head, which is what a comet looks
like and what the reference's rim light does. Every render test that wants the light
now samples the **peak** rather than the head point (`peakOnTheRightEdge`); the
hard-edge test still samples the front, because the front is what it is about.

**Thin, everywhere, and the mask stopped being the shape.** Core 2 → 1.5pt. Glow
body 8 → 4pt at the head. Feather 6 → 4pt. Bloom 160 × 40 → 100 × 16 at lower alpha.
Segments 20 → 28 so the wisps have resolution. And `beamGlowWidth` went 12 → **16**,
which reads as the opposite direction and is not: while the band was 9pt the plume's
own billows were cut flat against the mask's inner edge, so the visible inner edge
was the mask's and every wisp was invisible. The band is now wider than the plume
can reach and only the plume's own edge is ever seen; `nothingIsLitDeepInsideTheRim`
follows it and the content is still 12pt of `Style.padding` away from the deepest
faint smoke.

**What the tests said.** `theSmokeExpandsBehindTheHead` is the repaint's own
claim, stated as half-max width so the wisps' density cannot decide it: 4pt under
the peak against about 8pt on the top edge. `theHeadHasAHaloAndACrispCore` now
claims a *compact* source — bright at 2 and 4pt in, monotone to 10pt, under 20 at the
band's edge — where it used to claim the band was full.
`theBeamReadsAgainstAWhiteDesktop` measured **47 and 51** against 83 and 86 with
the liquid halo, and the floor came down 50 → **40**: a 1.5pt core and a 4pt head
are half the light on purpose, the failure it guards is 17, and the number moved
with none of the chroma or alpha nudges tried — it is the core's white over the
glass, not the glow, at the peak pixel. Everything else passed unchanged, including
the drain-out and both termini.

**And then, the same day: nothing inside the Card.** "The beam is still inside of
the card. That I do not want at all … it should at max hit the edge." So the smoke
is outside the rim, all of it: glow and bloom under `outward`, cut hard at the rim;
the core under `outward(inset: hairline)`, lighting the Card's own 1pt rim and cut
there, with `beamWidth` bounded at 2 × `hairline` so none of it is wasted. The
inward band and the feather layer are deleted — the feather was the outside part,
and now everything is. `nothingIsLitDeepInsideTheRim` became
`nothingIsLitInsideTheRim`: under 20 past 1.5pt in, zero past 3pt, at five phases.
Every light-sampling test flipped to read outward; `beamGlowRamp` went 1.5 → 1.6
because the tail reads wider outside and sat exactly on the 4× floor. This is the
third time the halo has been outside and the first time by instruction rather than
by argument; what made the first two read as a drop shadow was a wide soft band
whose brightest point sat off the edge, and this one is 4pt at the head, hard
against the rim, and only wide where it is faint. Composited over a white desktop it
measures well over the 40 floor in both appearances, because the smoke is chromatic
and the ground outside the rim contributes nothing.

**And then, the same day again: the reference, literally.** The outward smoke lasted
one look — "what is this tail thing? it looks ass … the reference image is what it
should look like" — with a screenshot of a green wisp floating off the Card's corner,
detached from the line. That is the failure every paragraph above was circling: a
halo with any shape of its own, however it is masked, is a thing next to the line
rather than light from it. So the beam is now what Tuna's is and nothing more. A white
hairline on the rim that fades along the edge. A 3pt soft white glow hugging it
outside, with the *same* fade and the same nose, so there is no point along the comet
where the glow is doing something the line is not. No nucleus, no hue, no plume:
`BeamBloom`, `head(in:at:)`, the smoke dials and the aurora ramp are deleted, not
parked. The one asymmetry left is `Palette.beamLight`, near-white in dark appearance
and faintly cool in light, because a white glow outside the rim over a white desktop
is the Δ10 nothing and light appearance's Card lives on white desktops. The floors
moved with the light: 3,910 lit pixels (floor 2,500), Δ32/24 over a white desktop
(floor 20 — the rim lighting from `cardRim` to white is what carries it there, and a
band Δ does not see that well), `beamGlowRamp` 1.5 for the 4× falloff.

### What is not in this budget

A **Glow** — a soft bloom outward from an edge — was considered alongside the beam
and ruled out **as a layer**, on three grounds: it would be a different primitive,
it walks into "no `.shadow()` on a view that fills its window", and a bloom would
need `PanelLayout.margin` to grow. The previous revision of this section drew a
careful line between that Glow and the comet's blurred tail — "the tail is the same
single stroke the head is, blurred, inside one layer and one mask; a Glow is a
*second* thing drawn behind a first; nothing here draws twice" — and closed with
"if the next proposal needs a second pass behind the beam to be visible, it is the
Glow and it is still out".

**The next proposal did need exactly that, and it is in.** The beam now draws a
second sliced stroke behind the first, and the reason the rule fell is that it was
enforcing the wrong thing. Two of its three grounds were never violated and still
are not: nothing uses `.shadow`, and `PanelLayout.margin` did not move — the glow
fits inside `Style.cardInset`'s gutter, which is padding inside the Panel rather
than the Panel's own reserve, and the clearances were measured rather than assumed.
The third ground, "a different primitive", was simply wrong: the glow is the *same*
primitive — `Style.cardShape`, trimmed, stroked, blurred — at a different width and
a different radius, sharing one slice list and one mask with the core.

What the rule was actually doing was counting layers, and layer count turned out to
be the one thing that could not be traded away: a slice has one blur radius, so a
crisp core inside a bloom is two layers or it is nothing. Held any longer, the rule
would have kept the beam permanently invisible in the name of a constraint that
protected nothing. It is replaced by the constraints that were doing the real work
— no `.shadow`, no growth in `PanelLayout.margin`, one mask, and the halo bounded
by the gutter — all of which are measurable.

**The third part, the head's radial bloom, is in on the same four constraints and
is not a `.shadow` wearing a hat.** It uses no `.shadow`, `PanelLayout.margin` did
not move, it is inside the one outward mask with the strokes, and its reach is
inside `cardInset`'s gutter — measured, not assumed: at `beamBloomDiameter` 96 the
total reach is still 34pt against 48, because the gradient's outer stops are
effectively zero past 30. It *is* a different primitive from the strokes — a
`RadialGradient` fill rather than a trimmed stroke — and that is now allowed,
because "a different primitive" was the ground that turned out to be protecting
nothing. What is still not allowed is a `.shadow`-as-bloom, which walks straight
into "no `.shadow()` on a view that fills its window", and anything that needs the
margin to grow.

A **static** glow is a different matter and is still out; see the fixed lamp
below.

A **gradient rim on the focused Card** — the "fixed lamp": a permanent
directional light on every Card's rim at rest, bright along the top and falling off
toward the bottom — is a static treatment, not motion, and so is not this ADR's
business. It is noted because the reference material for the Border Beam shows
exactly that, and the two are easily confused: a still frame cannot distinguish a
travelling segment from a fixed gradient. The beam travels; a Card gradient would
sit still and live in `Style.swift`. Neither is the other.

**It has been explicitly declined — "comet only, no fixed lamp" — and neither the
glow layer nor the head bloom is it arriving by the back door.** Both are lit only
while a sweep is running, both travel, and both are gone in 0.55s. Worth recording
four times over, because the reference image the halo has now been rebuilt against
**four times** *is* the fixed lamp — its rim highlight is static, both its Cards
have one, and nothing in the frame is sweeping — so the temptation to satisfy it by
drawing one is permanent, and it has now been asked for five times in words that do
not mention it. The fifth pass makes the temptation stronger rather than weaker,
because moving the light onto the Card's own edge is exactly what the reference does
and the only remaining difference is that ours *travels*. It is still not the lamp:
it is at a point, it moves, and it is not there at rest. The measured answer is that
the moving light gets there on its own: Δ87 to Δ256 at the head across four
backdrops in dark appearance, against Δ10 to Δ270 for the outward version, whose
low end was the entire problem. If a future pass concludes the lamp is needed after
all, that is a `Style.swift` change and a separate conversation, not a tightening of
this one.

### Verified by render, not by eye

The Panel itself still cannot be captured here — screen recording is not granted
and Cmd+Space is Spotlight's, the same gap `AGENTS.md` records for the show/hide
sequence. But the beam *can* be rasterised out of process with `ImageRenderer`,
and it had to be: the geometry tests passed for a beam that was invisible on
screen.

That is the lesson worth keeping. `BorderBeamTests` pinned the trim range and was
right about it the whole time; the tail's opacity ramp was deleting the beam
anyway. Twenty slices faded linearly — 1/20, 2/20, … — on top of colours already
carrying alpha put the trailing slices near 0.05 effective alpha, so all that
reached the screen was the leading slice: about 40pt of an intended 336pt.
"The maths is right" and "you can see it" were two different claims, and only one
of them was tested. `BorderBeamRenderTests` is the second claim, and it is the
only test in the suite that looks at pixels.

**And there is a third claim, which the one-layer comet found out the expensive
way: "you can see it" and "it reads as the thing it is for" are also different.**
Every render number in the paragraphs below was true of a beam whose head had no
halo at all, and the render test passed. What a render *can* be made to catch is a
measurable absence rather than a matter of degree, which is why
`theHeadHasAHaloAndACrispCore` exists: a floor on the alpha 1, 4, 8 and 16 points
outside the rim at the head's own phase. On the version that shipped, those four
numbers were 0, 0, 0, 0.

Two things came out of the render that no amount of reading would have settled:
the stepped falloff's opacity exponent had to be well below 1 — that was
`Style.beamFalloff`, now deleted with the ramp it corrected — and the slices need
`.butt` caps, because `.round` bulges half a line width past each slice's trim
range, so nineteen joints composite twice and the beam renders as a row of beads.
**That beading finding was made on the core and does not transfer, which was
checked rather than assumed.** Re-measured on the 20pt glow with the opacity ramp
in place, `.round` does not bead at all — 0 to 4 turnarounds in the along-beam
profile, the same as `.butt`. It is still rejected, and for a worse reason: the
bulges smear each slice's opacity into its neighbours and flatten the ramp back
into the tube. Both layers keep `.butt`; on the core it protects against beads and
on the glow it protects the falloff. A finding about a 2pt stroke was not a finding
about a 20pt one, and the general form this sentence used to take — "the slices
need `.butt` caps" — was doing work it had not earned.

**All four comets went through the same probe, and each pass missed the
measurement the next one needed.** The first moved three numbers and never
profiled *across* the beam. The second was tuned on that profile and never
profiled *along* it, so it shipped a constant-opacity band. The third took both
and then rasterised the thing as a PNG and looked at it, which is what caught the
core's flat cap and the banding in its blur ramp — neither of which appears in any
number the first two were taking. The fourth found that every number all three had
been taking was a **delta against a ground**, which is blind to the property being
complained about: a saturated blue and a desaturated near-white can measure the
same contrast on the same backdrop. It measured the core's absolute RGB and its
saturation instead, which is `theCoreIsADesaturatedHighlight`. The fifth found that
all four had been measuring against a **synthetic** ground and never against the
Card, which is `theBeamReadsAgainstAWhiteDesktop`.
`BorderBeamRenderTests` also carries the two
assertions the second and third failures correspond to:
`theGlowPeaksAtTheHeadAndDiesAtTheTail`, which is monotone along the beam plus a
4× head-to-far ratio (the tube failed both), and
`neitherEndOfTheLitSegmentIsAHardEdge`, which bounds the tangential gradient at
both termini and requires the drain-out's peak alpha to fall by more than 3×. That
last ratio is not decoration: with the travel-based `position` reverted but this
pass's blur left in, the drain-out is still monotone — 218, 203, 186, 166, 149 —
so monotone-only would have passed a terminus three times too bright at the end of
the lap.

`Style.beamStrokeWidth` is `beamWidth * 2`, which is the arithmetic — the mask
keeps the outer half of a centred stroke — but it was probed on the assumption
that the mask's own antialiased edge would eat part of the innermost pixel row and
2.0 would measure less than 1pt. It does not: a 2.0pt stroke measures exactly
1.00pt of outward coverage, all of it at full alpha, because the mask edge and the
stroke's inner edge are the same curve and cancel rather than compound. 2.5
measures 1.25pt, which is a fatter head than was asked for. The measurement was
taken on a straight edge; through a corner the inner edge feathers.

The tail survived its blur in dark appearance and the falloff was monotone: per
slice, peak alpha ran 0.95 at the head down to 0.07 at the trailing slice, with
the outward reach growing 1pt → 11.5pt as the blur grew 0 → 7.6. **All of which was
true, and the head still had no halo.** The measurement that mattered was never
taken: alpha as a function of *distance from the rim at a fixed phase*, rather than
peak alpha as a function of position along the segment. The falloff was profiled
along the beam and never across it.

That profile, taken across it, is what the two-layer version was tuned on. At the
head: alpha 247 on the rim, then 96, 92, 78, 60, 22 at 1, 4, 8, 12 and 20 points
out, reaching zero by 34. Along the tail the near-rim alpha peaks a little *behind*
the head — 159 at the slice one-quarter back against the head's own 96 — because an
interior slice has two neighbours' halos overlapping it and the leading slice has
one. A comet's coma sits behind its nucleus, so that was left alone rather than
corrected.

**The light-appearance problem the previous probe found was fixed, the fix was not
the one that pass predicted, and the fix itself then had to be partly undone.** It
had measured light's `beamHead` at Δ43/765 and light's `beamTail` at Δ127/765
against a white Card — the head a third the contrast of the tail it was supposed to
be leading — and correctly identified `beamHead` as the lever rather than
`beamTail`. Where it went wrong was the direction: it looked for a *darker* colour
and concluded that "no single opaque colour reads against both a white and a
mid-grey backdrop". Varying **saturation** instead: (0.20, 0.45, 1.00) measured
Δ207 on white, Δ149 on mid-grey and Δ250 on near-black, with no inversion. What
that closed was the inversion and what it opened was a saturated blue line where
the reference has a white one. The current colours, and the measured price of
desaturating them, are in "The white comet" below.

Dark appearance did not regress: head Δ400 on near-black (was 393), Δ259 on
mid-grey (was 255), Δ91 on white (was 90), with a halo behind it in each case
where there had been none.

The mask is now the one pixel-level *assertion* in the suite rather than a
number in a comment. Probed at insets of 0.5, 1, 2 and 4 points from the rim and
at five phases, the beam puts **zero** alpha inside `Style.cardShape`;
`BorderBeamRenderTests.nothingIsLitInsideTheRim` is that check, and it exists
because deleting one `.mask` leaves every geometry test in `BorderBeamTests`
passing. It still reads zero with the glow layer over it, at all four insets and
all five phases, which is the check that matters most now: the thing being masked
is a 20pt stroke blurred by up to 20 rather than a 2pt one blurred by 8.

**The fifth pass inverted that test along with the mask**, and it is now
`nothingIsLitOutsideTheRim`, reading zero at a 1pt outset at all five phases. The
old test was pinning the bug in place: it certified that the beam only ever touched
pixels this app does not own. The check is worth exactly as much pointed the other
way, and for the same reason — it is one modifier.

The render test also has to pad what it rasterises: the beam is entirely outside
the Card's bounds, `ImageRenderer` renders a view at its own size, and back when
the halo reached 11.5pt the unpadded render measured 327 lit pixels where the
padded one measured 1,039 — a test that would have failed for a reason unrelated to
the beam. The padding is now `cardInset + beamGlowTailBlur`, which clears a 34pt
reach; the extra area is transparent and contributes no lit pixels, so the baseline
does not move with it. Over that baseline of 3,468, mid-sweep went from **1,039**
lit pixels to **8,115**.

**The cost was measured rather than assumed, because Apple documents nothing
about whether `.blur` is GPU or CPU.** Rasterising the beam layer with
`ImageRenderer` — 40 slices across two layers, the outward mask, 34 frames, which
is a 0.55s sweep at 60fps — costs **2.6 ms per frame per Card unoptimised and
1.4 ms optimised**. Measured in the same harness with the glow layer switched off,
which is both the Reduce Transparency path and a stand-in for the one-layer
version: 2.3 ms and 1.0 ms. So the glow's own share is about **0.4 ms**, and it is
not the second layer's slice count that costs — it is the wider radii.

Three caveats that keep the number honest. `ImageRenderer` is a CPU rasteriser and
includes a bitmap allocation per frame, so on-screen compositing should be cheaper,
not dearer. Per-slice blur radius is *constant* through a sweep — slice *i* always
has radius *f(i)* and only its `from`/`to` move — so nothing animates a blur radius
and the unverified folklore about that invalidating a cache each frame does not
apply. And Tab sweeps two Cards at once, so the worst realistic case is roughly
twice these figures, which is still inside a 16.6 ms frame with room to spare.

**The remedy, if it is ever needed, is measured and not applied.** `beamSegments`
20 → 12 costs 1.11 ms instead of 1.43 in Release — about 22% — and coarsens the
falloff without breaking it. `beamMaskOutset` from three times the widest blur down
to two makes no measurable difference (1.40 against 1.43, inside the noise) and was
left at three for the margin. Neither is worth taking now.

**The absolute numbers in this sub-section do not transfer between passes, and
that is now known rather than suspected.** The third pass's timing loop, rendering
the same modifier at the same slice count, reads 3.98 ms in Release where this one
reads 1.43 — while the *lit-pixel* figure out of the same file reproduces 8,115
exactly, so the drawing is identical and the harness is not. Compare before and
after inside one run and ignore the absolute. On that basis the head bloom — a
`GeometryReader`, one `Path` build, one `trimmedPath` and one `RadialGradient` fill
per frame — costs 3.98 → 4.03 ms in Release and 4.50 → 4.67 ms in Debug: about 1%
and 4%, which is the cheapest thing in the effect.

**The third pass closed part of that gap without getting the Panel on screen, by
rasterising composited PNGs and looking at them, and the fourth started there
rather than ending there.** That is not the same as seeing it move, and it is not
the same as seeing it inside the Panel next to a Card's content and its shadow —
but it is the difference between reading a table and seeing a shape, and it is what
found the artefacts no table showed. Render the picture first; that is the standing
instruction for this feature now.

Still unverified, and only an eye on the running app can close it: whether 0.55s
reads as a comet or as a smear; whether the *travelling* bloom reads as light
coming off the border or as a moving smudge, which is the one judgement the numbers
cannot make; whether the visible comet, now roughly 150pt of the 303 that is
stroked, is long enough to be a tail; whether the mist crossing the bottom-trailing
chip at alpha 77 reads as light passing over it or as a flicker; whether light
appearance's inverted polarity — a dark line where dark appearance has a white one —
reads as the same effect or as a different one; whether Δ40 over a light Card on a
dark wallpaper is visible at all, which is the one number in this document that is a
genuine risk rather than a trade; and whether `ringSpin` in `onAppear` yields a
continuous rotation rather than one turn.

One caveat on all of the fifth pass's composited numbers, recorded because it is a
limit of the harness rather than of the beam: `ImageRenderer` rasterises
`glassEffect`, but not necessarily the way the compositor does, and it does not
even do it identically between configurations — the same code measured Δ87 over a
white desktop in Debug and Δ68 in Release. Its Cards also read *more* transparent
than Liquid Glass looks on screen, which if anything understates the fix, since a
more opaque Card is a more reliable ground. Every Δ quoted is a Debug figure and
the test floor is 50 to clear both. Every number is a named constant for exactly
that reason.
