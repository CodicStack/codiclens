import SwiftUI

/// The app's own spinner: a constant-length 270° arc, rotating.
///
/// **Decoration in the strict sense** of `docs/adr/0003-motion-budget.md`, which
/// is what entitles it to exist beside the three transition curves. It carries
/// no information — neither Vision nor `mdfind` reports progress, so there is
/// nothing here for it to be a measure of — and it is emphatically **never a
/// progress claim**. It is a fixed-length arc that turns; never a ring that
/// fills once and then waits, which would be claiming something the app cannot
/// back.
///
/// **It never appears without text beside it.** A bare spinner does not say what
/// is being waited on, so the row's label is the content and the ring is only
/// next to it.
///
/// It replaces the system `ProgressView` in both of the Panel's waiting states.
/// Once the app draws its own loop, a system spinner two cases down the same
/// `if` is the inconsistency rather than this.
///
/// It flashes on a fast image, knowingly: OCR on a small screenshot finishes in
/// well under 200ms. The alternative is a threshold before showing it, which is
/// an `asyncAfter`, which the decoration rules forbid outright.
struct LoadingRing: View {

    /// Flipped once, in `onAppear`, which is what `ringSpin` carries round and
    /// round. There is no clock and no `TimelineView`: one state change and a
    /// repeating curve.
    @State private var spinning = false

    var body: some View {
        // Absent under Reduce Motion, not frozen. A stopped 270° arc reads as a
        // hung widget, and `Motion.collapsed(_:)` cannot help — a cross-fade is
        // meaningless for a loop. The guard lives here rather than at the call
        // sites so that both of them are identical.
        if !Motion.isReduced {
            Circle()
                .trim(from: 0, to: Style.ringArcFraction)
                .stroke(
                    style: StrokeStyle(lineWidth: Style.ringStroke, lineCap: .round)
                )
                // Matched to the 12pt label it sits beside, so the pair reads as
                // one row rather than as a control with a caption.
                .foregroundStyle(.secondary)
                .frame(width: Style.ringDiameter, height: Style.ringDiameter)
                // Positive degrees are clockwise.
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .onAppear {
                    withAnimation(Motion.ringSpin) { spinning = true }
                }
        }
    }
}
