import SwiftUI

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
        } else if coordinator.targetVM.isSearching {
            searchingState
        } else if hasQuery {
            emptyState
        }
    }

    /// The Query, spelled out along the bottom of the Slab.
    ///
    /// Display-only: every keystroke is still captured by the hidden field in
    /// `CardContainerView`, and this only ever reads. It exists because the
    /// Subject Card shows what the Query *matched* — type `saf` and the Card says
    /// "Safari" — so without this there is nowhere to see what you actually
    /// typed. With 1,914 Emoji to filter, that is not optional.
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
        .padding(.vertical, Style.rowPaddingV)
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
        .padding(.vertical, Style.padding)
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("No results for \"\(coordinator.currentQuery)\"")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Style.padding)
        .padding(.vertical, Style.padding)
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

    private var list: some View {
        ScrollViewReader { proxy in
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
            }
            .frame(maxHeight: 260)
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
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(highlightedName(item.name, query: query))
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                    .lineLimit(1)

                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
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
                .frame(width: 32, height: 32)
        }
    }
}
