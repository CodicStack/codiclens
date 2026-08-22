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
**dropping the blur and going on sweeping** — the crisp 1pt core still travels the
rim. That is not a weaker version of Reduce Motion's answer, it is a different
answer to a different question, and the two must stay independent: with Reduce
Motion on there is no beam at all, and with only Reduce Transparency on there is a
beam with no halo. Folding the read into `Motion.isReduced` would make those two
cases indistinguishable, and there is no state in which one implies the other.
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

### The beam is a comet, and only the paint changed

It was a 3.5pt bright bar with a stepped opacity falloff. It is now a **comet**: a
crisp 1pt head with a tail that progressively blurs out and dissolves, so it reads
as a light source travelling the rim rather than a line moving along it.

**Nothing in the decision above moved.** Same `trim`, same over-travel geometry,
same `Animatable` drive with no clock, same one lap, same "it means nothing", same
absent-under-Reduce-Motion. This is a paint change, which is why it is recorded
here rather than in an ADR of its own — a second ADR would restate this one and
leave two documents disagreeing about who owns the beam.

Four things are worth writing down, because each of them was a decision that had
an obvious wrong alternative.

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

**The blur ramp replaced the opacity ramp rather than joining it, and
`Style.beamFalloff` was deleted.** This is the same trap as last time, one turn
later. Blur already dims: it spreads the same alpha over more pixels. Multiplying
an opacity ramp on top of that is the exact double-multiplication that once left
only the leading slice on screen — 40pt of an intended 336pt — and `beamFalloff`
existed *solely* to undo a multiplication of that kind. Keeping it as well would
have been the bug wearing the fix's clothes. So the opacity across the slices is
flat, the blur is the whole falloff, and the ramp is **linear** in the slice's
position precisely so there is no exponent to invent. One ramp, one cause. The
head's blur is exactly 0, because the crisp leading edge against a dissolving tail
is the entire contrast the comet lives on.

**One layer, and it is masked outward.** There is no bloom layer, no `.shadow`,
no second stroke behind the first — a `.shadow`-as-bloom walks straight into "no
`.shadow()` on a view that fills its window", one layer in. And because a blur
spreads inward as much as outward, the whole beam layer is masked to the region
*outside* `Style.cardShape`, after the blur rather than before it, so the halo
never washes over the Card's icon, name or chips. The hard inner edge that leaves
— sitting exactly on the rim — is not a compromise: it *is* the "densest at the
border" reading the comet is for. What it costs is half the stroke, because a
`.stroke` is centred on its path, and `Style.beamStrokeWidth` is the measured
answer to that.

**The gutter between Cards grew for this, and the Panel did not.**
`Style.cardInset` went 6 → 12, so the visible gap between two Card surfaces went
12pt → 24pt and the drawn surface went 248 × 228 → 236 × 216. `beamTailBlur` is
bounded by the inset for a reason a render made concrete: the far tail reaches
about 11.5pt past the rim, which fits inside 12 and would not have fitted inside
6. `PanelLayout.cardWidth`, `cardHeight`, `panelWidth` and `panelHeight` did not
move — this Panel is fixed and does not resize for a decoration — so
`PanelLayoutTests` asserts the same sums it did before. `Style.beamSeamOffset` did
have to be re-probed, because it is a function of the surface size: 0.6195 became
**0.6192**, still landing at (6.41, 6.41), the 45° midpoint of the corner's own
curve.

`Motion.beamSweep` went 0.25s → 0.55s with it, and stayed `easeOut`. The
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

A **Glow** — a soft bloom outward from an edge — was considered alongside the
beam and is still out **as a layer**. It would be a different primitive, it walks
into "no `.shadow()` on a view that fills its window", and a bloom on the Slab
would need `PanelLayout.margin` to grow, which moves a number `PanelLayoutTests`
asserts. It may also be re-specifying something that already exists: the focused
Card is already brighter and more defined at the edge.

The comet's blurred tail is not that Glow arriving by the back door, and the
distinction is the one that keeps the rule enforceable: the tail is **the same
single stroke** the head is, blurred, inside one layer and one mask. A Glow is a
*second* thing drawn behind a first. Nothing here draws twice, nothing uses
`.shadow`, and `PanelLayout.margin` did not move — `Style.cardInset` did, which is
padding inside the Panel rather than the Panel's own reserve. If the next proposal
needs a second pass behind the beam to be visible, it is the Glow and it is still
out.

A **gradient rim on the focused Card** — bright along the top, falling off toward
the bottom — is a static treatment, not motion, and so is not this ADR's
business. It is noted because the reference material for the Border Beam shows
one, and the two are easily confused: a still frame cannot distinguish a
travelling segment from a fixed gradient. The beam travels and lives on the
Slab; a Card gradient would sit still and live in `Style.swift`. Neither is the
other.

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

