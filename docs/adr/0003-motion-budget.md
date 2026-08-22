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
**dropping its glow layer and going on sweeping** — the crisp 1pt core still
travels the rim. That is not a weaker version of Reduce Motion's answer, it is a
different answer to a different question, and the two must stay independent: with
Reduce Motion on there is no beam at all, and with only Reduce Transparency on
there is a beam with no halo. Folding the read into `Motion.isReduced` would make
those two cases indistinguishable, and there is no state in which one implies the
other. The layer is dropped *whole* rather than un-blurred — that was the answer
while the beam was one layer, and it stopped being right when the glow got its
own 10pt-wide source band: un-blurring that is not a quieter halo, it is a flat
bar travelling the rim.

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
feature gets wrong later, which is why it is written here and in `CONTEXT.md`
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

### The beam is a comet, and only the paint changed — twice

It was a 3.5pt bright bar with a stepped opacity falloff. Then it was a **comet**
in one layer: a crisp 1pt head, a per-slice blur ramping from 0 at the head, one
sliced stroke, masked outward. It is now a comet in **two layers** — a crisp core
inside a soft glow — and the section below records both steps, because the second
one is a correction of the first and the correction is the valuable part.

**Nothing in the decision above moved, through either step.** Same `trim`, same
over-travel geometry, same `Animatable` drive with no clock, same one lap, same
"it means nothing", same absent-under-Reduce-Motion. These are paint changes,
which is why they are recorded here rather than in ADRs of their own — a second
ADR would restate this one and leave two documents disagreeing about who owns the
beam.

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

#### The two-layer comet

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
there is no exponent to invent. The head-to-tail *colour mix* is not that ramp:
`beamGlowHead` and `beamGlowTail` are two named colours whose alphas happen to
differ (0.80 → 0.55), exactly as the core's pair always has (0.95 → 0.70), and
interpolating between two colours is what `BeamSlice` has always done. The rule is
"no computed exponent over the blur", not "no alpha may ever differ".

**The core's blur is still exactly 0 at the head, and that is now correct rather
than merely defensible**, because the halo is a different layer. What was wrong
was not the crisp core; it was there being nothing else.

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

`Motion.beamSweep` went 0.25s → 0.55s with the first paint change, and stayed
`easeOut`. It **stayed 0.55 through the second**, which was decided rather than
skipped: the glow got wider *outward*, not longer along the rim. The lit segment is
still `beamTailFraction` of the perimeter, so there is exactly as much rim to
travel and exactly as much of it lit at once, and duration answers segment length
and perimeter. A bigger halo is easier to see, not slower to read. The
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
— no `.shadow`, no growth in `PanelLayout.margin`, one mask, and the glow bounded
by the gutter — all of which the two-layer beam satisfies and all of which are
measurable.

A **static** glow is a different matter and is still out; see the fixed lamp
below.

A **gradient rim on the focused Card** — the "fixed lamp": a permanent
directional light on every Card's rim at rest, bright along the top and falling off
toward the bottom — is a static treatment, not motion, and so is not this ADR's
business. It is noted because the reference material for the Border Beam shows
exactly that, and the two are easily confused: a still frame cannot distinguish a
travelling segment from a fixed gradient. The beam travels; a Card gradient would
sit still and live in `Style.swift`. Neither is the other.

**It has been explicitly declined — "comet only, no fixed lamp" — and the two-layer
glow is not it arriving by the back door.** The glow is lit only while a sweep is
running, it travels, and it is gone in 0.55s. Worth recording because the reference
image the glow was rebuilt against *is* the fixed lamp, so the temptation to
satisfy it by drawing one is permanent. The measured answer is that the moving glow
gets there on its own: Δ71–135 of halo one point outside the rim where the previous
version had zero, falling off over 24–34pt. If a future pass concludes the lamp is
needed after all, that is a `Style.swift` change and a separate conversation, not a
tightening of this one.

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
The caps are unchanged and stay `.butt`, and they matter more on the glow layer,
whose stroke is twenty times wider than the core's.

**Both comets went through the same probe. The first moved three numbers and
missed the one measurement that mattered; the second was tuned on that
measurement.**

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

**The light-appearance problem the previous probe found is fixed, and the fix is
not the one that pass predicted.** It had measured light's `beamHead` at Δ43/765
and light's `beamTail` at Δ127/765 against a white Card — the head a third the
contrast of the tail it was supposed to be leading — and correctly identified
`beamHead` as the lever rather than `beamTail`. Where it went wrong was the
direction: it looked for a *darker* colour and concluded that "no single opaque
colour reads against both a white and a mid-grey backdrop", having measured a
candidate at Δ236 on white and Δ1 on mid-grey. Every candidate in that search was
varying lightness, and lightness is exactly the axis on which the two grounds
disagree. Varying **saturation** instead: (0.20, 0.45, 1.00) sits at mid luminance
and 247 units from white, 255 from black, and measures Δ207 on white, Δ149 on
mid-grey and Δ250 on near-black. No inversion in any of the three, and the head is
the strongest element in all of them.

Dark appearance did not regress: head Δ400 on near-black (was 393), Δ259 on
mid-grey (was 255), Δ91 on white (was 90), with a halo behind it in each case
where there had been none.

The outward mask is now the one pixel-level *assertion* in the suite rather than a
number in a comment. Probed at insets of 0.5, 1, 2 and 4 points from the rim and
at five phases, the beam puts **zero** alpha inside `Style.cardShape`;
`BorderBeamRenderTests.nothingIsLitInsideTheRim` is that check, and it exists
because deleting one `.mask` leaves every geometry test in `BorderBeamTests`
passing. It still reads zero with the glow layer over it, at all four insets and
all five phases, which is the check that matters most now: the thing being masked
is a 20pt stroke blurred by up to 20 rather than a 2pt one blurred by 8.

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

Still unverified, and only an eye can close it: whether 0.55s reads as a comet or
as a smear on a real screen; whether 34pt of reach in a 48pt gutter is the right
amount of glow or too much; whether the light appearance's *darkening* halo reads
as blue light or as a blue shadow, which is the one thing the numbers genuinely
cannot settle, since Δ207 of perceptual distance is Δ207 whichever side of the
ground it falls; and whether `ringSpin` in `onAppear` yields a continuous rotation
rather than one turn. Every number is a named constant for exactly that reason.
