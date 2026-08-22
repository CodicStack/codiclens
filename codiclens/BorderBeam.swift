import SwiftUI

/// A bright segment travelling once around a Card's rim.
///
/// **It means nothing.** It belongs to a Card *as a surface*: it fires when that
/// Card takes the keyboard and that is the whole of it. It is not tied to OCR,
/// to `isOCRInFlight`, to searching, or to any other in-flight or waiting state
/// — reading it as one is the single most likely way this feature gets broken
/// later, which is why it is written here, in `docs/adr/0003-motion-budget.md`
/// and in `CONTEXT.md` all three. It shares a drawing primitive with the Loading
/// Ring — an animated `trim` along a stroked path — and nothing else.
///
/// It ran on the Results Slab's rim before it ran on the Cards'. Nothing about
/// the drawing changed in the move: the shape it strokes is `Style.cardShape`
/// rather than `Style.slabShape`, and every Card being one size is what let
/// `Style.beamSeamOffset` become exact.
///
/// Driven exactly the way `Shake` is driven, and structurally a copy of it: an
/// `Animatable` carrying a `progress` that a `withAnimation` steps one whole
/// unit, with no clock and no `TimelineView` anywhere. Phase is measured against
/// the step's own start rather than by `floor`, which is what lets a re-trigger
/// part-way through a sweep restart cleanly instead of wrapping round into a
/// second lap. `beamSweep` is an `easeOut` and will not overshoot, but the clamp
/// is the same one for the same reason.
///
/// It is `internal` rather than `private` only so `trimRange` can be pinned by a
/// test; everything else about it is as tight as it can be.
struct BorderBeam: ViewModifier, Animatable {
    var progress: Double
    let target: Double
    let reduced: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    // MARK: - The over-travel geometry

    /// The trim range of the lit segment at a given sweep phase.
    ///
    /// Total travel is `1 + tail`, so the head enters through the seam and the
    /// tail leaves through the same seam — one discontinuity-free entry and exit
    /// rather than a beam that pops into being fully formed. `trim`'s clamping
    /// gives the grow-in and the drain-out for free: at phase 0 both ends are 0
    /// and nothing is lit, from the moment `u` passes `tail` the whole segment
    /// is lit, and at phase 1 `u` is `1 + tail` so both ends are 1 and nothing
    /// is lit again.
    static func trimRange(phase: Double, tail: CGFloat) -> (from: CGFloat, to: CGFloat) {
        let u = CGFloat(phase) * (1 + tail)
        return (
            from: min(max(u - tail, 0), 1),
            to: min(max(u, 0), 1)
        )
    }

    // MARK: - Slicing

    /// One flat-coloured sub-stroke of the tail.
    private struct Slice: Identifiable {
        let id: Int
        let from: CGFloat
        let to: CGFloat
        /// 0 at the trailing end of the lit segment, 1 at the head.
        let position: Double
    }

    /// The lit segment, cut into `Style.beamSegments` pieces of equal path
    /// length and rotated onto the seam.
    ///
    /// Equal in the trim parameter, which *is* path length along
    /// `Style.cardShape` — that uniformity is the entire reason the falloff is
    /// stepped rather than a gradient. A slice that crosses the seam comes back
    /// as two pieces, because `trim` does not wrap.
    private var slices: [Slice] {
        let range = Self.trimRange(phase: phase, tail: Style.beamTailFraction)
        guard range.to > range.from else { return [] }

        let span = range.to - range.from
        let count = max(Style.beamSegments, 1)
        var out: [Slice] = []

        for i in 0..<count {
            let step = span / CGFloat(count)
            let start = seam(range.from + step * CGFloat(i))
            let end = start + step
            let position = Double(i + 1) / Double(count)

            if end <= 1 {
                out.append(Slice(id: out.count, from: start, to: end, position: position))
            } else {
                out.append(Slice(id: out.count, from: start, to: 1, position: position))
                out.append(Slice(id: out.count, from: 0, to: end - 1, position: position))
            }
        }
        return out
    }

