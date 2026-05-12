import SwiftUI

struct ResultsListView: View {
    @Bindable var coordinator: CommandCoordinator
    @Environment(\.colorScheme) private var colorScheme

    private var hasQuery: Bool {
        !coordinator.currentQuery.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if !coordinator.currentResults.isEmpty {
                header
                Divider().padding(.horizontal, 10)
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
            Text("Searching...")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        HStack {
            Text("No results for \"\(coordinator.currentQuery)\"")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var header: some View {
        HStack {
            Text("\(coordinator.currentResults.count) results")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if !coordinator.currentQuery.isEmpty {
                Text("\"\(coordinator.currentQuery)\"")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            ForEach(hints, id: \.self) { hint in
                Text(hint)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(colorScheme == .dark
                        ? Color.black.opacity(0.92)
                        : Color.white.opacity(0.92))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 260)
            .onChange(of: coordinator.currentSelectedIndex) { _, newIndex in
                if newIndex < coordinator.currentResults.count {
                    withAnimation(.easeOut(duration: 0.1)) {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
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
