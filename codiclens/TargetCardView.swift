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
        .overlay(alignment: .bottomTrailing) {
            if isFocused, target != nil {
                KeyHintChip(keys: "⏎")
                    .padding(Style.padding)
            }
        }
        .cardSurface(focused: isFocused)
        .cardBeam(identity: CardBeamIdentity.target(coordinator))
        .padding(Style.cardInset)
    }

    private func targetContent(_ target: ActionTarget) -> some View {
        VStack(spacing: 10) {
            Image(nsImage: target.icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: Style.cardIcon, height: Style.cardIcon)

            Text(target.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
    }

    /// Nothing matched, said without repeating the Query — which the Query field
    /// along the bottom of the Results Slab is already showing.
    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.quaternary)

            Text(coordinator.targetVM.searchText.isEmpty ? "Type to search…" : "No results")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.quaternary)
        }
    }
}
