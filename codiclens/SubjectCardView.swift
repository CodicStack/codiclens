import SwiftUI

struct SubjectCardView: View {
    @Bindable var coordinator: CommandCoordinator
    @FocusState private var isEditorFocused: Bool

    private var isFocused: Bool {
        switch coordinator.phase {
        case .searchingSubject, .browsingClipboard, .browsingEmoji: true
        default: false
        }
    }

    /// Whether the Card is holding text rather than naming something, which is
    /// the one case that needs a near-solid ground to stay readable.
    private var isWriting: Bool {
        isClipboardText || isTextMode
    }

    private var subject: Subject? {
        let vm = coordinator.subjectVM
        guard vm.selectedIndex < vm.results.count else { return nil }
        return vm.results[vm.selectedIndex]
    }

    private var isTextMode: Bool {
        if let subject, case .text = subject.kind { return true }
        return false
    }

    private var isClipboardMode: Bool {
        coordinator.isClipboardBrowsing
            || (coordinator.phase == .pickingAction && coordinator.selectedClipboardItem != nil)
    }

    private var isClipboardText: Bool {
        if isClipboardMode, let item = clipboardItem, !item.isImage { return true }
        if coordinator.isEditingClipboardItem { return true }
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
            } else if coordinator.isEditingClipboardItem {
                clipboardEditor
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

    /// Shown for a clipboard entry that is text: how long the thing being
    /// previewed actually is.
    private var characterCount: Int? {
        guard isClipboardMode, !coordinator.isEditingClipboardItem,
              let item = clipboardItem, !item.isImage else { return nil }
        return item.content.count
    }

    /// The key that acts on this Card. Only while the Card has the keyboard, and
    /// only when there is something for the key to act on.
    private var keyHint: String? {
        guard isFocused else { return nil }
        if coordinator.isEditingClipboardItem { return "⌘E" }
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

                Text(emoji.name)
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

    private var clipboardEditor: some View {
        TextEditor(text: $coordinator.clipboardEditText)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .focused($isEditorFocused)
            .padding(16)
            .onKeyPress { press in
                if press.key == .tab && press.modifiers.isEmpty {
                    coordinator.saveClipboardEditAndAdvance()
                    return .handled
                }
                if (press.modifiers.contains(.command) && press.characters == "e")
                    || (press.modifiers.contains(.control) && (press.characters == "e" || press.characters == "\u{05}")) {
                    coordinator.toggleClipboardEdit()
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

            Text(highlightedName(subject.displayName, query: coordinator.subjectVM.searchText))
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

            Text(coordinator.subjectVM.searchText.isEmpty ? "Type..." : "No match")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.quaternary)
        }
    }
}
