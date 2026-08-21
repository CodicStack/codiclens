import SwiftUI

/// The Results Slab's contents: whatever is being listed, and the Query field
/// pinned along the bottom.
///
/// **The Slab is as tall as what it holds.** Everything variable about its
/// height is the scrolling area's, which carries a definite height from
/// `PanelLayout.resultsAreaHeight(contentHeight:chromeHeight:)`; the header, the
/// message rows and the Query field are fixed for a given state. The Slab used
/// to be given `maxHeight` instead, and a flexible maximum inside a window
/// sized to the worst case takes the worst case — the Query field ended up
/// directly under the divider with an empty pane below it.
struct ResultsListView: View {
    @Bindable var coordinator: CommandCoordinator

    private var hasQuery: Bool {
        !coordinator.currentQuery.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            results
            queryField
        }
        .frame(maxWidth: .infinity)
        // The ceiling, and the only maximum left. Nothing reaches it: each
        // Results area's own ceiling already has this state's furniture and the
        // Query field taken off it.
        .frame(maxHeight: PanelLayout.maxResultsHeight)
        // Hug what the two of them came out as.
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var results: some View {
        if coordinator.isEmojiBrowsing {
            EmojiGridView(coordinator: coordinator)
        } else if !coordinator.currentResults.isEmpty {
            header
            Divider().padding(.horizontal, Style.padding)
            list
        } else if coordinator.isSearchInFlight {
            searchingState
        } else if hasQuery && coordinator.canReportNoResults {
            emptyState
        }
    }

    /// The Query, spelled out along the bottom edge of the Slab.
    ///
    /// Display-only: every keystroke is still captured by the hidden field in
    /// `CardContainerView`, and this only ever reads. It exists because the
    /// Subject Card shows what the Query *matched* — type `saf` and the Card says
    /// "Safari" — so without this there is nowhere to see what you actually
    /// typed. With 1,914 Emoji to filter, that is not optional. It is also the
    /// only place the Query is spelled out: everything else on screen names what
    /// it matched.
    ///
    /// A bar, not a row: `PanelLayout.queryFieldHeight` and nothing else, so it
    /// neither grows nor moves as the Results change. The Results area above it
    /// takes all the variable height.
    private var queryField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)

            Text(hasQuery ? coordinator.currentQuery : "Type to search")
                .font(.system(size: 13))
                .foregroundStyle(hasQuery ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                // The tail is what was typed most recently, so a long Query
                // truncates at the front.
                .truncationMode(.head)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Style.padding)
        .frame(height: PanelLayout.queryFieldHeight)
        .overlay(alignment: .top) {
            Divider().padding(.horizontal, Style.padding)
        }
    }

    private var searchingState: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Searching…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Style.padding)
        .frame(minHeight: PanelLayout.messageRowHeight)
    }

    /// No Results, and deliberately not saying what for.
    ///
    /// The Query used to be interpolated into this line, which printed it twice
    /// — once here and once in the field directly below — and a long Query
    /// wrapped this line over three of them while the field truncated it. One
    /// Query on screen at a time; the field is where it lives.
    ///
    /// No magnifying glass either, for the same reason: the Query bar
    /// immediately below carries one, and two of them a few points apart read as
    /// two search fields. The bar's is the one that means something.
    private var emptyState: some View {
        HStack(spacing: 8) {
            Text("No results")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Style.padding)
        .frame(minHeight: PanelLayout.messageRowHeight)
    }

    private var header: some View {
        HStack(spacing: 6) {
            // No Query here. It used to be repeated in this header; the field
            // pinned along the bottom of the Slab is where it belongs.
            Text("\(coordinator.currentResults.count) results")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer()

            ForEach(hints, id: \.self) { hint in
                Text(hint)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .chipSurface()
            }
        }
        .padding(.horizontal, Style.padding)
        .padding(.vertical, Style.rowPaddingV)
    }

    private var hints: [String] {
        if coordinator.isEditingClipboardItem {
            return ["⌘E save", "⇥ save+actions"]
        }
        if coordinator.phase == .browsingClipboard {
            let item = coordinator.currentClipboardItem
            var h = ["⏎ paste"]
            if item != nil && !(item?.isImage ?? false) {
                h.append("⌘E edit")
            }
            h.append("⇥ actions")
            return h
        }
        return []
    }

    /// The rows, in an area as tall as the rows are — up to what is left of the
    /// Slab once the header, its divider and the Query field have had theirs.
    private var list: some View {
        let height = PanelLayout.resultsAreaHeight(
            contentHeight: PanelLayout.listContentHeight(rows: coordinator.currentResults.count),
            chromeHeight: PanelLayout.resultsHeaderHeight + Style.hairline
        )

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(coordinator.currentResults.enumerated()), id: \.element.id) { index, item in
                        ResultRow(
                            item: item,
                            query: coordinator.currentQuery,
                            isSelected: index == coordinator.currentSelectedIndex
                        )
                        .id(item.id)
                        .onTapGesture {
                            coordinator.currentSelectedIndex = index
                            coordinator.submit()
                        }
                    }
                }
                .padding(.vertical, Style.resultInset)
                // The area's size springs; the rows inside it do not.
                .hardCut()
            }
            .frame(height: height)
            // A Slab following its content is a surface changing size, which is
            // what `resize` is for. Keyed to the height, so it is the height and
            // nothing else that animates: moving the selection cannot change
            // this value, so the highlight still lands on the frame the key was
            // pressed.
            .animation(Motion.resize, value: height)
            .onChange(of: coordinator.currentSelectedIndex) { _, newIndex in
                if newIndex < coordinator.currentResults.count {
                    withAnimation(Motion.snappy) {
                        proxy.scrollTo(coordinator.currentResults[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct ResultRow: View {
    let item: ResultDisplayItem
    let query: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            iconView
                .frame(width: PanelLayout.resultIconSize, height: PanelLayout.resultIconSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(highlightedName(item.name, query: query))
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                    .lineLimit(1)

                if !item.subtitle.isEmpty {
                    // Marked up like the title where the subtitle names the
                    // thing — under "Clipboard" it reads "Clipboard History",
                    // and the characters the Query matched are in both. Left
                    // plain where the subtitle is derived rather than named;
                    // `ResultDisplayItem.highlightsSubtitle` is where that is
                    // decided, per kind of Result.
                    Text(
                        item.highlightsSubtitle
                            ? highlightedName(item.subtitle, query: query)
                            : AttributedString(item.subtitle)
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, Style.rowPaddingH)
        .padding(.vertical, Style.rowPaddingV)
        .resultSurface(selected: isSelected)
        .padding(.horizontal, Style.resultInset)
    }

    @ViewBuilder
    private var iconView: some View {
        switch item.icon {
        case .nsImage(let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        case .sfSymbol(let name):
            Image(systemName: name)
                .font(.system(size: 20))
                .frame(width: PanelLayout.resultIconSize, height: PanelLayout.resultIconSize)
        }
    }
}
