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
            if press.modifiers.contains(.control),
               let letter = ControlKey.letter(press.characters) {
                switch letter {
                case "e":
                    coordinator.toggleClipboardEdit()
                    return .handled
                case "j":
                    coordinator.moveDown()
                    return .handled
                case "k":
                    coordinator.moveUp()
                    return .handled
                // In the Emoji grid these two are one cell left and right — or
                // one Skin Tone while the ⌥Enter picker is open. `moveLeft` and
                // `moveRight` report whether they meant anything, exactly as the
                // arrow keys use them, and only when they don't does the key
                // move the Phase. Routing straight to the Phase is what took
                // Ctrl+H and Ctrl+L out of Emoji Mode and advanced the Subject
                // sitting behind it from Subject to Action.
                case "h":
                    if !coordinator.moveLeft() { coordinator.retreatPhase() }
                    return .handled
                case "l":
                    if !coordinator.moveRight() { coordinator.advancePhase() }
                    return .handled
                default:
                    break
                }
            }
            return .ignored
        }
    }

    /// The Cards for the Phases reached so far.
    ///
    /// `.identity` on the Cards that come and go is not an oversight. What
    /// animates when a Phase is added is the *row's* width — driven by
    /// `PanelView`, which owns this view's frame — while the Card itself
    /// hard-cuts into place. A Card that scales or fades in delays information
    /// the user has already asked for, which is the trap `docs/adr/0003` exists
    /// to prevent.
    private var cardRow: some View {
        HStack(spacing: 6) {
            SubjectCardView(coordinator: coordinator)

            if coordinator.cardCount >= 2 {
                ActionCardView(coordinator: coordinator)
                    .transition(.identity)
            }

            if coordinator.cardCount >= 3 {
                TargetCardView(coordinator: coordinator)
                    .transition(.identity)
            }
        }
        .padding(6)
    }
}
