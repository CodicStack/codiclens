import SwiftUI

/// The Panel's own state, as SwiftUI sees it.
///
/// Two values, both written by `PanelController` and read by the view or by the
/// controller — never by both. `visible` drives the entrance and exit;
/// `hitRegions` travels the other way, from the layout back to the controller's
/// hit test.
@Observable
final class PanelPresentation {

    /// Drives `Motion.panelEntrance`. Flipped inside
    /// `withAnimation(Motion.entrance)` to animate, and assigned bare to cut.
    var visible = false

    /// Where the two surfaces actually ended up. Nothing in the view reads this,
    /// so writing it from a layout callback cannot provoke another render.
    var hitRegions = PanelHitRegions()
}

/// Everything inside the one Panel: the Card row, a real gap, the Results Slab,
/// and the Update Notice a gap under it while an update is waiting.
///
/// There is deliberately **no Slab behind the Cards**. Each Card is its own
/// top-level surface floating over the desktop, which is why `Style.cardSurface`
/// is built like `Style.slabSurface` rather than like a fill.
///
/// The whole thing sits inside `PanelLayout.margin` of empty space. That margin
/// is what lets `panelEntrance` scale past 1.0 and lets each surface cast a
/// shadow without either being clipped into a band by the window bounds.
struct PanelView: View {
    @Bindable var coordinator: CommandCoordinator
    let presentation: PanelPresentation

    /// Bumped every time a Query stops matching anything, which is what the
    /// shake reacts to.
    ///
    /// Detected here rather than in `SubjectSearchVM`: falling back to a text
    /// Subject is the view model's business, and nothing below the view needs to
    /// know the Panel shook about it.
    @State private var shakeTrigger = 0

    /// Where the hidden field's keys reach the preview while one is open.
    @State private var previewDriver = PassagePreviewDriver()

    var body: some View {
        // One container for every piece of glass in the Panel, which is what
        // lets a Card's **Arrival** morph out of the Card before it. Its spacing
        // is the distance at which two pieces of glass would fuse into one body,
        // and it is deliberately far below the 12pt gutter between two Cards:
        // Cards sit near each other and never merge. The container itself is not
        // glass — only its children are.
        GlassEffectContainer(spacing: Style.glassMergeDistance) {
            VStack(spacing: Style.gap) {
                cardRow
                if let preview = coordinator.passagePreview {
                    previewSlab(preview)
                } else {
                    resultsSlab
                }
                updateNotice
            }
        }
        .frame(
            width: PanelLayout.contentWidth,
            height: PanelLayout.contentHeight,
            alignment: .top
        )
        .padding(PanelLayout.margin)
        // Presence only. A Slab arriving and leaving is a surface changing size;
        // what it *contains* hard-cuts, because the user already asked for it.
        // The Slab growing and shrinking with its content is the same curve,
        // applied where that height is computed — the Results area's own frame.
        .animation(Motion.resize, value: showsSlab)
        .panelEntrance(visible: presentation.visible)
        .coordinateSpace(.named(PanelLayout.coordinateSpace))
        .onChange(of: showsSlab) { _, shows in
            // The Slab's frame stops being reported the moment it leaves, so its
            // hit region has to be surrendered explicitly or clicks keep landing
            // on a surface that is no longer there.
            if !shows { presentation.hitRegions.results = .zero }
        }
        // The same for the Update Notice, when the update goes.
        .onChange(of: coordinator.updateNotice == nil) { _, gone in
            if gone { presentation.hitRegions.notice = .zero }
        }
        .onChange(of: hasNoMatch) { _, noMatch in
            guard noMatch else { return }
            withAnimation(Motion.entrance) { shakeTrigger += 1 }
        }
        // An image with no readable text is a no-match too, and it shakes about
        // it the same way. The same trigger, not a second mechanism.
        .onChange(of: coordinator.ocrFoundNoText) { _, foundNothing in
            guard foundNothing else { return }
            withAnimation(Motion.entrance) { shakeTrigger += 1 }
        }
        .onChange(of: coordinator.imageActionFailed) { _, failed in
            guard failed else { return }
            withAnimation(Motion.entrance) { shakeTrigger += 1 }
        }
        // A Move, Rename or Compress that did not happen, a taken name among
        // them. The Subject Card's corner says which.
        .onChange(of: coordinator.fileOperationFailure) { _, failure in
            guard failure != nil else { return }
            withAnimation(Motion.entrance) { shakeTrigger += 1 }
        }
        // A Transcribe that came to nothing, Codictate missing among them.
        .onChange(of: coordinator.transcriptionFailure) { _, failure in
            guard failure != nil else { return }
            withAnimation(Motion.entrance) { shakeTrigger += 1 }
        }
    }

