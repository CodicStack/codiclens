import SwiftUI

struct TargetCardView: View {
    let coordinator: CommandCoordinator

    private var isFocused: Bool {
        if case .pickingTarget = coordinator.phase { return true }
        return false
    }

    private var target: ActionTarget? {
        let vm = coordinator.targetVM
        guard vm.selectedIndex < vm.filteredTargets.count else { return nil }
        return vm.filteredTargets[vm.selectedIndex]
    }

    var body: some View {
        Group {
            if let target {
                targetContent(target)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardSurface(focused: isFocused)
        .padding(Style.cardInset)
    }

    private func targetContent(_ target: ActionTarget) -> some View {
        VStack(spacing: 10) {
            Image(nsImage: target.icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)

            Text(target.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.quaternary)

            if coordinator.targetVM.searchText.isEmpty {
                Text("Type to search…")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.quaternary)
            } else {
                Text(coordinator.targetVM.searchText)
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
