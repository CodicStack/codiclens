import SwiftUI

struct CardContainerView: View {
    @Bindable var coordinator: CommandCoordinator
    @FocusState private var isSearchFocused: Bool

    /// What the text field holds. Assigning this is what actually forces the
    /// field's contents — a binding that merely returns a different value does
    /// not, which is why the query has to live here as state.
    @State private var fieldText: String = ""

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
        .onChange(of: coordinator.focusTrigger) {
            refocus()
            showCurrentQuery()
        }
        .onChange(of: coordinator.cardCount) { refocus() }
        .onChange(of: coordinator.phase) { showCurrentQuery() }
    }

    private func refocus() {
        isSearchFocused = true
    }

    /// Points the field at whatever the current phase is searching.
    private func showCurrentQuery() {
        coordinator.syncQueryDisplay()
        fieldText = coordinator.displayedQuery
    }

    private var hiddenSearchField: some View {
        TextField("", text: $fieldText)
        .textFieldStyle(.plain)
        .focused($isSearchFocused)
        .frame(width: 0, height: 0)
        .opacity(0)
        .onChange(of: fieldText) { _, typed in
            // Ignore the echo of our own write: the coordinator already knows
            // it put this text in the field. Anything else is the user typing.
            guard typed != coordinator.displayedQuery else { return }
            fieldText = coordinator.acceptTypedText(typed)
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
        .onKeyPress(.leftArrow) {
            coordinator.moveLeft() ? .handled : .ignored
        }
        .onKeyPress(.rightArrow) {
            coordinator.moveRight() ? .handled : .ignored
        }
        .onKeyPress(.escape) {
            coordinator.handleEscape() ? .handled : .ignored
        }
        .onKeyPress { press in
            if press.key == .return && press.modifiers.contains(.option) {
                if coordinator.toggleSkinTonePicker() { return .handled }
            }
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
        .animation(Motion.resize, value: coordinator.cardCount)
        .padding(6)
    }
}
