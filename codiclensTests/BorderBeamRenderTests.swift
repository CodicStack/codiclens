import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import codiclens

/// Does the Border Beam actually put light on the rim, and only outside it?
///
/// `BorderBeamTests` pins the *geometry* — where the lit segment is at a given
/// phase — and it passed happily while the beam was invisible on screen. The
/// trim range was correct the whole time; the tail's opacity ramp was deleting
/// it. `BeamSlice` faded twenty slices linearly (1/20, 2/20, …) on top of
/// colours that already carried alpha, so the trailing slices landed near 0.05
/// effective alpha and all that survived was the leading slice — a fortieth of
/// the rim, about 40pt of an intended 336pt.
///
/// Nothing but a render could catch that, so this rasterises the modifier and
/// counts lit pixels. It is the only test in the suite that looks at pixels, and
/// it exists because "the maths is right" and "you can see it" turned out to be
/// very different claims.
///
/// **Every test in here was added after a version shipped and was rejected on
/// sight, and each one is the measurement the pass before it had not taken.** That
/// is the pattern worth knowing about this file, because it has now happened four
/// times.
///
/// `theTailSurvivesItsOwnFalloff` and `theRimAloneIsWhatBothEndsOfTheSweepLookLike`
/// came from the deleted `Style.beamFalloff`: a linear opacity ramp over colours
/// already carrying alpha left 40pt of an intended 336pt on screen while every
/// geometry test passed.
///
/// `nothingIsLitInsideTheRim` is the rule taste cannot catch — a blur spreads
/// inward as much as outward, and the mask that keeps the halo off the Card's icon
/// and name is one modifier away from being silently absent.
///
/// `theHeadHasAHaloAndACrispCore` came from the one-layer comet, whose blur ramped
/// from exactly 0 at the head: the brightest part of the whole effect was a bare
/// 1pt line with literally zero light more than one point outside the rim, and the
/// answer was "there is not enough spread at all and it should be more clear that
/// there even is a glow". Every other test in this file passed.
///
/// `theGlowPeaksAtTheHeadAndDiesAtTheTail` and
/// `neitherEndOfTheLitSegmentIsAHardEdge` came from the two-layer comet, whose glow
/// ran at *constant opacity* down the whole lit segment and so read as a glowing
/// tube with a visible flat end. Every other test in this file passed, again.
///
/// `theCoreIsANearWhiteHighlight` came from the three-part comet, whose core was a
/// **saturated** blue line where the reference material's is a desaturated
/// near-white one — the reference's blue is in its Card's *fill*, and two passes
/// read it as belonging to the light. It is the only test here about a colour, and
/// it is a bound rather than a target, because "it went saturated blue again" is
/// now a repeat failure mode rather than a hypothetical one.
///
/// The through-line: a render can prove light is on screen and cannot say whether
/// it reads as the thing it is for. What a render *can* be made to catch is a
/// measurable absence, or a shape claim stated as an inequality — which is what
/// these two are. And when the complaint is about how something looks, the
/// closing check is still a picture: the core's flat cap and the per-slice banding
/// in its blur ramp were both found by writing composited PNGs out of this same
/// harness and looking at them at 3×, and neither appears in any number above.
@MainActor
struct BorderBeamRenderTests {

    /// A Card's glass surface, which is what the beam runs on: the Card row's
    /// cell less the inset the `.padding(Style.cardInset)` puts *outside* the
    /// surface. Every Card is this size, which is why `Style.beamSeamOffset` can
    /// be exact.
    private let size = CGSize(
        width: PanelLayout.cardWidth - Style.cardInset * 2,
        height: PanelLayout.cardHeight - Style.cardInset * 2
    )

    /// How much bare space is rasterised around the Card.
    ///
    /// `ImageRenderer` renders a view at its own size, and the beam lives
    /// entirely *outside* the Card's bounds — so this is not decoration, it is
    /// the difference between measuring the effect and measuring a crop of it.
    /// One `cardInset` is the gutter the glow was given; `beamGlowTailBlur`
    /// beyond that clears the reach, which is measured at 34pt and gone by 40.
    /// The extra area is transparent, so it contributes no lit pixels and the
    /// baseline does not move with it.
    ///
    /// It is deliberately *less* than `Style.beamMaskOutset`, and less than the
    /// head bloom's own radius: `beamBloomDiameter / 2` is 48 against this 46, so
    /// the outermost two points of the disc are cropped. Those two points carry the
    /// gradient's last stop, which is `.clear`, so nothing measurable is lost. What
    /// has to be cleared is the *measured* reach, not the widest geometry.
    private var pad: CGFloat { Style.cardInset + Style.beamGlowTailBlur }

