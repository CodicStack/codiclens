import SwiftUI

struct CardContainerView: View {
    @Bindable var coordinator: CommandCoordinator
    @FocusState private var isSearchFocused: Bool

    private let becameKeyPublisher = NotificationCenter.default.publisher(
        for: NSWindow.didBecomeKeyNotification
    )

    var body: some View {
        ZStack {
            hiddenSearchField
            cardRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(becameKeyPublisher) { notification in
            guard notification.object is FloatingPanel else { return }
            isSearchFocused = true
        }
        .onChange(of: coordinator.focusTrigger) { refocus() }
        .onChange(of: coordinator.cardCount) { refocus() }
    }

    private func refocus() {
        isSearchFocused = true
    }

    /// The field reads the current query straight from the coordinator and
    /// hands keystrokes back to it. There is no second copy of the text here to
    /// keep in sync.
    private var query: Binding<String> {
        Binding(
            get: { coordinator.currentSearchText },
            set: { coordinator.acceptTypedText($0) }
        )
    }

    private var hiddenSearchField: some View {
        TextField("", text: query)
        .textFieldStyle(.plain)
        .focused($isSearchFocused)
        .frame(width: 0, height: 0)
        .opacity(0)
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
            if press.key == .return {
                coordinator.submit()
                return .handled
            }
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
        .animation(.spring(response: 0.15, dampingFraction: 0.8), value: coordinator.cardCount)
        .padding(6)
    }
}
