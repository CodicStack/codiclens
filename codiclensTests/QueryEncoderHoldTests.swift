import Testing
@testable import codiclens

/// The query encoder is held while the Panel is up and let go as it hides,
/// once each way whichever paths the Panel takes, as `PanelController` calls
/// it. Counted here: the controller itself is never built in the test host.
@MainActor
struct QueryEncoderHoldTests {
    final class Counts {
        var holds = 0
        var releases = 0
    }

    private func make() -> (QueryEncoderHold, Counts) {
        let counts = Counts()
        return (QueryEncoderHold(hold: { counts.holds += 1 }, release: { counts.releases += 1 }), counts)
    }

    @Test func showingHoldsAndHidingReleases() {
        let (encoder, counts) = make()

        encoder.panelShown()
        #expect((counts.holds, counts.releases) == (1, 0))
        encoder.panelHidden()
        #expect((counts.holds, counts.releases) == (1, 1))

        encoder.panelShown()
        encoder.panelHidden()
        #expect((counts.holds, counts.releases) == (2, 2))
    }

    /// `tearDown` hides again after a hide, and the save panel's Cancel shows
    /// the Panel again without `showPanel`: neither holds or releases twice.
    @Test func aSecondHideOrShowDoesNothing() {
        let (encoder, counts) = make()

        encoder.panelHidden()
        #expect(counts.releases == 0, "nothing held")

        encoder.panelShown()
        encoder.panelShown()
        #expect(counts.holds == 1)

        encoder.panelHidden()
        encoder.panelHidden()
        #expect(counts.releases == 1)
    }
}
