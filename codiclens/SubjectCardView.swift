import SwiftUI

struct SubjectCardView: View {
    @Bindable var coordinator: CommandCoordinator
    @FocusState private var isEditorFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var isFocused: Bool {
        switch coordinator.phase {
        case .searchingSubject, .browsingClipboard: true
        default: false
        }
    }

    private var subject: Subject? {
        let vm = coordinator.subjectVM
        guard vm.selectedIndex < vm.results.count else { return nil }
        return vm.results[vm.selectedIndex]
    }

    private var isTextMode: Bool {
        if let subject, case .text = subject.kind { return true }
        if coordinator.subjectVM.searchText.contains(" ") { return true }
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
            } else if isTextMode {
                textAreaContent
            } else if let subject {
                subjectContent(subject)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                if isClipboardText || isTextMode {
                    RoundedRectangle(cornerRadius: 32)
                        .fill(colorScheme == .dark ? Color(white: 0.15) : Color.white)
                } else {
                    RoundedRectangle(cornerRadius: 32)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 32)
                        .fill(colorScheme == .dark
                            ? Color.black.opacity(0.92)
                            : Color.white.opacity(0.7))
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .opacity(isFocused || isClipboardText || isTextMode || coordinator.phase == .showingResult("") ? 1 : 0.7)
        .padding(4)
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
                .overlay(alignment: .bottomTrailing) {
                    Text("\(item.content.count) chars")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(colorScheme == .dark
                            ? Color.black.opacity(0.92)
                            : Color.white.opacity(0.92))
                        .clipShape(Capsule())
                        .padding(12)
                }
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
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isEditorFocused = true
                }
            }
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
                .frame(width: 96, height: 96)

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
