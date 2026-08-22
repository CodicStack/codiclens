import SwiftUI

struct SubjectCardView: View {
    @Bindable var coordinator: CommandCoordinator
    @FocusState private var isEditorFocused: Bool

    /// Whether the Query is still the question being asked.
    ///
    /// This is the distinction the Card turns on, and it decides two separate
    /// things: whether the Card *follows the selection* or *names the chosen
    /// Subject*, and whether the displayed name is marked up against the Query
    /// at all. The Phases where the Query is still live happen to be exactly the
    /// Phases where this Card holds the keyboard, which is why `isFocused` is
    /// the same set — if the two ever come apart, they come apart here.
    private var isQueryPhase: Bool {
        switch coordinator.phase {
        case .searchingSubject, .browsingClipboard, .browsingEmoji: true
        default: false
        }
    }

    private var isFocused: Bool { isQueryPhase }

    /// Whether the Card is holding text rather than naming something, which is
    /// the one case that needs a near-solid ground to stay readable.
    private var isWriting: Bool {
        isClipboardText || isTextMode || retargetedText != nil
    }

    /// What the Card is about — and it is two different things by Phase.
    ///
    /// While the Query is still the question, the Card previews the highlighted
    /// Result, so it reads `subjectVM.results[selectedIndex]` and moves as the
    /// selection moves. Once a Subject has been **chosen**, the Card is about
    /// that Subject and the Query's matches are no longer what it is showing.
    ///
    /// Those are not the same value, and reading only the first is how "Use as
    /// Subject" left Finder sitting on the Card after promoting a file out of
    /// it: the promotion writes `selectedSubject`, while `subjectVM.results`
    /// still holds whatever the Query matched. `retargetedText` already solved
    /// exactly this for OCR Text and a transform's output — but only for a
    /// `.text` Subject, and a promoted file or app is not one, so it fell
    /// straight through to the stale Result.
    private var subject: Subject? {
        if !isQueryPhase, let chosen = coordinator.selectedSubject { return chosen }
        let vm = coordinator.subjectVM
        guard vm.selectedIndex < vm.results.count else { return nil }
        return vm.results[vm.selectedIndex]
    }

    private var isTextMode: Bool {
        if let subject, case .text = subject.kind { return true }
        return false
    }

    /// The text of a Subject that has *replaced* what the Query matched — OCR
    /// Text, or a transform's output.
    ///
    /// A narrower case of what `subject` now does generally: it exists because a
    /// text Subject is *previewed* rather than named, so the Card needs the
    /// string and not the Subject. It stays separate for that reason alone, and
    /// no longer for the reason it was written — `subject` reads
    /// `selectedSubject` outside a Query Phase now, for every kind and not just
    /// text.
    private var retargetedText: String? {
        guard !isQueryPhase else { return nil }
        guard case .text(let rawText)? = coordinator.selectedSubject?.kind else { return nil }
        return rawText
    }

    private var isClipboardMode: Bool {
        coordinator.isClipboardBrowsing
            || (coordinator.phase == .pickingAction && coordinator.selectedClipboardItem != nil)
    }

    private var isClipboardText: Bool {
        if isClipboardMode, let item = clipboardItem, !item.isImage { return true }
        if coordinator.isEditingTextSubject { return true }
        return false
    }

    private var clipboardItem: ClipboardItem? {
        if let item = coordinator.selectedClipboardItem,
           (coordinator.phase == .pickingAction || coordinator.phase == .browsingClipboard) {
            return item
        }
        return coordinator.currentClipboardItem
    }

