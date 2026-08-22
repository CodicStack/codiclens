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

### The two members

**The Border Beam** belongs to a **Card** — Subject, Action or Target — and it
sweeps around that Card when the Card **takes the keyboard**. It means nothing.
It is emphatically **not** tied to OCR, to `isOCRInFlight`, or to any waiting or
in-flight state — that misreading is the single most likely way this feature gets
wrong later, which is why it is written here and in `CONTEXT.md` both. It shares
a drawing primitive with the Loading Ring — an animated `trim` along a stroked
path — and nothing else.

Exactly one Card holds the keyboard at a time and focus moves on every Tab,
Shift+Tab, Enter and Escape, so "this Card just took the keyboard" is one sweep
per Phase move on the Card that now owns it, with nothing to de-duplicate.
`CardBeam` is that policy and `borderBeam(trigger:)` is the primitive underneath
it; the split is deliberate, so the sweep itself knows nothing about focus.

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

**Two tradeoffs, both chosen knowingly.**

The sweep is a **constant duration** over a **variable perimeter**. The Slab runs
from 280 × 70 to 800 × 360 — a 700pt perimeter to a 2,320pt one — so the beam
travels 3.3× faster on the largest Slab than the smallest. Constant *speed* was
the alternative and was rejected for a good reason: a normalized 0 → 1 progress
is the only thing a curve can shape, and constant speed makes easing impossible
by definition. Expressiveness won over uniformity.

At 0.25s the beam is also well past the ~1,000–2,000 pt/s that the eye tracks
comfortably, so it reads as a whip rather than as a segment you follow. That is
the intent — "fast and snappy" was the brief — and it is why the curve is
`easeOut` rather than `easeInOut`: perceived speed is set by the velocity at the
*start* of a motion, and `easeOut` leaves the mark at full speed. `easeInOut`
reads as mass and considered weight, which is a different quality than the one
asked for, and slower-feeling because it spends its first frames accelerating.

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
beam and is out. It is a different primitive, it walks into "no `.shadow()` on a
view that fills its window", and a bloom on the Slab would need
`PanelLayout.margin` to grow, which moves a number `PanelLayoutTests` asserts.
It may also be re-specifying something that already exists: the focused Card is
already brighter and more defined at the edge.

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
`Style.beamFalloff` has to be well below 1, and the slices need `.butt` caps —
`.round` bulges half a line width past each slice's trim range, so nineteen
joints composite twice and the beam renders as a row of beads.

Still unverified, and only an eye can close it: whether 0.25s reads as fast or as
a flicker on a real screen, whether the blue is right over a wallpaper, whether
`beamSeamOffset` puts the seam close enough to the top-left at every Slab size,
and whether `ringSpin` in `onAppear` yields a continuous rotation rather than one
turn. Every number is a named constant for exactly that reason.
