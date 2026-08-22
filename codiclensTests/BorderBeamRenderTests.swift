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
/// bare rim. One rule is new and belongs to the comet: **nothing lands inside
/// the rim.** A blur spreads both ways, and the mask that keeps the halo out of
/// the Card's content is one modifier away from being silently absent.
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
    /// **The `.padding(Style.cardInset)` is load-bearing and was added with the
    /// comet.** The beam is now masked to the region *outside* `Style.cardShape`,
    /// which is to say entirely outside the Card's own bounds, and its blurred
    /// halo reaches about 11.5pt past the rim into the gutter. `ImageRenderer`
    /// renders a view at its own size, so without the padding the whole effect
    /// falls outside the bitmap and is cropped away: the same render measured
    /// 1,039 lit pixels padded and 327 unpadded, and the 327 were only the
    /// mask edge's own antialiasing bleeding onto the boundary row. An unpadded
    /// render here would have failed for a reason that has nothing to do with the
    /// beam.
    private func card(progress: Double) -> some View {
        ZStack {
            Color(white: 0.12)
            Style.cardShape.strokeBorder(.white.opacity(0.12), lineWidth: Style.hairline)
        }
        .frame(width: size.width, height: size.height)
        .modifier(BorderBeam(progress: progress, target: 1, reduced: false))
        .padding(Style.cardInset)
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
    /// **The threshold came down with the comet, and it was re-measured rather
    /// than scaled.** The head is 1pt of visible rim where the old bar was 3.5pt,
    /// so less light reaches the screen by construction; the blurred tail spreads
    /// what is left over more pixels at lower alpha, and some of those pixels
    /// fall under the 130 floor. The comet measures **1,039** over a baseline of
    /// 3,468 at mid-sweep. A beam reduced to its head slice alone — the failure
    /// mode this test is for — would be about 60 pixels, since the head is one
    /// twentieth of a 303pt comet at 1pt wide. So 500 is half of a working comet
    /// and eight times a deleted one, which is the same shape of margin the old
    /// 600 had.
    @Test func theTailSurvivesItsOwnFalloff() {
        let lit = litPixels(progress: 0.5) - baseline

        #expect(
            lit > 500,
            """
            only \(lit) pixels of rim are lit at mid-sweep. The comet's tail is \
            being deleted by its own falloff — check Style.beamTailBlur, which \
            dims by spreading alpha and must not be stacked on an opacity ramp, \
            and Style.beamWidth/beamStrokeWidth, which is what survives the \
            outward mask.
            """
        )
    }

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
    /// This is the comet's one new rule and the only one taste cannot catch: a
    /// blur spreads inward as much as outward, so an unmasked tail would wash
    /// across the Card's icon, name and chips — faintly, at the far end, over a
    /// glass surface, which is exactly the kind of wrong that survives a look.
    /// `BorderBeam.outward` is the mask that stops it and it is one modifier;
    /// delete it and every geometry test in `BorderBeamTests` still passes.
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
                x: Style.cardInset + inset, y: Style.cardInset + inset,
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
            .padding(Style.cardInset)

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