Two things came out of the render that no amount of reading would have settled:
the stepped falloff's opacity exponent had to be well below 1 — that was
`Style.beamFalloff`, now deleted with the ramp it corrected — and the slices need
`.butt` caps, because `.round` bulges half a line width past each slice's trim
range, so nineteen joints composite twice and the beam renders as a row of beads.
The caps are unchanged and stay `.butt`.

**The comet went through the same probe, and it moved three numbers and found one
problem.**

`Style.beamStrokeWidth` is `beamWidth * 2`, which is the arithmetic — the mask
keeps the outer half of a centred stroke — but it was probed on the assumption
that the mask's own antialiased edge would eat part of the innermost pixel row and
2.0 would measure less than 1pt. It does not: a 2.0pt stroke measures exactly
1.00pt of outward coverage, all of it at full alpha, because the mask edge and the
stroke's inner edge are the same curve and cancel rather than compound. 2.5
measures 1.25pt, which is a fatter head than was asked for. The measurement was
taken on a straight edge; through a corner the inner edge feathers.

The tail survives its blur in dark appearance and the falloff is monotone: per
slice, peak alpha runs 0.95 at the head down to 0.07 at the trailing slice, with
the outward reach growing 1pt → 11.5pt as the blur grows 0 → 7.6. As luminance
contrast against a dark Card that is Δ639/765 at the head and Δ24/765 at the far
tail, stepping smoothly between. Nothing ends in a cut: the trailing slice's own
butt cap is smeared by 7.6pt of isotropic blur, so the comet's end is an 11pt
feather. The sharpest transition in the whole effect is the first joint *behind*
the head, 0.95 → 0.70, which is the crisp-head-against-dissolving-tail contrast
the comet is built on rather than an artefact.

**The problem the probe found is light appearance, and it is older than the
comet.** Against a light Card — white-tinted glass over a light wallpaper, the
worst case `Palette` names in its own comment — the light `beamHead` measures
Δ43/765 and the light `beamTail` Δ127/765. The head is a *third* the contrast of
the tail, so the comet is inverted: the brightest part of it is the part that is
supposed to be dissolving. Against a mid-grey ground the two swap over — head
Δ182, tail Δ15 — because a pale blue reads on grey and a saturated blue reads on
white. That is a property of the existing pair of colours and not of the comet;
what the comet changed is that there is now 1pt of visible rim carrying it instead
of 3.5pt, so an existing weakness is three and a half times less area. Retuning
`beamTail` alone, which was the anticipated fix, measurably makes it *worse* —
the tail is already the stronger of the two on a light ground. **So nothing was
retuned, and this is recorded as the open question rather than papered over.** The
fix, if the eye agrees with the numbers, is `beamHead` in light appearance going
darker and more saturated, and it needs a real screen to choose on, because no
single opaque colour reads against both a white and a mid-grey backdrop: a
candidate that measured Δ236 on white measured Δ1 on mid-grey.

The outward mask is now the one pixel-level *assertion* in the suite rather than a
number in a comment. Probed at insets of 0.5, 1, 2 and 4 points from the rim and
at five phases, the beam puts **zero** alpha inside `Style.cardShape`;
`BorderBeamRenderTests.nothingIsLitInsideTheRim` is that check, and it exists
because deleting one `.mask` leaves every geometry test in `BorderBeamTests`
passing. The render test also had to start padding what it rasterises: the beam is
now entirely outside the Card's bounds, `ImageRenderer` renders a view at its own
size, and the unpadded render measured 327 lit pixels where the padded one
measures 1,039 — a test that would have failed for a reason unrelated to the beam.

**The cost was measured rather than assumed, because Apple documents nothing
about whether `.blur` is GPU or CPU.** Rasterising the beam layer with
`ImageRenderer` — 20 slices, the outward mask, 34 frames, which is a 0.55s sweep
at 60fps — costs about 1.3 ms per frame per Card in Debug and 0.9–1.3 ms in
Release. The blur's own share is 0.15–0.25 ms of that: 20 slices with the blur
switched off measured 1.01 ms against 1.27 ms with it on. Dropping to 12 segments
saves about 0.15 ms and is not worth the coarser falloff. Two caveats that keep
the number honest: `ImageRenderer` is a CPU rasteriser and includes a bitmap
allocation per frame, so on-screen compositing should be cheaper, not dearer; and
Debug and Release are within noise of each other precisely because the cost is
CoreGraphics rather than Swift. Per-slice blur radius is also *constant* through a
sweep — slice *i* always has radius *f(i)* and only its `from`/`to` move — so
nothing animates a blur radius and the unverified folklore about that invalidating
a cache each frame does not apply here.

Still unverified, and only an eye can close it: whether 0.55s reads as a comet or
as a smear on a real screen, whether the light-appearance inversion above is as
bad as it measures, whether 8pt of tail blur is too much or too little glow in the
24pt gutter, and whether `ringSpin` in `onAppear` yields a continuous rotation
rather than one turn. Every number is a named constant for exactly that reason.