    /// Pixels brighter than the unlit Card, at 2x.
    private func litPixels(progress: Double) -> Int {
        guard let bitmap = rasterise(progress: progress) else { return -1 }
        var lit = 0
        for i in stride(from: 0, to: bitmap.pixels.count, by: 4) {
            if Int(bitmap.pixels[i]) + Int(bitmap.pixels[i + 1]) + Int(bitmap.pixels[i + 2]) > 130 {
                lit += 1
            }
        }
        return lit
    }

    private struct Bitmap {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        func alpha(x: Int, y: Int) -> Int { Int(pixels[(y * width + x) * 4 + 3]) }

        /// The stored, **premultiplied** channels. Saturation — `(max - min) / max`
        /// — is invariant under premultiplication by a scalar, so this is the
        /// beam's own colour's saturation without having to un-premultiply it and
        /// without a ground to composite over.
        func rgb(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * width + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }

        func saturation(x: Int, y: Int) -> Double {
            let c = rgb(x: x, y: y)
            let mx = Double(max(c.r, max(c.g, c.b)))
            let mn = Double(min(c.r, min(c.g, c.b)))
            return mx == 0 ? 0 : (mx - mn) / mx
        }
    }

    private func rasterise(progress: Double) -> Bitmap? {
        let renderer = ImageRenderer(content: card(progress: progress))
        renderer.scale = Self.scale
        guard let cg = renderer.cgImage else { return nil }

        var buf = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        guard let ctx = CGContext(
            data: &buf, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return Bitmap(width: cg.width, height: cg.height, pixels: buf)
    }

    private static let scale: CGFloat = 2

    /// A stand-in for a focused Card: the dark ground it sits over, its own rim,
    /// and the beam over the top.
    ///
    /// The rim's colour is spelled out rather than read from `Style`, because
    /// `Palette` is private to `Style.swift` — this is dark appearance's
    /// `cardRim`. It only has to be a plausible floor for "brighter than the
    /// rim"; the beam is what is under test.
    ///
    /// **The padding is load-bearing.** The beam is masked to the region
    /// *outside* `Style.cardShape`, which is to say entirely outside the Card's
    /// own bounds. `ImageRenderer` renders a view at its own size, so without the
    /// padding the whole effect falls outside the bitmap and is cropped away: back
    /// when the halo reached 11.5pt the same render measured 1,039 lit pixels
    /// padded and 327 unpadded, and the 327 were only the mask edge's own
    /// antialiasing bleeding onto the boundary row. An unpadded render here would
    /// have failed for a reason that has nothing to do with the beam. See `pad`
    /// for why it is more than one `cardInset` now.
    private func card(progress: Double) -> some View {
        ZStack {
            Color(white: 0.12)
            Style.cardShape.strokeBorder(.white.opacity(0.12), lineWidth: Style.hairline)
        }
        .frame(width: size.width, height: size.height)
        .modifier(BorderBeam(progress: progress, target: 1, reduced: false))
        .padding(pad)
    }

    /// The rim on its own, with no beam lit. Both ends of the sweep must come
    /// back to exactly this, or the beam is parked on the rim instead of gone.
    private var baseline: Int { litPixels(progress: 0) }

    @Test func theRimAloneIsWhatBothEndsOfTheSweepLookLike() {
        #expect(baseline > 0, "the Card's own rim did not render, so nothing here means anything")
        #expect(litPixels(progress: 1) == baseline)
    }

    /// The regression this file exists for. The linear opacity ramp scored 156
    /// pixels over a 280 × 200 Slab's baseline and was invisible; the eased one
    /// scored over 1,500 there, and 1,447 over a Card.
    ///
    /// **The threshold has been re-measured three times and scaled none of
    /// them.** The one-layer comet measured 1,039 over a baseline of 3,468 at
    /// mid-sweep. Adding the glow layer took the same render to 8,115, because a
    /// 10pt band blurred by 10–20 puts real alpha across the whole gutter instead
    /// of a hairline against the rim. That version was rejected on screen for
    /// being *too* dense, and the fix — an opacity ramp on the glow, a bloom at
    /// the head, quieter colours — brought it to **5,197**, deliberately. It was
    /// rejected again for the same reason, and the fourth pass — a steeper glow
    /// ramp, a much fainter glow tail, a dimmer bloom — brings it to **3,782**. A
    /// beam reduced to its head slice alone, which is the failure mode this test is
    /// for, would still be about 60 pixels. So 3,000 is under a working comet and
    /// fifty times a deleted one.
    ///
    /// **Three of those four numbers went *down* on purpose, so this floor cannot
    /// be read as "more is better", and it is now the tightest it has been** — 782
    /// pixels of margin rather than 2,197. It stays at 3,000 rather than following
    /// the measurement down, because it is a floor on the beam *existing* and the
    /// deleted-beam failure it guards is two orders of magnitude below. If a fifth
    /// pass takes the mist down again, re-measure this before assuming there is
    /// room.
    @Test func theTailSurvivesItsOwnFalloff() {
        let lit = litPixels(progress: 0.5) - baseline

        #expect(
            lit > 3_000,
            """
            only \(lit) pixels of rim are lit at mid-sweep. The comet is being \
            deleted by its own falloff — check Style.beamGlowWidth and \
            beamGlowBlur(at:), which are the whole of the halo, \
            Style.beamGlowRamp, which is the only computed opacity ramp in the \
            beam and the one thing here that could delete it again, and \
            Style.beamWidth/beamStrokeWidth, which is what survives the \
            outward mask.
            """
        )
    }

