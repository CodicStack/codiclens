import SwiftUI

struct ResultsListView: View {
    @Bindable var coordinator: CommandCoordinator

    private var hasQuery: Bool {
        !coordinator.currentQuery.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
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
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            Text("\(coordinator.currentResults.count) results")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if !coordinator.currentQuery.isEmpty {
                Text("\"\(coordinator.currentQuery)\"")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

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
