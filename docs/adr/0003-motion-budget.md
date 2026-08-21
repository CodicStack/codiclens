---
status: accepted
---

# Animate the Panel, not its contents

Only three things animate: the Panel appearing, the Panel dismissing, and a Slab changing size. Phase advances, Card content swaps, and selection movement are **instant, deliberately**.

This came from measuring the reference app frame-by-frame at 60fps. Its show is blur + fade + scale together in ~100ms with a 1.04 overshoot; its hide is ~120ms with a one-frame scale-*up* anticipation kick. Everything inside its panel hard-cuts. That combination is what reads as "responsive and native without being overly animated" — the quality we're chasing.

The trap this ADR exists to prevent: animating phase transitions feels like an obvious polish win and is actively wrong. An animated selection highlight lags the keypress; an animated card swap delays information the user already asked for.

## Consequences

- Exactly three curves exist, in `Motion.swift`: `entrance` (show/hide), `resize` (Slab size), `snappy` (scroll-to-selection). Every animation in the app references one of the three; nothing declares its own.
- Reduce Motion and the user-facing animations toggle both collapse all three in one place.
- A horizontal shake signals no-match, replacing today's silent fallback to a text Subject.

## Amendment: an indeterminate system control is not in the budget

OCR is awaited out of process, so for the first time the Panel has a moment with
no answer yet, and the Slab shows a spinner beside the "Reading text…" row.

That is not a fourth curve and it does not belong in `Motion.swift`. The three
curves are *transitions* — they start, they finish, they are gone. A spinner
loops, and it reports progress rather than decorating a transition, which is the
distinction this budget is actually about. It is a system `ProgressView`, no more
this app's motion vocabulary than an SF Symbol is its iconography.

Two things follow, and neither is optional:

- **It stops under Reduce Motion.** `Motion.collapsed(_:)` turns an `Animation`
  into a cross-fade, which is meaningless for a loop — so the collapse cannot be
  delegated to it. Reduce Motion means no perpetual motion; the row's text stays
  and still says the true thing.
- **It never appears alone.** A bare spinner does not say what it is waiting for.

It flashes on a fast image, and that was chosen with the flash known: OCR on a
small screenshot finishes in well under 200ms. The alternative is a threshold
before showing it, which is an `asyncAfter` — a third exception to the
no-timing-hacks rule, for the rarer half of the cases. Not worth it.
