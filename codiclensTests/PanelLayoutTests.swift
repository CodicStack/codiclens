import CoreGraphics
import Testing
@testable import codiclens

/// The Panel's fixed geometry, and the rule that decides which clicks count as
/// landing on it.
///
/// This matters more than it looks. The Panel is one window sized to its maximum
/// extent, so most of it is empty space — a margin all the way round and a real
/// gap between the two Slabs. Click-outside-to-dismiss depends on a click in
/// that space being treated as *outside*, and the two coordinate systems
/// involved disagree about which way y goes: AppKit measures a window from its
/// bottom-left, SwiftUI reports frames from the top-left.
struct PanelLayoutTests {

    // MARK: - The margin

    @Test func theMarginLeavesRoomForTheEntranceOvershootAndAShadow() {
        // `PanelEntrance` peaks at 1.04 about the centre, so the widest layout
        // pushes 2% of its width past its own edge on each side.
        let overshoot = PanelLayout.contentWidth * 0.02

        #expect(PanelLayout.margin > overshoot)
        #expect(
            PanelLayout.margin - overshoot >= Style.shadowRadius,
            "whatever is left over has to be enough for the shadow to fall off in"
        )
        #expect(PanelLayout.margin - Style.shadowRadius - Style.shadowY > 0)
    }

    @Test func thePanelIsBiggerThanItsContentOnAllFourSides() {
        #expect(PanelLayout.panelWidth == PanelLayout.contentWidth + PanelLayout.margin * 2)
        #expect(PanelLayout.panelHeight == PanelLayout.contentHeight + PanelLayout.margin * 2)
    }

    @Test func theContentIsTheWidestCardRowAndTheTallestSlabWithAGapBetween() {
        #expect(PanelLayout.contentWidth == PanelLayout.cardRowWidth(PanelLayout.maxCardCount))
        #expect(
            PanelLayout.contentHeight
                == PanelLayout.cardHeight + Style.gap + PanelLayout.maxResultsHeight
        )
    }

    /// Centring puts this line on the screen's vertical midpoint, so it has to
    /// describe the Card row's bottom edge and nothing else.
    @Test func theCardRowSitsUnderTheTopMargin() {
        #expect(
            PanelLayout.cardRowBottomInset
                == Style.gap + PanelLayout.maxResultsHeight + PanelLayout.margin
        )
    }

    // MARK: - Which clicks land on the Panel

    /// The layout as SwiftUI would report it: Cards under the top margin,
    /// Results Slab a gap below them, both horizontally centred.
    private var regions: PanelHitRegions {
        let cardWidth = PanelLayout.cardRowWidth(1)
        let x = (PanelLayout.panelWidth - cardWidth) / 2
        return PanelHitRegions(
            cards: CGRect(
                x: x, y: PanelLayout.margin,
                width: cardWidth, height: PanelLayout.cardHeight
            ),
            results: CGRect(
                x: x, y: PanelLayout.margin + PanelLayout.cardHeight + Style.gap,
                width: cardWidth, height: 120
            )
        )
    }

    /// A point in the SwiftUI space, as AppKit would report the same point.
    private func windowPoint(fromTopLeft point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: PanelLayout.panelHeight - point.y)
    }

    private func accepts(topLeft point: CGPoint, _ regions: PanelHitRegions) -> Bool {
        regions.accepts(
            windowPoint: windowPoint(fromTopLeft: point),
            panelHeight: PanelLayout.panelHeight
        )
    }

    @Test func aClickOnACardLandsOnThePanel() {
        #expect(accepts(topLeft: CGPoint(x: regions.cards.midX, y: regions.cards.midY), regions))
    }

    @Test func aClickOnTheResultsSlabLandsOnThePanel() {
        #expect(accepts(topLeft: CGPoint(x: regions.results.midX, y: regions.results.midY), regions))
    }

    @Test func aClickInTheGapBetweenTheSlabsIsOutside() {
        let gapMiddle = CGPoint(
            x: regions.cards.midX,
            y: regions.cards.maxY + Style.gap / 2
        )
        #expect(accepts(topLeft: gapMiddle, regions) == false)
    }

    @Test(arguments: [
        CGPoint(x: 4, y: 4),                                  // top-left margin
        CGPoint(x: PanelLayout.panelWidth - 4, y: 4),          // top-right
        CGPoint(x: 4, y: PanelLayout.panelHeight - 4),         // bottom-left
        CGPoint(x: PanelLayout.panelWidth / 2, y: 4),          // above the Cards
        CGPoint(x: PanelLayout.panelWidth / 2,
                y: PanelLayout.panelHeight - 4),               // below the Slab
    ])
    func aClickOnTheMarginIsOutside(point: CGPoint) {
        #expect(accepts(topLeft: point, regions) == false)
    }

    @Test func aClickBesideTheCardRowIsOutside() {
        let besideCards = CGPoint(x: regions.cards.minX - 8, y: regions.cards.midY)
        #expect(accepts(topLeft: besideCards, regions) == false)
    }

    /// The Slab surrenders its region when it leaves. Without that, clicks keep
    /// landing on a surface that is no longer on screen.
    @Test func aClickWhereAnAbsentSlabUsedToBeIsOutside() {
        var withoutResults = regions
        let wasAt = CGPoint(x: withoutResults.results.midX, y: withoutResults.results.midY)
        withoutResults.results = .zero

        #expect(accepts(topLeft: wasAt, withoutResults) == false)
        #expect(
            accepts(topLeft: CGPoint(x: regions.cards.midX, y: regions.cards.midY), withoutResults),
            "the Card row is unaffected"
        )
    }

    @Test func anEmptyLayoutAcceptsNothing() {
        let empty = PanelHitRegions()
        #expect(accepts(topLeft: CGPoint(x: 100, y: 100), empty) == false)
        #expect(accepts(topLeft: .zero, empty) == false)
    }
}
