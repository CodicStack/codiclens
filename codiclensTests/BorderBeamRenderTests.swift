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
/// The opacity ramp is gone now — the comet's falloff is a per-slice blur, and
/// `Style.beamFalloff` was deleted rather than retuned, because a blur *and* an
/// opacity ramp is the same double-multiplication that deleted the beam the
/// first time. What the tests below guard is unchanged in kind: that the tail
/// survives whatever the current falloff is, and that both ends of the sweep are
/// bare rim. Two rules are newer. **Nothing lands inside the rim** — a blur
/// spreads both ways, and the mask that keeps the halo out of the Card's content
/// is one modifier away from being silently absent. And **the head has a halo as
/// well as a core**, which is the regression that actually shipped: the beam was
/// one sliced stroke whose blur ramped from exactly 0 at the head, so the
/// brightest, most visible part of the whole effect was a bare 1pt line with
/// literally zero light more than one point outside the rim. Every geometry test
/// passed, this file's tail test passed, and the answer on screen was "there is
/// not enough spread at all and it should be more clear that there even is a
/// glow". A test that would have caught that is worth more than another one
/// pinning what already worked.
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
    /// **The threshold has been re-measured twice and scaled neither time.** The
    /// one-layer comet measured 1,039 over a baseline of 3,468 at mid-sweep — the
    /// head was 1pt of visible rim where the old bar had been 3.5, and the blurred
    /// tail spread what was left over more pixels at lower alpha, with many of
    /// them under the 130 floor. Adding the glow layer takes the same render to
    /// **8,115** over the same baseline, because a 10pt band blurred by 10–20
    /// puts real alpha across the whole gutter instead of a hairline against the
    /// rim. A beam reduced to its head slice alone — the failure mode this test is
    /// for — would still be about 60 pixels. So 4,000 is half of a working comet
    /// and sixty times a deleted one.
    @Test func theTailSurvivesItsOwnFalloff() {
        let lit = litPixels(progress: 0.5) - baseline

        #expect(
            lit > 4_000,
            """
            only \(lit) pixels of rim are lit at mid-sweep. The comet is being \
            deleted by its own falloff — check Style.beamGlowWidth and \
            beamGlowBlur(at:), which are the whole of the halo, and \
            Style.beamWidth/beamStrokeWidth, which is what survives the \
            outward mask. Blur dims by spreading alpha and must not be stacked \
            on an opacity ramp.
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
    /// puts the head slice there: alpha 247 at the rim, then 96, 92, 78, 60, 22
    /// at 1, 4, 8, 12 and 20 points out, reaching zero by 34. The floors below are
    /// well under those and well over nothing.
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
            alpha(0) > 220,
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
    private func beamAlone(progress: Double) -> Bitmap? {
        let view = Color.clear
            .frame(width: size.width, height: size.height)
            .modifier(BorderBeam(progress: progress, target: 1, reduced: false))
            .padding(pad)

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
