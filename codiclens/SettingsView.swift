import SwiftUI

struct SettingsView: View {
    let setup: SetupController
    let updater: any Updater

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView(setup: setup, updater: updater)
            }
            Tab("Sources", systemImage: "folder") {
                SourcesSettingsView()
            }
        }
        .frame(width: 460)
    }
}

private struct GeneralSettingsView: View {
    let setup: SetupController
    let updater: any Updater
    @AppStorage("appTheme") private var selectedTheme: String = AppTheme.system.rawValue
    @AppStorage(Motion.animationsEnabledKey) private var animationsEnabled: Bool = true
    @State private var isShowingAcknowledgements = false

    var body: some View {
        Form {
            Section {
                shortcutRows
                Toggle("Open at login", isOn: Binding(
                    get: { setup.openAtLogin.isOn },
                    set: { setup.openAtLogin.setOn($0) }
                ))
            } header: {
                Text("Startup and shortcuts")
            } footer: {
                Text("Quitting Codiclens gives ⌘Space and ⌃⌘Space back to macOS until it opens again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

            updatesSection

            Section {
                Button("Show Setup…") { setup.show() }
                Button("Acknowledgements…") { isShowingAcknowledgements = true }
                Button("Quit Codiclens") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingAcknowledgements) {
            AcknowledgementsView { isShowingAcknowledgements = false }
        }
        .onAppear { setup.openAtLogin.refresh() }
    }

    // MARK: - Shortcuts

    /// The same choices as Setup's Shortcuts row, put into effect at once:
    /// off hands the shortcut back to macOS (ADR 0016). Where macOS kept
    /// one, the row says so in Setup's words.
    @ViewBuilder
    private var shortcutRows: some View {
        let takeover = setup.takeover
        if takeover.isAvailable {
            Toggle(SystemShortcut.spotlight.choiceTitle, isOn: binding(for: .spotlight))
            if takeover.isOn(.spotlight), takeover.hasFailed(.spotlight) { SpotlightFallbackNote() }
            Toggle(SystemShortcut.emoji.choiceTitle, isOn: binding(for: .emoji))
            if takeover.isOn(.emoji), takeover.hasFailed(.emoji) { EmojiFallbackNote() }
        } else {
            SpotlightFallbackNote()
            EmojiFallbackNote()
        }
    }

    private func binding(for shortcut: SystemShortcut) -> Binding<Bool> {
        Binding(
            get: { setup.takeover.isOn(shortcut) },
            set: { setup.takeover.setOn($0, for: shortcut) }
        )
    }

    // MARK: - Updates

    /// Reads and asks only the `Updater`, never Sparkle.
    private var updatesSection: some View {
        Section {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.checksAutomatically },
                set: { updater.checksAutomatically = $0 }
            ))
            Toggle("Download and install updates automatically", isOn: Binding(
                get: { updater.downloadsAutomatically },
                set: { updater.downloadsAutomatically = $0 }
            ))
            .disabled(!updater.canDownloadAutomatically)
            Button("Check Now") { updater.request(.check) }
                .disabled(!updater.canCheck)
            // Once a minute, so "last checked 2 minutes ago" keeps up.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(UpdateStatusLine.text(version: updater.version, lastCheck: updater.lastCheck, now: context.date))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Checks codiclens.codicstack.com once a day.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
}
