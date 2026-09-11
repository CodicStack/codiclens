import SwiftUI

struct ActionCardView: View {
    let coordinator: CommandCoordinator

    /// The Card row's glass namespace: this Card's glass grows out of the
    /// Subject Card's, and the Target Card's grows out of this one.
    let glassNamespace: Namespace.ID

    private var isFocused: Bool {
        if case .pickingAction = coordinator.phase { return true }
        return false
    }

    private var action: SubjectAction? {
        let vm = coordinator.actionVM
        guard vm.selectedIndex < vm.filteredActions.count else { return nil }
        return vm.filteredActions[vm.selectedIndex]
    }

    var body: some View {
        Group {
            if let action {
                actionContent(action)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if let keyHint {
                KeyHintChip(keys: keyHint)
                    .padding(Style.padding)
            }
        }
        .cardSurface(focused: isFocused, phase: .action, in: glassNamespace)
        .padding(Style.cardInset)
    }

    /// A Final Action runs on Enter; anything else asks for a Target first, so
    /// the key that moves you on is Tab.
    private var keyHint: String? {
        guard isFocused, let action else { return nil }
        return action.isFinal ? "⏎" : "⇥"
    }

    private func actionContent(_ action: SubjectAction) -> some View {
        VStack(spacing: 10) {
            actionIconView(action.icon)
                .frame(width: Style.cardIcon, height: Style.cardIcon)

            Text(action.name)
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
                .foregroundStyle(.primary)

            if !action.isFinal {
                Text("→")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actionIconView(_ icon: ActionIcon) -> some View {
        switch icon {
        case .sfSymbol(let name):
            Image(systemName: name)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.primary)
        case .appIcon(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        }
    }

    /// Nothing matched, said without repeating the Query.
    ///
    /// This Card used to spell the Query out above the message. The Query field
    /// along the bottom of the Results Slab is now always on screen, so that put
    /// it there twice — and one Query on screen at a time is the rule. The
    /// Subject Card's placeholder has always read this way.
    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.right.circle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.quaternary)

            Text(coordinator.actionVM.searchText.isEmpty ? "Action" : "No results")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.quaternary)
        }
    }
}
