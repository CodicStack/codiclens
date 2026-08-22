import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import codiclens

/// Does the Border Beam actually put light on the rim, and only where it is meant
/// to?
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
/// is the pattern worth knowing about this file, because it has now happened five
/// times.
///
/// `theTailSurvivesItsOwnFalloff` and `theRimAloneIsWhatBothEndsOfTheSweepLookLike`
/// came from the deleted `Style.beamFalloff`: a linear opacity ramp over colours
/// already carrying alpha left 40pt of an intended 336pt on screen while every
/// geometry test passed.
///
/// `nothingIsLitDeepInsideTheRim` has been pointed both ways and the history is the
/// interesting part. For four passes it was `nothingIsLitInsideTheRim`, asserting
/// that the beam only ever touched pixels *outside* the Card — which is to say
/// pixels this app does not own, because outside a Card's rim is the gutter, the
/// Panel's transparent margin and then the user's desktop. It was certifying the
/// bug. The fifth pass inverted the mask and the test with it. The sixth put the
/// halo back outside — where the user wants it — and gave the **core** a foot on
/// both sides, so the claim is neither "nothing inside" nor "nothing outside" any
/// more: it is that nothing reaches *deep* inside, which is a bound with a number
/// in it.
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
/// `theBeamReadsAgainstAWhiteDesktop` came from the fourth comet, and it is the
/// only test here that composites the beam over the Card as the app actually draws
/// it — `cardSurface(focused:)`, real `Style` values, real `glassEffect` — rather
/// than over the transparent ground everything else in this file measures. Four
/// passes measured against synthetic swatches, and a Δ19 against a white one sat
/// unread in a results table for a whole iteration while the beam was invisible on
/// the user's screen. A pure-white backdrop is the regression case: white is the
/// ground that contributes *nothing*, so a beam that still reads over it is a beam
/// that is not living off somebody's wallpaper. **It is the most important test in
/// this file and it survived the halo moving back outside**, because the core now
/// straddles the rim: 1pt of the line is always on Liquid Glass.
///
/// `theCoreIsADesaturatedHighlight` came from the three-part comet, whose core was a
/// **saturated** blue line, and it now bounds the core's saturation from **both**
/// sides. Above 0.60 is the saturated primary that was rejected twice as "too
/// dense" and a "blue blob"; below 0.20 is the near-white that was rejected once for
/// being invisible over a bright wallpaper, which is the failure a Δ cannot see and
/// this one can.
///
/// `theBloomIsElongatedAlongTheRim` is the sixth pass's own test. The nucleus was a
/// circle, and a circle centred on a line is a dot on that line: "not just a dot
/// that has a radial glow … but spread it more out". A circle is a shape claim, so
/// it is checkable as one.
///
/// The through-line: a render can prove light is on screen and cannot say whether
/// it reads as the thing it is for. What a render *can* be made to catch is a
/// measurable absence, or a shape claim stated as an inequality — which is what
/// these are. And when the complaint is about how something looks, the closing
/// check is still a picture: the core's flat cap, the per-slice banding in its blur
/// ramp, and the head reading as a dot were all found by writing composited PNGs
/// out of this same harness and looking at them at 3×, and none of them appears in
/// any number above.
///
/// **One thing about the harness, found the sixth time round and worth more than
/// any threshold here: `glassEffect` does not rasterise deterministically under
/// `ImageRenderer` in Debug.** Two renders of the *same* unlit Card differ by up to
/// Δ36 on 60% of their pixels — a dither, and it is enough to swamp any composited
/// measurement taken from a single pair. In Release the same pair is bit-identical.
/// Every composited number quoted in this file is therefore a mean of several
/// renders (`composited(progress:dark:)` takes it), which brings the residual under
/// Δ0.5 at 16 renders and under Δ5 at 8. The older note that the same code measured
/// Δ87 in Debug and Δ68 in Release is the same phenomenon seen once, without the
/// cause; with averaging the two configurations now agree to about Δ5.
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
    /// **It is the room the effect lives in again**, because the halo is masked
    /// *outward* once more. It clears the measured reach with room over, and every
    /// coordinate in this file is expressed relative to it — shrinking it would move
    /// every sample point and re-measure nothing.
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
        // **Dark appearance, explicitly, and it stopped being optional when the
        // beam moved inward.** `litPixels` counts pixels *brighter* than the
        // unlit Card, which was appearance-neutral while the beam drew on a
        // transparent ground outside the rim. It is not any more: the beam draws
        // on the Card's own glass, and light appearance's Card is lighter than
        // any highlight, so light appearance's beam is a *darkening* — see
        // `Palette.beamHead`. Counting bright pixels in light appearance now
        // measures the beam getting weaker as it gets stronger. So this stand-in
        // is the dark Card it has always looked like, and says so.
        .environment(\.colorScheme, .dark)
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
    /// **The threshold has been re-measured four times and scaled none of
    /// them.** The one-layer comet measured 1,039 over a baseline of 3,468 at
    /// mid-sweep. Adding the glow layer took the same render to 8,115, because a
    /// 10pt band blurred by 10–20 puts real alpha across the whole gutter instead
    /// of a hairline against the rim. That version was rejected on screen for
    /// being *too* dense, and the fix — an opacity ramp on the glow, a bloom at
    /// the head, quieter colours — brought it to **5,197**, deliberately. It was
    /// rejected again for the same reason, and the fourth pass — a steeper glow
    /// ramp, a much fainter glow tail, a dimmer bloom — brought it to **3,782**.
    ///
    /// The fifth pass masked the beam inward and read **13,835** — not four times
    /// brighter, a different region of pixels, since inside the rim the Card's own
    /// ground already contributes 93 of the 130. The sixth put the halo back outside
    /// with a bigger, bluer, longer comet and reads **8,591**. None of these numbers
    /// is comparable with the one before it; the counted set keeps moving.
    ///
    /// The floor is **6,000**, about two thirds of the measurement. It is a floor on
    /// the beam *existing*, not a target: several of the numbers above went down on
    /// purpose. Re-measure it rather than scaling it, both ways.
    @Test func theTailSurvivesItsOwnFalloff() {
        let lit = litPixels(progress: 0.5) - baseline

        #expect(
            lit > 6_000,
            """
            only \(lit) pixels of rim are lit at mid-sweep. The comet is being \
            deleted by its own falloff — check Style.beamGlowWidth and \
            beamGlowBlur(at:), which are the whole of the halo, \
            Style.beamGlowRamp, which is the only computed opacity ramp in the \
            beam and the one thing here that could delete it again, and \
            Style.beamWidth, which is the core straddling the rim.
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
    /// **Measured *outward* from the right edge's vertical midpoint, which is where
    /// the halo is again.** It was read inward for one pass, while the whole comet
    /// was masked to the Card's interior. At 0, 1, 4, 8, 12, 16 and 28 points out it
    /// reads **182, 167, 115, 96, 76, 58, 19**, gone by 40 — the same profile in both
    /// appearances now, because the palette no longer differs between them. The
    /// floors below were re-measured against that and left where they were.
    ///
    /// The rim's alpha against the alpha 4pt out is **1.53** (176 / 115), which is
    /// the number that says the line reads as a line rather than as the bright middle
    /// of a cloud. It must stay above about 1.3.
    @Test func theHeadHasAHaloAndACrispCore() {
        guard let bitmap = beamAlone(progress: Self.headOnTheRightEdge) else {
            Issue.record("the beam layer did not rasterise")
            return
        }

        let y = Int(((pad + size.height / 2) * Self.scale).rounded(.down))
        /// Points *outward* from the rim, which is where the halo is.
        func alpha(_ outward: CGFloat) -> Int {
            let x = Int(((pad + size.width + outward + 0.25) * Self.scale).rounded(.down))
            return bitmap.alpha(x: x, y: y)
        }

        #expect(
            alpha(0) > 155,
            "the core is not crisp at the rim: alpha \(alpha(0)). Style.beamWidth is the core's stroked width."
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
    /// reads **0.293** and **0.026**. The bound below is loose on purpose — it is a
    /// guard against a *return* to a saturated core, not a target — and it is set
    /// under the rejected value rather than just over the shipping one.
    ///
    /// **The sixth pass bounds it from below as well, and dropped the polarity
    /// split.** The core is one light blue in both appearances — un-premultiplied
    /// **(128, 171, 255)**, saturation **0.50** — because half of it lands outside
    /// the rim, on the user's desktop. That is the ground a near-white core vanished
    /// against (Δ10/442 over a bright hazy sky), so "desaturated" is no longer the
    /// whole claim: the colour has to be *chromatic enough* to clear a white sky and
    /// *unsaturated enough* not to be the blue blob that was rejected twice. Hence
    /// two bounds rather than one.
    ///
    /// **Saturation rather than a Δ against a ground**, because the two appearances
    /// and the four grounds disagree about contrast and agree about this. It is
    /// read off the premultiplied channels directly: `(max - min) / max` is
    /// invariant under multiplication by alpha. The polarity check has to
    /// un-premultiply, which is why it divides by alpha.
    @Test func theCoreIsADesaturatedHighlight() {
        let y = Int(((pad + size.height / 2) * Self.scale).rounded(.down))
        // Just *inside* the rim: the core lies in `[rim - beamWidth, rim]` now.
        let x = Int(((pad + size.width - 0.25) * Self.scale).rounded(.down))

        for dark in [false, true] {
            guard let bitmap = beamAlone(progress: Self.headOnTheRightEdge, dark: dark) else {
                Issue.record("the beam layer did not rasterise")
                return
            }
            let saturation = bitmap.saturation(x: x, y: y)
            #expect(
                saturation < 0.60 && saturation > 0.20,
                """
                the core's colour is out of bounds in \(dark ? "dark" : "light") \
                appearance: saturation \(saturation) at the head's rim, against 0.50 \
                shipping. Above 0.60 is the saturated primary that was rejected twice \
                as "too dense" and a "blue blob"; below 0.20 is the near-white that \
                measured Δ10/442 over a bright wallpaper, because half of the core \
                composites against the desktop — see Palette.beamHead.
                """
            )

            let colour = bitmap.rgb(x: x, y: y)
            let alpha = max(bitmap.alpha(x: x, y: y), 1)
            let brightest = Double(max(colour.r, max(colour.g, colour.b))) / Double(alpha)
            let dimmest = Double(min(colour.r, min(colour.g, colour.b))) / Double(alpha)
            #expect(
                brightest > 0.85 && dimmest > 0.30,
                """
                the core is not a *light* blue in \(dark ? "dark" : "light") \
                appearance: brightest channel \(brightest), dimmest \(dimmest), \
                against 1.00 and 0.50 shipping. It has to read as light rather than \
                as a colour — the same value in both appearances, because the halo \
                lands on a desktop and not on the Card's tint.
                """
            )
        }
    }

    /// The sweep phase that puts the head slice on the right edge's vertical
    /// midpoint, where "inward" is −x and a profile can be read along one row of
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
    /// `Style.beamGlowRamp` at 1.4, and **112 / 48 / 24 / 13** at 2.4 — the
    /// fourth pass's answer to "the opacity of the start should be less so that it
    /// just looks more misty". Head-to-far went 7.4× → **8.6×** while every
    /// absolute number came down, and those two have to be read together: a fainter
    /// tail is a *steeper* comet, not a weaker one. The floors below are a monotone
    /// requirement plus a 4× head-to-far ratio, which the tube fails on both counts
    /// (its ratio was 1.5 and its first step went the wrong way).
    ///
    /// **They are 4pt outside the rim again**, the mask having spent one pass
    /// inverted. `Style.beamGlowRamp` came down 2.4 → 1.25 for "spread it more out",
    /// which lifts the *body* of the tail without touching either end: the same four
    /// places read 115 / 93 / 22 / 13 at 2.4 and **115 / 96 / 28 / 13** at 1.25, and
    /// 100pt behind the head 15 → 25. The far end does not move at any exponent,
    /// because what is visible there is the core's own trailing colour rather than
    /// the glow. Ratio 8.85×.
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
            written for measured 92 against 62; the shipping one measures 115 \
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
    /// `beamCoreHeadBlur` went to 1.5, and **9** against 2 when the glow under the
    /// head came down to mist. Read half a point *outside* the rim, where the halo
    /// is, it is **9 against a control of 3** in both appearances. All of those are
    /// steps *along* the beam, and 40 is the bound.
    ///
    /// **The radial step across the rim is a different quantity and it is not what
    /// this test bounds.** It was 178 with the halo outside and 194 with it inside,
    /// and it is **70** now, because the core straddles the rim: the mask's cut has
    /// the line drawn over it on both sides rather than abutting it on one. A visible
    /// terminus, which is what "you can see where the border thing ends" was about,
    /// is a step *along* the beam where there is no line for it to be the edge of.
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
    /// against the unclamped travel instead read **218, 174, 126, 79, 46**, and it
    /// reads **190, 137, 94, 57, 34** now — the mask does not touch this, and the
    /// changes are the palette's and the ramp's.
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

    /// **Nothing the beam draws reaches deep into the Card, and this test has been
    /// pointed both ways.**
    ///
    /// For four passes it was `nothingIsLitInsideTheRim`, and it was enforcing a bug:
    /// masking the whole comet *outside* `Style.cardShape` sounded like the obviously
    /// right rule — a blur spreads inward as much as outward, so cut the inward half
    /// and nothing washes over the Card's icon, name and chips — but outside a Card's
    /// rim is `Style.cardInset`'s gutter and then the Panel's own transparent margin,
    /// and the Panel is a borderless non-activating `NSPanel`. Outside the rim is
    /// **the user's desktop**, so the beam never composited against anything this app
    /// draws. Measured on the real composite, a near-white head read **Δ10/442** in
    /// dark appearance over a white desktop against Δ270 over a near-black one: a
    /// factor of twenty-seven decided by somebody's wallpaper. The fifth pass
    /// inverted the mask and this test with it; the sixth put the halo back outside,
    /// where it was asked for, and made the light **blue** — which is the thing that
    /// makes an unknown ground survivable.
    ///
    /// So the claim is neither "nothing inside" nor "nothing outside" any more. The
    /// glow and the bloom are masked outward; the **core** is unmasked and straddles
    /// the rim, so half of `Style.beamWidth` is deliberately inside, blurred by up to
    /// `beamCoreTailBlur`. Measured, any alpha at all stops by **13.3pt** in and
    /// nothing past 10pt in exceeds alpha **4** — the icon, the name and the whole
    /// middle of the Card are untouched. The bound below is that, loosely: it still
    /// fails outright if `BorderBeam.outward` is deleted, which is the one-modifier
    /// mistake worth catching.
    @Test func nothingIsLitDeepInsideTheRim() {
        /// Signed distance from the rim, positive outside: the standard rounded-rect
        /// SDF, exact for an axis-aligned one.
        func distanceFromTheRim(x: Int, y: Int) -> CGFloat {
            let px = (CGFloat(x) + 0.5) / Self.scale - pad
            let py = (CGFloat(y) + 0.5) / Self.scale - pad
            let qx = abs(px - size.width / 2) - size.width / 2 + Style.cardRadius
            let qy = abs(py - size.height / 2) - size.height / 2 + Style.cardRadius
            let mx = max(qx, 0), my = max(qy, 0)
            return (mx * mx + my * my).squareRoot() + min(max(qx, qy), 0) - Style.cardRadius
        }

        for phase in [0.15, 0.3, 0.5, 0.7, 0.85] {
            guard let bitmap = beamAlone(progress: phase) else {
                Issue.record("the beam layer did not rasterise at phase \(phase)")
                return
            }

            var worstPast10 = 0
            var worstPast16 = 0
            for y in 0..<bitmap.height {
                for x in 0..<bitmap.width {
                    let alpha = bitmap.alpha(x: x, y: y)
                    guard alpha > 0 else { continue }
                    let d = distanceFromTheRim(x: x, y: y)
                    if d < -10 { worstPast10 = max(worstPast10, alpha) }
                    if d < -16 { worstPast16 = max(worstPast16, alpha) }
                }
            }

            #expect(
                worstPast10 < 20 && worstPast16 == 0,
                """
                the beam put alpha \(worstPast10) more than 10pt inside the rim and \
                \(worstPast16) more than 16pt in, at phase \(phase). The glow and \
                the bloom must stay under BorderBeam.outward — only the core's own \
                inner half belongs inside the Card, and it dies by 13pt.
                """
            )
        }
    }

    /// **The beam reads on a Card over a pure-white desktop, and this is the test
    /// the whole fifth pass exists for.**
    ///
    /// Every other test in this file measures the beam's own alpha on a transparent
    /// ground, which is the right way to pin a falloff and blind to the only
    /// question that mattered: *what is this light landing on?* For four passes the
    /// answer was "the user's wallpaper", and the number that proved it — a core
    /// measuring Δ19 against a white ground — sat unrecognised in a results table
    /// for a whole iteration, because "dark appearance" was read as implying a dark
    /// ground. It does not. The appearance sets the Card's tint; the desktop the
    /// beam was drawing on has nothing to do with it.
    ///
    /// So this one composites the real thing: `cardSurface(focused: true)` with real
    /// `Style` values and real `glassEffect`, over a **pure white** backdrop, and
    /// asks how far the lit render moves from the unlit one. White is the regression
    /// case rather than an unusual one — it is the ground that contributes nothing,
    /// so whatever is left is the Card doing the work.
    ///
    /// **It survived the halo moving back outside, which is the single most
    /// important fact in this pass**, and it survived it for a reason with a
    /// mechanism: the core is no longer masked to one side, it *straddles* the rim,
    /// so half of the line always lands on Liquid Glass whatever the wallpaper is.
    /// Measured, peak perceptual distance across the rim band: **Δ83 in dark
    /// appearance and Δ86 in light**, against Δ74 and Δ174 with the whole comet
    /// masked inward and Δ17 and Δ89 with the whole comet masked outward and
    /// near-white. The floor is 50, which the near-white outward build fails by a
    /// factor of three. Of those numbers, the ones that cannot be taken away by a
    /// wallpaper are the *inward* halves — Δ46 and Δ49 — because that is the part
    /// drawn on the Card.
    ///
    /// The band is sampled 8pt *outside* the rim to 16pt inside it, because the light
    /// is on both sides now.
    ///
    /// **The renders are averaged, and that is not fussiness.** `glassEffect` does not
    /// rasterise deterministically under `ImageRenderer` in Debug: two renders of the
    /// same unlit Card differ by up to Δ36 on most of their pixels, which is most of
    /// this test's own floor. Six renders bring the residual under Δ5. In Release the
    /// same pair is bit-identical and the measurement lands within Δ5 of the Debug
    /// one.
    @Test func theBeamReadsAgainstAWhiteDesktop() {
        for dark in [false, true] {
            guard let lit = composited(progress: Self.headOnTheRightEdge, dark: dark),
                  let unlit = composited(progress: nil, dark: dark) else {
                Issue.record("the Card did not rasterise")
                return
            }

            let y = Int(((pad + size.height / 2) * Self.scale).rounded(.down))
            var best = 0.0
            for offset in stride(from: CGFloat(-8), through: 16, by: 0.5) {
                let x = Int(((pad + size.width - offset - 0.25) * Self.scale).rounded(.down))
                let a = lit.rgb(x: x, y: y)
                let b = unlit.rgb(x: x, y: y)
                let d = ((a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g)
                    + (a.b - b.b) * (a.b - b.b)).squareRoot()
                best = max(best, d)
            }

            #expect(
                best > 50,
                """
                the beam is invisible on a Card over a white desktop in \
                \(dark ? "dark" : "light") appearance: peak Δ\(Int(best))/442 \
                across the rim band, against 83 and 86 shipping. This is the \
                architectural failure, not a tuning one: with the core masked \
                entirely outward and near-white it collapses to 17, because outside \
                the rim is the user's desktop. See BorderBeam.outward.
                """
            )
        }
    }

    /// The Card as the app draws it, over a pure white desktop, with the beam over
    /// the top — or without it, when `progress` is `nil`, and averaged over
    /// `Self.composites` renders.
    ///
    /// The one place in this file that renders `cardSurface`. Everything else
    /// measures the beam alone, because a falloff is a property of the beam; this
    /// measures the composite, because legibility is a property of the pair.
    ///
    /// **The averaging is load-bearing in Debug.** `glassEffect` under
    /// `ImageRenderer` dithers: two renders of the same unlit Card differ by up to
    /// Δ36 per pixel, which would be most of this test's floor arriving as noise.
    /// Six renders bring the residual under Δ5; sixteen bring it under Δ0.5. Release
    /// is deterministic and needs none of it.
    private func composited(progress: Double?, dark: Bool) -> Field? {
        let card = Color.clear
            .frame(width: size.width, height: size.height)
            .cardSurface(focused: true)
        let view = ZStack {
            Color.white
            Group {
                if let progress {
                    card.modifier(BorderBeam(progress: progress, target: 1, reduced: false))
                } else {
                    card
                }
            }
        }
        .frame(width: size.width + pad * 2, height: size.height + pad * 2)
        .environment(\.colorScheme, dark ? .dark : .light)

        var mean: [Double] = []
        var width = 0, height = 0
        for _ in 0..<Self.composites {
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
            if mean.isEmpty {
                width = cg.width
                height = cg.height
                mean = [Double](repeating: 0, count: width * height * 3)
            }
            for i in 0..<(width * height) {
                mean[i * 3] += Double(buf[i * 4])
                mean[i * 3 + 1] += Double(buf[i * 4 + 1])
                mean[i * 3 + 2] += Double(buf[i * 4 + 2])
            }
        }
        for i in 0..<mean.count { mean[i] /= Double(Self.composites) }
        return Field(width: width, height: height, rgb: mean)
    }

    /// How many renders one composited measurement averages. See `composited`.
    private static let composites = 6

    /// Mean RGB per pixel over several renders, which is what a noisy rasteriser
    /// leaves you able to measure.
    private struct Field {
        let width: Int
        let height: Int
        let rgb: [Double]

        func rgb(x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
            let i = (y * width + x) * 3
            return (rgb[i], rgb[i + 1], rgb[i + 2])
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
