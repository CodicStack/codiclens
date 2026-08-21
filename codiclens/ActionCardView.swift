import SwiftUI

struct ActionCardView: View {
    let coordinator: CommandCoordinator

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
        .cardSurface(focused: isFocused)
        .padding(Style.cardInset)
    }

    private func actionContent(_ action: SubjectAction) -> some View {
        VStack(spacing: 10) {
            actionIconView(action.icon)
                .frame(width: Style.cardIcon, height: Style.cardIcon)

            Text(action.name)
                .font(.system(size: 15, weight: .semibold))
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

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.right.circle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.quaternary)

            if coordinator.actionVM.searchText.isEmpty {
                Text("Action")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.quaternary)
            } else {
                Text(coordinator.actionVM.searchText)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Text("No results")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
