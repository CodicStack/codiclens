import SwiftUI

struct SettingsView: View {
    @AppStorage("appTheme") private var selectedTheme: String = AppTheme.system.rawValue
    @State private var isShowingAcknowledgements = false

    private var emojiHotKey: EmojiHotKeyController { .shared }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $selectedTheme) {
                    ForEach(AppTheme.allCases, id: \.rawValue) { theme in
                        Text(theme.label).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                emojiHotKeyRow
                skinToneRow
            } header: {
                Text("Emoji")
            } footer: {
                emojiHotKeyExplanation
            }

            Section {
                LabeledContent("App index") {
                    HStack(spacing: 8) {
                        if AppIndex.shared.isRefreshing {
                            ProgressView().controlSize(.small)
                        }
                        Button("Refresh Now") { AppIndex.shared.refresh() }
                            .disabled(AppIndex.shared.isRefreshing)
                    }
                }
            } header: {
                Text("Applications")
            } footer: {
                Text("Codiclens watches your application folders and picks up new apps on its own. Refresh only if something is missing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Emoji Data Acknowledgements…") { isShowingAcknowledgements = true }
                Button("Quit Codiclens") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .sheet(isPresented: $isShowingAcknowledgements) { acknowledgementsSheet }
    }

    // MARK: - Emoji hotkey

    /// The one control that is genuinely hard to explain, because macOS gives
    /// the user no way to release Ctrl+Cmd+Space themselves.
    private var emojiHotKeyRow: some View {
        Toggle(isOn: Binding(
            get: { emojiHotKey.isEnabled },
            set: { emojiHotKey.isEnabled = $0 }
        )) {
            Text("Use ⌃⌘Space for Codiclens")
            statusLabel(for: emojiHotKey.status)
        }
        .disabled(!emojiHotKey.isSupported)
    }

    @ViewBuilder
    private func statusLabel(for status: EmojiHotKeyController.Status) -> some View {
        switch status {
        case .codiclensOwns:
            Label("Codiclens opens the emoji picker.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .systemOwns:
            Text("macOS opens Emoji & Symbols.")
        case .blockedBySystemShortcut:
            Label("macOS is still holding this shortcut.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .unavailable:
            Label("This version of macOS does not allow the change.", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var emojiHotKeyExplanation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("macOS reserves ⌃⌘Space for its own Emoji & Symbols window, and offers no setting to release it. Turning this on switches that system shortcut off; turning it off gives the shortcut straight back.")
            if emojiHotKey.status == .blockedBySystemShortcut {
                Text("The change did not take. Try turning this off and on again — if it keeps failing, restart your Mac and try once more.")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Skin tone

    private var skinToneRow: some View {
        Picker("Default skin tone", selection: Binding(
            get: { EmojiPreferences.shared.defaultSkinTone },
            set: { EmojiPreferences.shared.defaultSkinTone = $0 }
        )) {
            ForEach(SkinTone.allCases) { tone in
                Text("\(preview(tone))  \(tone.name)").tag(tone)
            }
        }
    }

    /// A thumbs-up wearing the tone, so the list is chosen by eye rather than
    /// by reading "Medium-Dark".
    private func preview(_ tone: SkinTone) -> String {
        guard let modifier = tone.modifier else { return "👍" }
        return "👍" + String(Character(modifier))
    }

    // MARK: - Acknowledgements

    private var acknowledgementsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Emoji Data").font(.headline)
            ScrollView {
                Text(EmojiIndex.licenseText() ?? "The bundled emoji data is missing its licence file.")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { isShowingAcknowledgements = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }
}
