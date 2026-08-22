import CoreGraphics
import Testing
@testable import codiclens

/// The Border Beam's over-travel: how the lit segment enters and leaves through
/// the seam.
///
/// The whole point of the arithmetic is that the beam is never on screen
/// fully-formed at either end of the sweep. It travels `1 + tail` so the head
/// crosses the seam first and the tail crosses it last, and `trim`'s clamping is
/// what grows it in and drains it out. Get the range wrong in either direction
/// and the beam pops into being — which is exactly the artefact the over-travel
/// was chosen to avoid, and not something a still frame would show.
struct BorderBeamTests {

    private let tail = Style.beamTailFraction

    // MARK: - The two ends of the sweep

    @Test func nothingIsLitAtTheStartOfTheSweep() {
        let range = BorderBeam.trimRange(phase: 0, tail: tail)

        #expect(range.from == range.to)
        #expect(range.from == 0)
    }

    /// The tail has left through the seam, so the segment is gone rather than
    /// parked at the end of the path.
    @Test func nothingIsLitAtTheEndOfTheSweep() {
        let range = BorderBeam.trimRange(phase: 1, tail: tail)

        #expect(range.from == range.to)
        #expect(range.to == 1)
    }

    /// The one moment the whole segment is lit *and* touching the seam: the head
    /// has just arrived back at it, and the tail is a full `tail` behind.
    @Test func theWholeSegmentIsLitAsTheHeadReachesTheSeam() {
        let phase = 1 / Double(1 + tail)
        let range = BorderBeam.trimRange(phase: phase, tail: tail)

        #expect(abs(range.to - 1) < 0.0001)
        #expect(abs(range.from - (1 - tail)) < 0.0001)
    }

    // MARK: - Invariants across the sweep

    @Test func theLitSegmentNeverOutgrowsItsTailAndNeverLeavesThePath() {
        for step in 0...200 {
            let phase = Double(step) / 200
            let range = BorderBeam.trimRange(phase: phase, tail: tail)

            #expect(range.from >= 0, "phase \(phase) ran off the start of the path")
            #expect(range.to <= 1, "phase \(phase) ran off the end of the path")
            #expect(range.from <= range.to, "phase \(phase) inverted the range")
            #expect(
                range.to - range.from <= tail + 0.0001,
                "phase \(phase) lit \(range.to - range.from) of the rim, more than the tail"
            )
        }
    }

    /// The head only ever moves forwards, and so does the tail. A sweep that
    /// went backwards anywhere would read as a bounce.
    @Test func bothEndsAdvanceMonotonically() {
        var previous = BorderBeam.trimRange(phase: 0, tail: tail)

        for step in 1...200 {
            let range = BorderBeam.trimRange(phase: Double(step) / 200, tail: tail)
            #expect(range.from >= previous.from)
            #expect(range.to >= previous.to)
            previous = range
        }
    }

    /// The fraction is a fraction so that the sweep looks the same on the
    /// shortest Slab and the tallest one — the geometry must not depend on the
    /// tuned value.
    @Test func theArithmeticHoldsForAnyTailLength() {
        for tail in [CGFloat(0.05), 0.35, 0.5, 1.0] {
            #expect(BorderBeam.trimRange(phase: 0, tail: tail).to == 0)
            #expect(BorderBeam.trimRange(phase: 1, tail: tail).from == 1)

            let full = BorderBeam.trimRange(phase: 1 / Double(1 + tail), tail: tail)
            #expect(abs(full.to - 1) < 0.0001)
            #expect(abs(full.from - (1 - tail)) < 0.0001)
        }
    }
}
