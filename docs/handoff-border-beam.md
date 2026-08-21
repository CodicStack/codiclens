# Handoff: Border Beam on the Slab, and the OCR loading ring

Written 2026-08-21, at the end of the OCR work. Nothing here is built. The next
session should be a grilling, but three things are already settled by the user
and are **not** open — marked **Settled** below.

Read `AGENTS.md` (the whole **Visual layer** section) and
`docs/adr/0003-motion-budget.md` including its amendment before anything else.

## The two pieces

**Settled — the loading ring.** A three-quarter circle border, spinning. A
constant-length arc, roughly 270° of the circle, rotating. **It is decorative.
There is no deeper meaning and it is not tied to recognition progress** — Vision
reports none anyway. Do not build a ring that fills once and waits, and do not
dress it up as progress. "It should just look cool" is the whole brief.

**Settled — the Border Beam goes on the Slab.** The whole surface, the big
rounded rectangle. Not the Cards.

They are the same primitive — an animated `trim` along a stroked path — which is
why they belong in one session. A **Glow** is a different primitive (a soft bloom
outward from an edge, possibly static) and is in scope only for the vocabulary
question below.

## What exists right now

- `SearchView.swift` → `ResultsListView.readingTextState`: a system
  `ProgressView(.small)` beside the text "Reading text…". Reads `Motion.isReduced`
  and omits the spinner entirely when motion is off, keeping the text. **This is
  the thing the ring replaces.**
- `CommandCoordinator.isOCRInFlight` is the flag it renders off. It also gates
  `canReportNoResults` and forces the Slab to show. Do not change that wiring.
- `Style.slabShape` is `RoundedRectangle(cornerRadius: slabRadius, style:
  .continuous)`. `Style.swift` also holds `cardShape` and `resultShape`, same
  form. `slabSurface()` and `cardSurface(focused:writing:)` are the modifiers.
- `docs/adr/0003-motion-budget.md` has an **amendment** that justifies a *system*
  `ProgressView` on the grounds that it is not this app's motion vocabulary — "no
  more this app's motion vocabulary than an SF Symbol is its iconography."
  Replacing it with a hand-drawn spinning arc **invalidates that reasoning**: a
  custom looping animation *is* this app's vocabulary and belongs in
  `Motion.swift` or nowhere. Expect to rewrite that amendment, not extend it.

## The shape question, answered before you ask it

The user asked whether the Slab's shape would have to change to draw a border
effect on it. **No.**

`Style.slabShape` is a `RoundedRectangle`, which conforms to `InsettableShape`,
so `strokeBorder` works, and `trim(from:to:)` works on its path. The
`ConcentricRectangle` warning in `AGENTS.md` — that it is a `Shape` and not an
`InsettableShape`, so it has no `strokeBorder` — is a caution about a type
`grep` finds **nowhere in the app**. It would only bite if someone reached for
concentric radii to make a beam follow a Card's corner, and the beam is going on
the Slab.

The real craft problem is different, and worth knowing up front: the Slab is a
**wide** rectangle, not a square. A beam driven by a *rotating conic gradient*
sweeps at a constant angular rate, so it appears to race along the long edges and
crawl at the corners. Driving it with a `trim` along the shape's own path instead
is uniform in path length, which is what actually looks even. Same reason the
ring is easy and the rectangle is not.

## Constraints that will bite

All documented in `AGENTS.md`; collected here because a border effect walks into
every one.

- **Stroke a rim *after* clipping, not before.** `overlay { strokeBorder }` then
  `clipShape` halves the hairline and aliases along the curve. The Slab already
  has a rim; the beam has to coexist with it, not fight it.
- **`FloatingPanel.hasShadow` must stay `false`**, and **no `.shadow()` on a view
  that fills its window** — it clips into a hard band down two edges instead of a
  falloff. A Glow *is* a blur outward, so this is exactly the trap it falls into.
  `PanelLayout.margin` exists for this, and `PanelLayoutTests` pins its
  relationship to `Style.shadowRadius`. A Glow on the Slab may need that margin to
  grow, which moves a tested number.
- **`Style.swift` owns every radius, material, tint and rim**, and is the only
  place that branches on `colorScheme`. The beam's colour and width, and the
  ring's stroke width, live there — not in the view drawing them.
- **`Motion.swift` owns every curve, and there are three.** Both the beam and the
  ring are perpetual loops — a fourth *species*, not a fourth curve. See the
  frontier's first question.
- **No timing hacks.** No `asyncAfter`, `sleep` or `usleep` — including "wait
  200ms before showing the ring", already rejected during the OCR grilling. The
  ring appears the instant `isOCRInFlight` goes true and flashes on a fast image;
  that was chosen knowingly.
- **A tint heavy enough to read as a colour stops glass being glass.** The Slab is
  `.regular` material with a light wash. A beam bright enough to see is a bright
  thing sitting on glass, and the two have to be judged together.

## The frontier for that grilling

Roughly in dependency order:

1. **Does the motion budget bend, or is the beam bounded to a state?** Always-on
   decoration versus lit only while something is true — Panel visible, OCR in
   flight, Slab has Results. Bounded needs no ADR 0003 rewrite; always-on needs a
   real one. The ring is inherently bounded (it exists only while
   `isOCRInFlight`), so this is really a question about the beam.
2. **What drives the beam?** A continuous idle loop, or a one-shot sweep on an
   event (the Slab arriving, a Phase advancing). A one-shot sweep is a
   *transition* and fits the existing budget almost unchanged — worth putting to
   the user, because "looks cool" may not require perpetual motion.
3. **Reduce Motion.** `Motion.collapsed(_:)` turns an `Animation` into a
   cross-fade and cannot express "stop a loop" — the OCR spinner had to read
   `Motion.isReduced` directly. Does the beam vanish, freeze lit, or degrade to
   the static Glow? (That last is elegant and worth offering.) Same question for
   the ring: with motion off, does the row keep text only, as today?
4. **Is the Glow in or out?** A separate primitive with its own shadow/margin
   problem. It may also be re-specifying something that exists — `AGENTS.md` says
   the focused Card is already "brighter and more defined at the edge".
5. **Does any of it survive the no-accent-colour rule?** `CONTEXT.md`: "there is
   no accent colour anywhere in the app." A beam is usually a colour gradient, so
   either the rule bends or the beam is built from white and luminance alone.
6. **Where do the Cards stand?** The beam is settled as Slab-only. Is that
   permanent, or does a Card get one later — which is when the
   `ConcentricRectangle` problem becomes real.

## Files it will touch

`Style.swift` (colours, widths, the beam and ring shapes), `Motion.swift` (if the
loop becomes vocabulary), `SearchView.swift` (`readingTextState`),
`PanelView.swift` or wherever `slabSurface()` is applied, and
`docs/adr/0003-motion-budget.md`. New `CONTEXT.md` terms for **Border Beam** and,
if it survives question 4, **Glow** — kept apart, they are two things.

## Out of scope

Everything OCR. It is built, tested and documented — ADR 0007, ADR 0008, the 0003
amendment, and five `CONTEXT.md` terms. The only OCR-adjacent change here is what
`readingTextState` draws.