    /// A fraction along `Style.cardShape`'s own path, moved to where the seam is
    /// and wrapped into `0..<1`.
    private func seam(_ fraction: CGFloat) -> CGFloat {
        let shifted = (fraction + Style.beamSeamOffset).truncatingRemainder(dividingBy: 1)
        return shifted < 0 ? shifted + 1 : shifted
    }

    private var phase: Double {
        min(max(progress - (target - 1), 0), 1)
    }

    func body(content: Content) -> some View {
        content.overlay {
            // Absent under Reduce Motion, not slowed down: a travelling
            // highlight has nothing to cross-fade to, so `Motion.collapsed(_:)`
            // cannot express its collapse.
            if !reduced {
                ZStack {
                    ForEach(slices) { slice in
                        BeamSlice(from: slice.from, to: slice.to, position: slice.position)
                    }
                }
                // The beam is light on the rim, not a hit target. The Card row's
                // own frame is what `hitRegions.cards` reports.
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - The Card-level policy

/// When a Card sweeps: once, each time it takes the keyboard.
///
/// **Deliberately separate from `borderBeam(trigger:)`, which stays the
/// primitive.** The primitive is a *drawing* — one lap per increment of an
/// `Int`, knowing nothing about why the number moved — and it is the thing
/// `BorderBeamTests` and `BorderBeamRenderTests` pin. This is the *policy*, and
/// the reason it is a modifier of its own is that it would otherwise be the same
/// three lines of `@State` and `onChange` in `SubjectCardView`, `ActionCardView`
/// and `TargetCardView`. If the trigger is ever narrowed — Mode changes only, the
/// step down ADR 0003 keeps in reserve — this file changes and `BorderBeam` does
/// not.
///
/// Exactly one Card holds the keyboard at a time and focus moves on every Tab,
/// Shift+Tab, Enter and Escape, so a false→true edge on one Card's own
/// `isFocused` is the whole trigger: no Card has to know what the others are
/// doing, and nothing can fire twice for one Phase move.
///
/// `onAppear` covers the one Card that never sees that edge — the one already
/// holding the keyboard when the row is built. **A Card focused across a whole
/// dismiss-and-resummon still will not sweep on the second summon**, because the
/// view is not rebuilt and `isFocused` never went false; every Tab and Shift+Tab
/// does. That gap is known and left.
private struct CardBeam: ViewModifier {
    let focused: Bool

    @State private var trigger = 0

    func body(content: Content) -> some View {
        content
            .borderBeam(trigger: trigger)
            .onChange(of: focused) { _, nowFocused in
                guard nowFocused else { return }
                sweep()
            }
            .onAppear {
                guard focused else { return }
                sweep()
            }
    }

    private func sweep() {
        withAnimation(Motion.beamSweep) { trigger += 1 }
    }
}

// MARK: - The API views use

extension View {

    /// Sweeps the Border Beam once each time `trigger` increases. Drive it by
    /// incrementing `trigger` inside `withAnimation(Motion.beamSweep)`.
    ///
    /// The primitive. `cardBeam(focused:)` is the policy the Cards use; this is
    /// what it draws with.
    func borderBeam(trigger: Int) -> some View {
        modifier(
            BorderBeam(
                progress: Double(trigger),
                target: Double(trigger),
                reduced: Motion.isReduced
            )
        )
    }

    /// Sweeps the Border Beam around this Card whenever it takes the keyboard.
    ///
    /// Goes on *after* `cardSurface(focused:)` — the beam runs along the rim the
    /// surface drew — and *before* `.padding(Style.cardInset)`, which sits
    /// outside the surface and would otherwise put the beam on the wrong bounds.
    func cardBeam(focused: Bool) -> some View {
        modifier(CardBeam(focused: focused))
    }
}
