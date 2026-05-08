import SwiftUI

struct CardContainerView: View {
    @Bindable var coordinator: CommandCoordinator
    @FocusState private var isSearchFocused: Bool
    @State private var textProxy: String = ""
    @State private var suppressSync: Bool = false

    var body: some View {
        ZStack {
            hiddenSearchField
            cardRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: coordinator.focusTrigger) {
            refocus()
            if coordinator.returningFromQuickLook {
                coordinator.returningFromQuickLook = false
            } else {
                suppressSync = true
                textProxy = coordinator.currentSearchText
                DispatchQueue.main.async { suppressSync = false }
            }
        }
        .onChange(of: coordinator.cardCount) {
            refocus()
        }
        .onChange(of: coordinator.phase) { _, _ in
            textProxy = coordinator.currentSearchText
        }
    }

    private func refocus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isSearchFocused = true
        }
    }

    private var hiddenSearchField: some View {
        TextField("", text: $textProxy)
        .textFieldStyle(.plain)
        .focused($isSearchFocused)
        .frame(width: 0, height: 0)
        .opacity(0)
        .onChange(of: textProxy) { oldValue, newValue in
            guard !suppressSync else { return }

            if coordinator.phase == .searchingSubject
                        && coordinator.subjectVM.isSearchCommitted
                        && !coordinator.isTextMode {
                if newValue.count > oldValue.count {
                    let added = String(newValue.dropFirst(oldValue.count))
                    suppressSync = true
                    textProxy = added
                    coordinator.currentSearchText = added
                    DispatchQueue.main.async { self.suppressSync = false }
                } else if newValue.isEmpty {
                    suppressSync = true
                    textProxy = ""
                    coordinator.currentSearchText = ""
                    DispatchQueue.main.async { self.suppressSync = false }
                } else {
                    suppressSync = true
                    textProxy = newValue
                    coordinator.currentSearchText = newValue
                    DispatchQueue.main.async { self.suppressSync = false }
                }
            } else {
                coordinator.currentSearchText = newValue
            }
        }
        .onSubmit { coordinator.submit() }
        .onKeyPress(.upArrow) {
            coordinator.moveUp()
            return .handled
        }
        .onKeyPress(.downArrow) {
            coordinator.moveDown()
            return .handled
        }
        .onKeyPress(.escape) {
            coordinator.handleEscape() ? .handled : .ignored
        }
        .onKeyPress { press in
            if press.key == .tab && press.modifiers.isEmpty {
                coordinator.advancePhase()
                return .handled
            }
            if press.key == .tab && press.modifiers.contains(.shift) {
                coordinator.retreatPhase()
                return .handled
            }
            if press.modifiers.contains(.command) && press.characters == "e" {
                coordinator.toggleClipboardEdit()
                return .handled
            }
            if press.modifiers.contains(.command) &&
                (press.key == .delete || press.characters == "\u{7F}" || press.characters == "\u{8}") {
                coordinator.retreatPhase()
                return .handled
            }
            if press.key == .space && press.modifiers.contains(.shift) {
                coordinator.triggerQuickLook()
                return .handled
            }
            if press.modifiers.contains(.control) {
                if press.characters == "e" || press.characters == "\u{05}" {
                    coordinator.toggleClipboardEdit()
                    return .handled
                }
                switch press.characters {
                case "j":
                    coordinator.moveDown()
                    return .handled
                case "k":
                    coordinator.moveUp()
                    return .handled
                case "h":
                    coordinator.retreatPhase()
                    return .handled
                case "l":
                    coordinator.advancePhase()
                    return .handled
                default:
                    break
                }
            }
            return .ignored
        }
    }

    private var cardRow: some View {
        HStack(spacing: 6) {
            SubjectCardView(coordinator: coordinator)

            if coordinator.cardCount >= 2 {
                ActionCardView(coordinator: coordinator)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0, anchor: .leading)
                                .combined(with: .opacity),
                            removal: .scale(scale: 0, anchor: .leading)
                                .combined(with: .opacity)
                        )
                    )
            }

            if coordinator.cardCount >= 3 {
                TargetCardView(coordinator: coordinator)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0, anchor: .leading)
                                .combined(with: .opacity),
                            removal: .scale(scale: 0, anchor: .leading)
                                .combined(with: .opacity)
                        )
                    )
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: coordinator.cardCount)
        .padding(6)
    }
}