    var body: some View {
        Group {
            if case .showingResult(let result) = coordinator.phase {
                resultPreview(result)
            } else if coordinator.isEditingTextSubject {
                textSubjectEditor
            } else if let retargetedText {
                textPreview(retargetedText)
            } else if isClipboardMode {
                clipboardPreview
            } else if coordinator.isEmojiBrowsing {
                emojiContent
            } else if isTextMode {
                textAreaContent
            } else if let subject {
                subjectContent(subject)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) { corner }
        .cardSurface(focused: isFocused, writing: isWriting)
        .cardBeam(focused: isFocused)
        .padding(Style.cardInset)
    }

    /// The Card's bottom-trailing corner: what it holds, and what acts on it.
    private var corner: some View {
        HStack(spacing: 4) {
            if let characterCount {
                Text("\(characterCount) chars")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .chipSurface()
            }
            if let keyHint {
                KeyHintChip(keys: keyHint)
            }
        }
        .padding(Style.padding)
    }

    /// Shown wherever the Card is previewing text rather than naming
    /// something: how long the thing being previewed actually is. A page of OCR
    /// Text needs that as much as a clipboard entry does.
    private var characterCount: Int? {
        guard !coordinator.isEditingTextSubject else { return nil }
        if let retargetedText { return retargetedText.count }
        guard isClipboardMode, let item = clipboardItem, !item.isImage else { return nil }
        return item.content.count
    }

    /// The key that acts on this Card. Only while the Card has the keyboard, and
    /// only when there is something for the key to act on.
    private var keyHint: String? {
        // Editing is the one case where the Card holds the keyboard without
        // being the focused Card of the Phase — the editor has it, wherever the
        // Phase happens to be — so this is asked before `isFocused`.
        if coordinator.isEditingTextSubject { return "⌘E" }
        guard isFocused else { return nil }
        if coordinator.isEmojiBrowsing { return coordinator.currentEmoji == nil ? nil : "⏎" }
        if isClipboardMode { return clipboardItem == nil ? nil : "⏎" }
        return subject == nil ? nil : "⏎"
    }

    /// The Card in Emoji Mode: the glyph where an app icon would be, its CLDR
    /// name where an app name would be, so the Card reads the same either way.
    ///
    /// The glyph goes through `EmojiRenderer` rather than a large `Text`.
    /// Apple Color Emoji is a bitmap font, so an off-strike point size resamples
    /// and reads soft. The renderer picks the nearest strike for the icon slot
    /// the other Cards use, which keeps the Card's metrics identical whether it
    /// holds an app icon or a glyph.
    @ViewBuilder
    private var emojiContent: some View {
        if let emoji = coordinator.currentEmoji {
            VStack(spacing: 10) {
                Image(nsImage: EmojiRenderer.image(for: emoji.string, box: Style.cardIcon))
                    .frame(width: Style.cardIcon, height: Style.cardIcon)

                // Marked up like an app name, and for the same reason: the Card
                // shows what the Query matched, so it should show *where*. An
                // Emoji found by a keyword has nothing to mark up in its CLDR
                // name, and `highlightedName` leaves that plain rather than
                // underlining the characters that happen to line up.
                Text(highlightedName(emoji.name, query: coordinator.emojiVM.searchText))
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, Style.padding)
        } else {
            placeholder
        }
    }

    private func resultPreview(_ result: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.green)

            Text(result)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(3)
                .foregroundStyle(.primary)

            Text("⏎ to copy")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var clipboardPreview: some View {
        if let item = clipboardItem {
            if item.isImage,
               let fileName = item.imageFileName,
               let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
               let nsImage = NSImage(contentsOf: appSupport.appendingPathComponent("codiclens/images/\(fileName)")) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else {
                ScrollView {
                    Text(item.content)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "clipboard")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.quaternary)
                Text("No items")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.quaternary)
            }
        }
    }

    /// The editor for a text Subject, wherever it is being edited from — the
    /// Clipboard browser, OCR Text, a transform's output.
    private var textSubjectEditor: some View {
        TextEditor(text: $coordinator.textSubjectEditText)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .focused($isEditorFocused)
            .padding(16)
            .onKeyPress { press in
                if press.key == .tab && press.modifiers.isEmpty {
                    coordinator.saveTextSubjectEditAndAdvance()
                    return .handled
                }
                if (press.modifiers.contains(.command) && press.characters == "e")
                    || (press.modifiers.contains(.control) && (press.characters == "e" || press.characters == "\u{05}")) {
                    coordinator.toggleTextSubjectEdit()
                    return .handled
                }
                if press.key == .escape {
                    _ = coordinator.handleEscape()
                    isEditorFocused = false
                    return .handled
                }
                return .ignored
            }
            // Focus has to be taken *after* the update that inserted the editor
            // has committed — assigning it during that update is dropped,
            // because the text view it would move focus to does not exist yet.
            // `task` is the event that says "committed": it starts on the main
            // actor once the view is in the hierarchy. It replaces a fixed
            // 0.1-second delay that was guessing at the same moment.
            .task { isEditorFocused = true }
    }

    /// A block of text the Card is holding, scrollable because OCR Text can be
    /// a page of it.
    private func textPreview(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private var textAreaContent: some View {
        VStack {
            Text(coordinator.subjectVM.searchText)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .lineLimit(nil)
        }
        .padding(20)
    }

    private func subjectContent(_ subject: Subject) -> some View {
        VStack(spacing: 10) {
            Image(nsImage: subject.icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: Style.cardIcon, height: Style.cardIcon)

            // Marked up only where the name is what the Query matched. A
            // promoted or chosen Subject is not, and underlining the
            // characters of `find` that happen to line up in a file it was
            // found through would be marking a match that never happened.
            Text(
                highlightedName(
                    subject.displayName,
                    query: isQueryPhase ? coordinator.subjectVM.searchText : ""
                )
            )
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

            Text(placeholderMessage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.quaternary)
        }
    }

    /// What an empty Card says, and it must not claim more than it knows.
    ///
    /// "No match" is a finding, and the Card is only entitled to it once the app
    /// Index has answered — before that a Query has not been looked up, so the
    /// Card is still waiting rather than reporting.
    private var placeholderMessage: String {
        if coordinator.subjectVM.searchText.isEmpty { return "Type..." }
        return coordinator.subjectVM.isIndexReady ? "No match" : "Searching…"
    }
}
