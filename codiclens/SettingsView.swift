import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Sources", systemImage: "folder") {
                SourcesSettingsView()
            }
        }
        .frame(width: 460)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage("appTheme") private var selectedTheme: String = AppTheme.system.rawValue
    @AppStorage(Motion.animationsEnabledKey) private var animationsEnabled: Bool = true
    @State private var isShowingAcknowledgements = false

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $selectedTheme) {
                    ForEach(AppTheme.allCases, id: \.rawValue) { theme in
                        Text(theme.label).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Animations", isOn: $animationsEnabled)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Codiclens animates only the panel appearing, the panel dismissing, and a panel changing size. Turning this off replaces all three with a cross-fade. macOS's own Reduce Motion setting does the same thing on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
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
                Button("Acknowledgements…") { isShowingAcknowledgements = true }
                Button("Quit Codiclens") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingAcknowledgements) { acknowledgementsSheet }
    }

    // MARK: - Emoji hotkey

    /// ⌃⌘Space is registered unconditionally, but macOS ships owning it. The
    /// footer says so, because a shortcut that silently does nothing is worse
    /// than one the user knows they have to free up. No path is given for
    /// freeing it: System Settings has no row for Emoji & Symbols — see
    /// `docs/adr/0006-private-symbolic-hotkey-api.md`.
    private var emojiHotKeyExplanation: some View {
        Text("⌃⌘Space opens the emoji picker, and ⌘Space opens Codiclens. If macOS's own Emoji & Symbols window appears instead, the system still holds ⌃⌘Space and is consuming the keystroke before Codiclens sees it.")
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

    /// Third-party material the app ships, each with the licence it came
    /// under. Both files are bundled resources.
    private var acknowledgements: [(title: String, text: String)] {
        [
            ("Emoji Data", EmojiIndex.licenseText() ?? "The bundled emoji data is missing its licence file."),
            ("DigUp", Self.bundledText("digup-license") ?? "The DigUp licence file is missing from the app.")
        ]
    }

    private static func bundledText(_ resource: String) -> String? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private var acknowledgementsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Acknowledgements").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(acknowledgements, id: \.title) { acknowledgement in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(acknowledgement.title).font(.subheadline.weight(.semibold))
                            Text(acknowledgement.text)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
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
