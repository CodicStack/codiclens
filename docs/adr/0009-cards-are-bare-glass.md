---
status: accepted
---

# Cards are bare glass, and focus is Emphasis

A Card is `.glassEffect(.regular)` in a rounded rect with **nothing painted on it** — no
grey material tint, no rim hairline, no `.shadow` of its own, no `.clipShape`, no specular
wash, no inner shadow, no Lamp. **No Card carries colour, focused or not**; every Card is
the same untinted `.regular` glass. Focus is **Emphasis**: the focused Card stands at full
size with its content at full opacity, while an unfocused Card is inset by
`Style.unfocusedCardShrink` (10pt on each side in layout — a 200pt Card drawn at 180) with its
content at `Style.unfocusedContentOpacity` (0.6). The inset is layout and never a transform:
`GlassEffectContainer` builds its glass shapes from layout frames and ignores a
`.scaleEffect`'s anchor, so glass and content shrank about different anchors and the content
ended up ~10pt off-centre.
Emphasis moving is **instant** — `.animation(nil, value: focused)` — because a Card that
grows or dims because the keyboard moved is information, and animating it lags the keypress.
The three Cards are separate tiles with a ~12pt gap and **no surface behind them**, and they
never fuse. All glass — Cards and the Results Slab — lives in one `GlassEffectContainer`
whose `spacing` is below the gap, so nothing merges and every piece of glass matches in
brightness. **Arrival** is `.glassEffectTransition(.matchedGeometry)` on the existing
`Motion.resize` curve: a new Card grows out of the Card before it, while the Card's content
still hard-cuts. Geometry: ~200×200 drawn surface, radius 20, icon 76, `cardInset` 6. Text
Subjects get a monochrome fill in the Card's **content** layer rather than a tinted glass,
so the glass keeps one meaning, and no Card branches on `colorScheme`.

On screen the previous Card read as "frosted plastic, not professional" in both appearances,
and the cause was additive: a grey `.tint(surfaceTint)`, three static gradients, the Card's
own `.shadow` and a `.clipShape`, all fighting the material. WWDC25 219 ("Meet Liquid
Glass") is explicit that lensing, the specular rim and an adaptive shadow are the material's
own behaviour and must not be re-drawn by hand; Apple Developer Forums thread 797806 records
that clipping the glass cuts its own shadow into a grey halo; WWDC25 310 forbids a fill as a
sibling behind glass; WWDC25 323 and HIG *Materials* put colour on glass as a **tint**, not
as a fill over it. The Border Beam — "the beam is ass" — and the Lamp were six-plus passes
of trying to make a lone, uncoloured Card look expensive: both were light drawn *on* the
Card to say which one had the keyboard. Emphasis says that with the Card's own size and the
presence of its content — no colour, nothing extra drawn — so neither has anything to carry.

## Considered options

- **Tuna-faithful: an outer slab behind the Cards plus a solid blue fill on the focused one.**
  Rejected by the user on sight — "we have to be more unique and not the exact same as Tuna",
  "I don't want the back card". Tuna is macOS 15 and `NSVisualEffectView`, so slab plus fill is
  a workaround for not having Liquid Glass (ADR 0002); WWDC25 310 warns against the fill.
- **Selection Tint — accent-coloured glass on the focused Card.** Built 2026-09-11 and
  rejected the same day on sight: the blue read as awful; the app carries no colour.
- **One fused glass body holding all three Phases.** Rejected by the user: the Panel reads as
  three separate tiles with a gap, not one body with three regions (CONTEXT.md, **Card**).
- **Keep the Border Beam and rebuild the Card under it.** Rejected: the beam was the symptom.
  With Emphasis carrying focus there is nothing left for it to say — and it cost a
  pixel-render suite and a per-frame `trimmedPath` to say it.

## Consequences

- `BorderBeam.swift` is deleted, with every beam dial in `Style.swift`, `CardBeamIdentity`,
  `BorderBeamTests`, `BorderBeamRenderTests` and the `beamLoop` `UserDefaults` key. The Lamp,
  the specular wash, the inner shadow and `writingTint` go with them. The theme picker stays.
- **ADR 0003's beam sections are history, not guidance.** The motion budget itself stands:
  three Transition curves, and Decoration is now the Loading Ring alone.
  `Motion.isTransparencyReduced` is **deleted** with the beam that read it. Arrival is a
  Transition and uses `resize`; under Reduce Motion the glass transition is `.identity`.
- **ADR 0001's "each Slab draws its own SwiftUI shadow" now applies to the Results Slab only.**
  A Card's shadow is the material's.
- `CONTEXT.md` changes: **Emphasis** and **Arrival** are new, **Card** is rewritten, and
  **Lamp**, **Border Beam** and **Selection Tint** are retired words — not to be reintroduced
  under a new name.
- The "no accent colour" rule (2026-08 →) **stands**. What changed is its cost: focus no
  longer needs a rim, a lamp or a beam to be shown without colour — size and presence show it.
