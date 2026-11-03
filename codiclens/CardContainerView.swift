import SwiftUI

struct CardContainerView: View {
    @Bindable var coordinator: CommandCoordinator
    /// The Panel's own preview, which answers the arrows and Space while it
    /// is open.
    let previewDriver: PassagePreviewDriver
    @FocusState private var isSearchFocused: Bool

    /// The namespace the Cards' glass is matched in, which is what makes an
    /// **Arrival** an Arrival: the Action Card's glass grows out of the Subject
    /// Card's, and the Target Card's out of the Action Card's. It lives here
    /// because this is the view that inserts and removes them.
    @Namespace private var glassNamespace

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

    /// Whether the Panel's own preview is open, and so has the arrows and
    /// Space.
    private var isPreviewing: Bool { coordinator.passagePreview != nil }

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
            if isPreviewing { previewDriver.scroll(by: -1) } else { coordinator.moveUp() }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if isPreviewing { previewDriver.scroll(by: 1) } else { coordinator.moveDown() }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            if isPreviewing {
                previewDriver.step(by: -1)
                return .handled
            }
            return coordinator.moveLeft() ? .handled : .ignored
        }
        .onKeyPress(.rightArrow) {
            if isPreviewing {
                previewDriver.step(by: 1)
                return .handled
            }
            return coordinator.moveRight() ? .handled : .ignored
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
            // Shift+Tab does not arrive as `.tab`, and that is why this used
            // to do nothing at all.
            //
            // AppKit gives a back-tab its own control character — `NSText.h`
            // spells them `NSTabCharacter = 0x0009` and
            // `NSBackTabCharacter = 0x0019` — and SwiftUI passes it straight
            // through: `press.key` is U+0019, not `.tab`, so a
            // `press.key == .tab && press.modifiers.contains(.shift)` test is
            // false for every Shift+Tab ever pressed. `KeyEquivalent` has no
            // `.backTab` member, so the scalar literal is the only spelling
            // available.
            //
            // **Measured, not reasoned.** Apple documents none of this, and
            // `KeyPress.characters` is documented as the characters "as if no
            // modifier key applies" — which reads like a promise that a back-tab
            // normalises back down to a tab, and is wrong. A probe logging the
            // scalars of both fields recorded, for one Shift+Tab:
            //
            //     key=U+0019 characters=U+0019 modifiers=0x0002[shift]
            //
            // and for a plain Tab, `U+0009` in both with no modifiers. So both
            // fields carry the back-tab and `.shift` is present as well.
            //
            // The `.shift` test is not redundant: U+0019 is also what Ctrl+Y
            // produces, and without it Ctrl+Y would retreat the Phase.
            if press.key == KeyEquivalent("\u{19}") && press.modifiers.contains(.shift) {
                // Unconditional, because Tab is unconditional — Shift+Tab is the
                // exact inverse of Tab and nothing else. Deliberately *not*
                // Ctrl+H's grid-first shape (`if !moveLeft() { retreatPhase() }`):
                // in Emoji Mode Shift+Tab has to leave the grid, not walk one
                // cell left.
                coordinator.retreatPhase()
                return .handled
            }
            if press.key == .tab && press.modifiers.isEmpty {
                coordinator.advancePhase()
                return .handled
            }
            if press.modifiers.contains(.command) && press.characters == "e" {
                coordinator.toggleTextSubjectEdit()
                return .handled
            }
            // The Update Notice, in every Phase. With no update it does
            // nothing, and is still taken so it never reaches the field.
            if press.modifiers.contains(.command) && press.characters == "u" {
                coordinator.actOnUpdateNotice()
                return .handled
            }
            if press.modifiers.contains(.command) &&
                (press.key == .delete || press.characters == "\u{7F}" || press.characters == "\u{8}") {
                // On a Clipboard Item this deletes it from Clipboard History, as
                // Cmd+Delete does in Finder; anywhere else it retreats the Phase.
                if !coordinator.deleteSelectedClipboardItem() { coordinator.retreatPhase() }
                return .handled
            }
            if press.key == .space && press.modifiers.contains(.shift) {
                coordinator.triggerQuickLook()
                return .handled
            }
            // Space plays or pauses the preview's video, or pages its text,
            // rather than typing a space into the Query behind it.
            if isPreviewing && press.key == .space && press.modifiers.isEmpty {
                previewDriver.space()
                return .handled
            }
            if press.modifiers.contains(.control),
               let letter = ControlKey.letter(press.characters) {
                switch letter {
                case "e":
                    coordinator.toggleTextSubjectEdit()
                    return .handled
                case "j":
                    if isPreviewing { previewDriver.scroll(by: 1) } else { coordinator.moveDown() }
                    return .handled
                case "k":
                    if isPreviewing { previewDriver.scroll(by: -1) } else { coordinator.moveUp() }
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
    /// **No spacing, because the gap is each Card's own.** A Card's cell carries
    /// `Style.cardInset` of padding outside its glass, so two neighbours make
    /// the gutter between them and the row's arithmetic stays in one place.
    ///
    /// **Every cell is `PanelLayout.cardWidth` × `cardHeight`, definite.** A Card
    /// is flexible inside — its content fills the cell so it stays centred — and
    /// a flexible view in an `HStack` takes a share of whatever width the stack
    /// is offered *this frame*. The row's width is itself animating 212 → 424
    /// while a Card arrives, so without a definite cell each Card is squashed on
    /// the first frames of the Arrival and springs back out: the glass morphing
    /// out of its neighbour would be morphing out of a deforming source. A
    /// definite cell keeps every drawn surface 200 × 200 (212 less
    /// `Style.cardInset` twice) no matter what width the row is passing through.
    ///
    /// `.identity` on the Cards that come and go is not an oversight. What
    /// animates when a Phase is added is the *glass* — the row widening, and the
    /// new Card's surface growing out of its neighbour's — while the Card's
    /// **content** hard-cuts into place. Content that scales or fades in delays
    /// information the user has already asked for, which is the trap
    /// `docs/adr/0003` exists to prevent.
    private var cardRow: some View {
        HStack(spacing: 0) {
            SubjectCardView(coordinator: coordinator, glassNamespace: glassNamespace)
                .frame(width: PanelLayout.cardWidth, height: PanelLayout.cardHeight)

            if coordinator.cardCount >= 2 {
                ActionCardView(coordinator: coordinator, glassNamespace: glassNamespace)
                    .frame(width: PanelLayout.cardWidth, height: PanelLayout.cardHeight)
                    .transition(.identity)
            }

            if coordinator.cardCount >= 3 {
                TargetCardView(coordinator: coordinator, glassNamespace: glassNamespace)
                    .frame(width: PanelLayout.cardWidth, height: PanelLayout.cardHeight)
                    .transition(.identity)
            }
        }
    }
}