    // MARK: - The Card row

    /// The Cards, and the hidden field that captures every keystroke.
    ///
    /// `CardContainerView` keeps the keyboard: it owns the hidden `TextField`
    /// that everything is typed into, and that must not move.
    private var cardRow: some View {
        CardContainerView(coordinator: coordinator, previewDriver: previewDriver)
            .frame(
                width: PanelLayout.cardRowWidth(coordinator.cardCount),
                height: PanelLayout.cardHeight
            )
            .animation(Motion.resize, value: coordinator.cardCount)
            .shake(trigger: shakeTrigger)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(PanelLayout.coordinateSpace))
            } action: { frame in
                presentation.hitRegions.cards = frame
            }
    }

    // MARK: - The Results Slab

    /// The Slab, as tall as what it holds.
    ///
    /// No height is imposed here. `ResultsListView` hugs its own content up to
    /// `PanelLayout.maxResultsHeight`, and the space the Panel reserved for the
    /// worst case is simply left empty below it — which is why the frame is
    /// *reported* to `hitRegions` rather than assumed: a click in that empty
    /// space has to dismiss the Panel, and the region has to shrink with the
    /// Slab for it to.
    ///
    /// The width is `PanelLayout.slabWidth`, not the Card row's: under a single
    /// Card the Slab keeps its own floor and overhangs the Card on both sides,
    /// which is what the Emoji grid's five fixed columns need.
    @ViewBuilder
    private var resultsSlab: some View {
        if showsResults {
            ResultsListView(coordinator: coordinator)
                .frame(width: PanelLayout.slabWidth(coordinator.cardCount))
                .slabSurface()
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(PanelLayout.coordinateSpace))
                } action: { frame in
                    presentation.hitRegions.results = frame
                }
                .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
        }
    }

    /// The Panel's own preview of a File Result, where the Results Slab was:
    /// as wide as the widest Card row and as tall as the tallest Slab, so a
    /// page is worth reading at any Phase. Its frame is the Slab's hit region,
    /// so a click in it scrolls or plays rather than dismissing.
    private func previewSlab(_ preview: PassagePreview) -> some View {
        PassagePreviewView(preview: preview, driver: previewDriver)
            .id(preview)
            .frame(width: PanelLayout.contentWidth, height: PanelLayout.maxResultsHeight)
            .slabSurface()
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(PanelLayout.coordinateSpace))
            } action: { frame in
                presentation.hitRegions.results = frame
            }
            .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
    }

    // MARK: - The Update Notice

    /// The strip, a gap under whatever is last in the column: the Results
    /// Slab, the preview, or the Card row. Being in the same column is what
    /// moves it with the Slab — a Slab arriving or leaving animates the column
    /// on `Motion.resize`, so the strip rides the same curve to its new place.
    /// Its own arrival and its text hard-cut: an update turning up is
    /// information, and the user did not cause it.
    ///
    /// Its frame is a hit region of its own, so a click on it acts rather
    /// than dismissing.
    @ViewBuilder
    private var updateNotice: some View {
        if let notice = coordinator.updateNotice {
            UpdateNoticeView(notice: notice) { coordinator.actOnUpdateNotice() }
                .frame(width: PanelLayout.updateNoticeWidth(
                    cardCount: coordinator.cardCount,
                    underPreview: coordinator.passagePreview != nil
                ))
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(PanelLayout.coordinateSpace))
                } action: { frame in
                    presentation.hitRegions.notice = frame
                }
        }
    }

    /// Whether a Slab is showing: the Results Slab, or the preview in its
    /// place.
    private var showsSlab: Bool {
        coordinator.passagePreview != nil || showsResults
    }

    /// Whether the Results Slab is showing at all.
    ///
    /// Emoji Mode is the exception: its grid is never empty, not even on first
    /// run, so the Slab is unconditional there.
    private var showsResults: Bool {
        if coordinator.isEmojiBrowsing { return true }
        // "Reading text…" is something the Slab is saying, so the Slab has to
        // be there to say it — even if the Action list behind it were empty.
        if coordinator.isOCRInFlight { return true }
        if !coordinator.currentResults.isEmpty { return true }
        if coordinator.targetVM.isSearching { return true }
        return !coordinator.currentQuery.isEmpty
    }

    /// Whether the Query matched nothing.
    ///
    /// The Index having answered *and* answered with nothing — not "the visible
    /// Subject is a text one", which was the old proxy for it. That proxy also
    /// matched the moment before the first scan lands, so a cold start shook the
    /// Panel at a Query it had not looked up yet. Read, not changed: the
    /// no-match itself is the view model's finding and stays there.
    private var hasNoMatch: Bool {
        coordinator.hasNoSubjectMatch
    }
}