    /// **The head is a bright core inside a soft halo, not a bare line.**
    ///
    /// This is the regression that shipped, and it shipped past every other test
    /// in this file. The beam was a single sliced stroke whose blur ramped from
    /// exactly 0 at the head — a deliberate decision, on the grounds that a crisp
    /// leading edge against a dissolving tail was the contrast the comet lived on
    /// — and the consequence is the row of zeroes below: measured on the real
    /// modifier, that version put alpha 247 one pixel outside the rim and **0**
    /// everywhere beyond, at every distance, in both appearances. A slice has one
    /// blur radius, so one layer could not be crisp and bloomed at once. The glow
    /// is a second layer for that reason and its blur is never 0.
    ///
    /// Measured outward from the right edge's vertical midpoint, at the phase that
    /// puts the head slice there. The two-layer version read alpha 247 at the rim,
    /// then 96, 92, 78, 60, 22 at 1, 4, 8, 12 and 20 points out, reaching zero by
    /// 34. The third pass — a glow that ramps, a bloom at the head, and a core
    /// whose head blur is no longer 0 — read **202, 192, 155, 137, 110, 62**. The
    /// fourth, which turned the halo down to mist and the core into a near-white
    /// highlight, reads **178, 163, 112, 97, 77, 41**, still nothing by 40.
    ///
    /// The rim floor has come down twice, 220 → 170 → **155**, and both times it
    /// was **re-measured rather than scaled**. 178 is what a 1pt core at full
    /// opacity, blurred by `Style.beamCoreHeadBlur`, puts on the rim once the glow
    /// underneath it is only half as dense; the floor sits about 13% under that,
    /// which is the margin 170 had under 202 and 220 had under 247. Note the rim
    /// alpha *fell* while the core's own opacity went 0.95 → 1.00 — what it lost is
    /// the glow that used to be stacked beneath it, and that loss is the point: the
    /// rim's alpha against the alpha 4pt out went 1.30 → **1.59**, which is the
    /// core becoming visible *as a line* rather than as the middle of a bloom.
    @Test func theHeadHasAHaloAndACrispCore() {
        guard let bitmap = beamAlone(progress: Self.headOnTheRightEdge) else {
            Issue.record("the beam layer did not rasterise")
            return
        }

        let y = Int(((pad + size.height / 2) * Self.scale).rounded(.down))
        func alpha(_ outward: CGFloat) -> Int {
            let x = Int(((pad + size.width + outward + 0.25) * Self.scale).rounded(.down))
            return bitmap.alpha(x: x, y: y)
        }

        #expect(
            alpha(0) > 155,
            "the core is not crisp at the rim: alpha \(alpha(0)). Style.beamWidth is what survives the mask."
        )
        #expect(
            alpha(1) > 60 && alpha(4) > 60 && alpha(8) > 40 && alpha(16) > 20,
            """
            the head has no halo: alpha \(alpha(1)) / \(alpha(4)) / \(alpha(8)) / \
            \(alpha(16)) at 1, 4, 8 and 16 points out. Style.beamGlowHeadBlur must \
            never be 0 and the glow layer must be drawn under the head, not only \
            behind it — a head with no bloom is a line, which is what this test is for.
            """
        )
        #expect(
            alpha(1) > alpha(12) && alpha(12) > alpha(28),
            "the halo does not fall off outward: \(alpha(1)) / \(alpha(12)) / \(alpha(28))"
        )
    }

    /// **The core is a desaturated near-white highlight, not a blue line.**
    ///
    /// The one claim in this file about a *colour*, and it is here because "it went
    /// saturated blue again" is a repeat failure. The reference material — Tuna for
    /// Mac — has a pale, crisp, near-white rim highlight over a Card whose **fill**
    /// is blue, and two separate passes read that blue as belonging to the *light*
    /// and pushed the core to a saturated mid-luminance blue. Both were rejected on
    /// screen, and the second one was rejected with the words "the line should be
    /// highlighted exactly like … the tunaformac".
    ///
    /// Measured at the head's rim pixel, on the beam's own colour: the saturated
    /// version read **0.738** in light appearance and **0.158** in dark. It now
    /// reads **0.477** and **0.056**. The bound below is loose on purpose — it is a
    /// guard against a *return* to a saturated core, not a target — and it is set
    /// under the rejected value rather than just over the shipping one, so a pass
    /// that legitimately trades a little saturation back for contrast on a light
    /// ground does not have to argue with a test.
    ///
    /// **Saturation rather than a Δ against a ground**, because the two appearances
    /// and the three grounds disagree about contrast and agree about this. It is
    /// read off the premultiplied channels directly: `(max - min) / max` is
    /// invariant under multiplication by alpha.
    @Test func theCoreIsANearWhiteHighlight() {
        let y = Int(((pad + size.height / 2) * Self.scale).rounded(.down))
        let x = Int(((pad + size.width + 0.25) * Self.scale).rounded(.down))

        for dark in [false, true] {
            guard let bitmap = beamAlone(progress: Self.headOnTheRightEdge, dark: dark) else {
                Issue.record("the beam layer did not rasterise")
                return
            }
            let saturation = bitmap.saturation(x: x, y: y)
            #expect(
                saturation < 0.60,
                """
                the core has gone saturated again in \(dark ? "dark" : "light") \
                appearance: saturation \(saturation) at the head's rim, against \
                0.477 shipping in light and 0.056 in dark. The reference's rim \
                light is white and its blue is in the Card's *fill* — see \
                Palette.beamHead. On a light ground the answer to a beam that does \
                not read is not more blue.
                """
            )
        }
    }

    /// The sweep phase that puts the head slice on the right edge's vertical
    /// midpoint, where "outward" is +x and a profile can be read along one row of
    /// pixels. Derived from the seam and the over-travel rather than guessed:
    /// `Style.beamSeamOffset` puts trim fraction 0 at the top-left corner, so the
    /// right edge's midpoint is `1 - beamSeamOffset` along the beam's own
    /// parameter, and the phase that lands the *middle* of the head slice there
    /// backs off half a slice.
    private static let headOnTheRightEdge: Double = {
        let midpoint = 1 - Double(Style.beamSeamOffset)
        let halfSlice = Double(Style.beamTailFraction) / Double(Style.beamSegments) / 2
        return (midpoint + halfSlice) / (1 + Double(Style.beamTailFraction))
    }()

    /// **The glow peaks at the head and dies before the tail's own end: a coma,
    /// not a tube.**
    ///
    /// This is the third regression to ship past every other test in this file,
    /// and the measurement that catches it is the one nobody had taken. The first
    /// pass profiled the falloff *along* the beam and never across it, and shipped
    /// a beam with no halo. The second profiled it across and never along, and
    /// shipped a halo of constant opacity down the whole 303pt lit segment — which
    /// is a glowing hose. Rasterised, 4pt outside the rim, that version read
    /// **92 at the head, 100 sixty points behind it, 91 at 180 and 62 at 280**: it
    /// rose behind the head and then went flat, so nothing peaked anywhere and
    /// there was no point for the light to be coming from. The answer on screen
    /// was "it should be more like a single area/point that a radial blue kinda
    /// goes out from".
    ///
    /// It read **155 / 75 / 43 / 21** at the same four places with
    /// `Style.beamGlowRamp` at 1.4, and reads **112 / 48 / 24 / 13** at 2.4 — the
    /// fourth pass's answer to "the opacity of the start should be less so that it
    /// just looks more misty". Head-to-far went 7.4× → **8.6×** while every
    /// absolute number came down, and those two have to be read together: a fainter
    /// tail is a *steeper* comet, not a weaker one. The floors below are a monotone
    /// requirement plus a 4× head-to-far ratio, which the tube fails on both counts
    /// (its ratio was 1.5 and its first step went the wrong way).
    ///
    /// The four points are addressed off straight edges rather than by walking the
    /// path, so no arc-length machinery is needed here: at
    /// `headOnTheRightEdge` the head sits on the right edge's vertical midpoint
    /// and the lit segment runs *up* that edge, round the top-right corner and
    /// leftward along the top. Two of the samples are on the right edge and two on
    /// the top, and their order along the beam is unambiguous even though their
    /// exact arc distances are not.
    @Test func theGlowPeaksAtTheHeadAndDiesAtTheTail() {
        guard let bitmap = beamAlone(progress: Self.headOnTheRightEdge) else {
            Issue.record("the beam layer did not rasterise")
            return
        }

        let outward: CGFloat = 4
        func alpha(x: CGFloat, y: CGFloat) -> Int {
            bitmap.alpha(
                x: Int(((x + 0.25) * Self.scale).rounded(.down)),
                y: Int(((y + 0.25) * Self.scale).rounded(.down))
            )
        }

        let right = pad + size.width
        let midY = pad + size.height / 2
        let head = alpha(x: right + outward, y: midY)
        let behind = alpha(x: right + outward, y: midY - 60)
        let far = alpha(x: right - Style.cardRadius - 60, y: pad - outward)
        let furthest = alpha(x: right - Style.cardRadius - 160, y: pad - outward)

        #expect(
            head > behind && behind > far && far > furthest,
            """
            the glow does not fall off along the beam: \(head) / \(behind) / \
            \(far) / \(furthest) at the head and three points behind it. \
            Style.beamGlowRamp is what makes this a coma rather than a tube, and \
            a flat glow reads as a hose whatever its blur does.
            """
        )
        #expect(
            head > furthest * 4,
            """
            the glow's falloff is too shallow to read as a comet: \(head) at the \
            head against \(furthest) 280pt behind it. The version this test was \
            written for measured 92 against 62; the shipping one measures 112 \
            against 13.
            """
        )
    }

    /// **Neither end of the lit segment is a hard edge, and the drain-out does not
    /// park a bright head at the seam.**
    ///
    /// The user-visible complaint was "the end where the beam thing stops looks
    /// bad because you can see where the border thing ends", and there were two
    /// separate causes with very different sizes.
    ///
    /// The travelling head's own terminus was the *core*'s `.butt` cap at
    /// `beamCoreHeadBlur` = 0: a 1pt square of alpha 250 with nothing beyond it.
    /// Measured as the largest alpha step between vertically adjacent pixels half
    /// a point outside the rim, scanned ±24pt around the head, it read **170**
    /// against a mid-segment control of 7. It read **6** against 3 once
    /// `beamCoreHeadBlur` went to 1.5, and reads **9** against 2 now that the glow
    /// under the head is half as dense — a brighter line inside a fainter halo has
    /// a slightly steeper edge by construction, and 9 against a threshold of 40 is
    /// still a fifth of the way to a visible terminus. `Style.beamGlowHeadBlur` is
    /// what would put it back up: raising it 12 → 15 was tried in the same pass and
    /// read 10 here while costing the halo everywhere else.
    ///
    /// The worse one was structural and had nothing to do with caps.
    /// `BorderBeam.trimRange` pins the lit segment's leading end at 1 from phase
    /// 0.741 onward while the trailing end keeps advancing, and `slices` used to
    /// take each slice's `position` from its *index in the current span* — so the
    /// leading slice was always position 1, at full brightness and zero blur. For
    /// the last quarter of every lap the beam therefore had a crisp, stationary,
    /// full-brightness terminus sitting at the top-left corner for 0.14s. Peak
    /// alpha across the whole render at phases 0.74, 0.80, 0.86, 0.92 and 0.97
    /// read **249, 249, 248, 249, 248** — a parked head. Measuring `position`
    /// against the unclamped travel instead read **218, 174, 126, 79, 46**, and
    /// with the fourth pass's quieter mist it reads **190, 132, 87, 51, 31**.
    ///
    /// **The ratio is in the assertion and the monotonicity alone is not enough**,
    /// which was checked rather than assumed: with the travel-based `position`
    /// reverted but this pass's blur and ramp left in, the same five phases read
    /// 218, 203, 186, 166, **149** — still monotone, because the slices get
    /// shorter as the span shrinks and a 1.75pt slice blurred by
    /// `beamCoreHeadBlur` loses peak alpha on its own. Monotone-only would have
    /// passed a terminus three times too bright at the end of the lap. A still
    /// frame cannot tell a draining comet from a parked one; these numbers can.
    @Test func neitherEndOfTheLitSegmentIsAHardEdge() {
        let right = pad + size.width
        let midY = pad + size.height / 2

        /// The largest step between vertically adjacent pixels — which is the
        /// step *along* the beam where it runs down the right edge — at a fixed
        /// distance outside the rim, over 48pt centred on `y`.
        func tangentialStep(_ bitmap: Bitmap, around y: CGFloat, outward: CGFloat) -> Int {
            let x = Int(((right + outward + 0.25) * Self.scale).rounded(.down))
            let first = Int(((y - 24) * Self.scale).rounded(.down))
            let last = Int(((y + 24) * Self.scale).rounded(.down))
            var worst = 0
            for row in first..<last {
                worst = max(worst, abs(bitmap.alpha(x: x, y: row) - bitmap.alpha(x: x, y: row + 1)))
            }
            return worst
        }

        guard let atHead = beamAlone(progress: Self.headOnTheRightEdge),
              let atTail = beamAlone(progress: Self.tailOnTheRightEdge) else {
            Issue.record("the beam layer did not rasterise")
            return
        }

        for outward in [CGFloat(0.5), 1, 2] {
            let head = tangentialStep(atHead, around: midY, outward: outward)
            let control = tangentialStep(atHead, around: midY - 70, outward: outward)
            let tail = tangentialStep(atTail, around: midY, outward: outward)

            #expect(
                head < 40,
                """
                the head terminates in a hard edge \(outward)pt out: a step of \
                \(head), against \(control) along the beam's middle. \
                Style.beamCoreHeadBlur must not be 0 — a `.butt` cap on an \
                unblurred 1pt core is a visible flat end.
                """
            )
            #expect(
                tail < 40,
                "the tail terminates in a hard edge \(outward)pt out: a step of \(tail)."
            )
        }

        var previous = Int.max
        var first = 0
        var last = 0
        for phase in [0.74, 0.80, 0.86, 0.92, 0.97] {
            guard let bitmap = beamAlone(progress: phase) else {
                Issue.record("the beam layer did not rasterise at phase \(phase)")
                return
            }
            var peak = 0
            for i in stride(from: 3, to: bitmap.pixels.count, by: 4) {
                peak = max(peak, Int(bitmap.pixels[i]))
            }
            #expect(
                peak < previous,
                """
                the drain-out is not draining: peak alpha \(peak) at phase \
                \(phase), against \(previous) at the phase before it. The head \
                is parked at the seam at full brightness — BorderBeam.slices must \
                take `position` from the unclamped travel, not from the slice's \
                index in the clipped span.
                """
            )
            if first == 0 { first = peak }
            last = peak
            previous = peak
        }

        #expect(
            last * 3 < first,
            """
            the drain-out only dims: peak alpha \(first) at phase 0.74 against \
            \(last) at 0.97. The lit segment's leading end is pinned at the seam \
            for the last quarter of the lap, so what is left there has to fade to \
            nothing rather than merely thin out — see BorderBeam.slices.
            """
        )
    }

    /// The phase that puts the *trailing* end of the lit segment on the right
    /// edge's vertical midpoint, so the step at that terminus can be read down one
    /// column of pixels. The mirror of `headOnTheRightEdge`: the trailing end is a
    /// whole `beamTailFraction` behind the head, and the phase backs off half a
    /// slice the other way so the cap rather than the slice's middle lands there.
    private static let tailOnTheRightEdge: Double = {
        let midpoint = 1 - Double(Style.beamSeamOffset)
        let halfSlice = Double(Style.beamTailFraction) / Double(Style.beamSegments) / 2
        return (midpoint - halfSlice + Double(Style.beamTailFraction))
            / (1 + Double(Style.beamTailFraction))
    }()

    /// The lit length grows in through the seam and drains back out through it,
    /// so the middle of the sweep is the brightest moment and neither end is.
    @Test func theSweepGrowsInAndDrainsOut() {
        let early = litPixels(progress: 0.15) - baseline
        let middle = litPixels(progress: 0.5) - baseline
        let late = litPixels(progress: 0.85) - baseline

        #expect(early > 0)
        #expect(late > 0)
        #expect(middle > early)
        #expect(middle > late)
    }

    /// **Nothing the beam draws lands inside the rim.**
    ///
    /// This is the one rule taste cannot catch: a blur spreads inward as much as
    /// outward, so an unmasked beam would wash across the Card's icon, name and
    /// chips — faintly, at the far end, over a glass surface, which is exactly the
    /// kind of wrong that survives a look. It matters more since the glow layer
    /// arrived: the thing being masked is a 20pt stroke blurred by up to 20, not a
    /// 2pt one blurred by 8. `BorderBeam.outward` is the mask that stops it and it
    /// is one modifier; delete it and every geometry test in `BorderBeamTests`
    /// still passes.
    ///
    /// The region tested is the Card's own shape shrunk by a point, which is
    /// enough to clear the mask edge's own antialiasing and no more — the beam is
    /// drawn on a transparent ground, so a mask that leaked would show up as
    /// alpha and there is nothing else here that could put any there. Probed at
    /// 0.5, 1, 2 and 4 points of inset and at five phases: zero every time.
    @Test func nothingIsLitInsideTheRim() {
        let inset: CGFloat = 1
        let inner = RoundedRectangle(cornerRadius: Style.cardRadius - inset, style: .continuous)
            .path(in: CGRect(
                x: pad + inset, y: pad + inset,
                width: size.width - inset * 2, height: size.height - inset * 2
            ))
            .cgPath

        for phase in [0.15, 0.3, 0.5, 0.7, 0.85] {
            guard let bitmap = beamAlone(progress: phase) else {
                Issue.record("the beam layer did not rasterise at phase \(phase)")
                return
            }

            var worst = 0
            for y in 0..<bitmap.height {
                for x in 0..<bitmap.width {
                    let point = CGPoint(
                        x: (CGFloat(x) + 0.5) / Self.scale,
                        y: (CGFloat(y) + 0.5) / Self.scale
                    )
                    guard inner.contains(point) else { continue }
                    worst = max(worst, bitmap.alpha(x: x, y: y))
                }
            }

            #expect(
                worst == 0,
                """
                the beam put alpha \(worst) inside the rim at phase \(phase). \
                BorderBeam's outward mask is gone or wrong, and the comet's \
                blurred tail is washing over the Card's content.
                """
            )
        }
    }

    /// The beam with no Card under it, so any alpha inside the rim is the beam's.
    ///
    /// `dark` exists for `theCoreIsANearWhiteHighlight`, which is the one claim in
    /// this file that is about a *colour* and therefore the one that has to be made
    /// twice. Everything else here measures alpha, which the palette's two halves
    /// agree on to within a point.
    private func beamAlone(progress: Double, dark: Bool = false) -> Bitmap? {
        let view = Color.clear
            .frame(width: size.width, height: size.height)
            .modifier(BorderBeam(progress: progress, target: 1, reduced: false))
            .padding(pad)
            .environment(\.colorScheme, dark ? .dark : .light)

        let renderer = ImageRenderer(content: view)
        renderer.scale = Self.scale
        guard let cg = renderer.cgImage else { return nil }

        var buf = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        guard let ctx = CGContext(
            data: &buf, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return Bitmap(width: cg.width, height: cg.height, pixels: buf)
    }
}
