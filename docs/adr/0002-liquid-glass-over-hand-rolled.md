---
status: accepted
---

# Liquid Glass, not a hand-rolled blur

Slab and Card materials use the macOS 26 Liquid Glass API (`.glassEffect`, `GlassEffectContainer`). Deployment target is 26.4, so no `#available` gating is needed anywhere.

This is worth recording because our visual reference, Tuna, does **not** use Liquid Glass — static inspection of its shipping binary shows `NSVisualEffectView` plus an animatable `CALayer` `CIGaussianBlur.inputRadius`, with zero Liquid Glass symbols. Someone comparing the two apps will notice the difference and may assume we made a mistake.

We didn't. Tuna's deployment target is macOS 15, so Liquid Glass was not available to them; the hand-rolled blur is a compatibility constraint we don't share. What we take from Tuna is its *geometry, its tint-as-selection signal, and its restraint* — not its material implementation.

## Consequences

- Material tokens live in one place (`Style.swift`). Before this decision the same `.ultraThinMaterial` + opacity-overlay recipe was copy-pasted across four files with drifting corner radii.
- The old dark-mode treatment (`Color.black.opacity(0.92)` over a material) is gone. It was effectively opaque and was the reason the app read as "solid, not glass."
- Both light and dark appearances are supported; the theme picker stays. Light mode gets a stronger material and a defined rim, because symmetric treatment washes out on light wallpapers.
