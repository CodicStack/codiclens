import SwiftUI

struct SettingsView: View {
    let setupController: SetupController
    let updater: any Updater

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView(setupController: setupController, updater: updater)
            }
            Tab("Sources", systemImage: "folder") {
                SourcesSettingsView()
            }
        }
        .frame(width: 460)
    }
}

private struct GeneralSettingsView: View {
    let setupController: SetupController
    let updater: any Updater
    @AppStorage("appTheme") private var selectedTheme: String = AppTheme.system.rawValue
    @AppStorage(Motion.animationsEnabledKey) private var animationsEnabled: Bool = true
    @State private var isShowingAcknowledgements = false
    /// A smaller limit waiting for the user to agree to lose the oldest items.
    @State private var pendingMaxItems: Int?
    /// What the Clipboard History takes on disk, shown beside Unlimited.
    @State private var clipboardDiskUsage: Int64?

    var body: some View {
        Form {
            Section {
                shortcutRows
                Toggle("Open at login", isOn: Binding(
                    get: { setupController.openAtLogin.isOn },
                    set: { setupController.openAtLogin.setOn($0) }
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

            clipboardHistorySection

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
                Button("Show Setup…") { setupController.show() }
                Button("Acknowledgements…") { isShowingAcknowledgements = true }
                Button("Quit Codiclens") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingAcknowledgements) {
            AcknowledgementsView { isShowingAcknowledgements = false }
        }
        .onAppear { setupController.openAtLogin.refresh() }
    }

    // MARK: - Shortcuts

    /// The same choices as Setup's Shortcuts row, put into effect at once:
    /// off hands the shortcut back to macOS (ADR 0016). Where macOS kept
    /// one, the row says so in Setup's words.
    @ViewBuilder
    private var shortcutRows: some View {
        let takeover = setupController.takeover
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
            get: { setupController.takeover.isOn(shortcut) },
            set: { setupController.takeover.setOn($0, for: shortcut) }
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

    // MARK: - Clipboard History

    /// Lowering the limit below what the history holds asks first: the
    /// oldest Clipboard Items go at once and cannot come back. Unlimited never
    /// asks, and warns what it costs instead.
    private var clipboardHistorySection: some View {
        let history = ClipboardHistory.shared
        return Section {
            Picker("Keep", selection: Binding(
                get: { history.maxItems },
                set: { newValue in
                    if let newValue, newValue < history.items.count {
                        pendingMaxItems = newValue
                    } else {
                        history.maxItems = newValue
                    }
                }
            )) {
                ForEach(ClipboardHistory.maxItemsChoices, id: \.self) { choice in
                    Text("\(choice.formatted()) items").tag(Int?.some(choice))
                }
                Text("Unlimited").tag(Int?.none)
            }
            .confirmationDialog(
                removalTitle,
                isPresented: Binding(
                    get: { pendingMaxItems != nil },
                    set: { if !$0 { pendingMaxItems = nil } }
                )
            ) {
                Button("Remove", role: .destructive) {
                    if let pendingMaxItems { history.maxItems = pendingMaxItems }
                    pendingMaxItems = nil
                }
            } message: {
                Text("They can't be brought back.")
            }

            if history.maxItems == nil {
                unlimitedWarning(history)
            }
        } header: {
            Text("Clipboard History")
        } footer: {
            Text("Text and images each count as one item. When the history is full, the oldest item makes room for the newest.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Measured when the row appears and again whenever the history changes,
    /// never on a redraw alone: it reads the disk.
    private func unlimitedWarning(_ history: ClipboardHistory) -> some View {
        Label {
            Text(unlimitedWarningText)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .task(id: HistoryVersion(count: history.items.count, newest: history.items.first?.id)) {
            clipboardDiskUsage = history.diskUsage()
        }
    }

    private var unlimitedWarningText: String {
        let warning = "Everything you copy stays on this Mac until you remove it, images too."
        guard let clipboardDiskUsage else { return warning }
        let size = ByteCountFormatter.string(fromByteCount: clipboardDiskUsage, countStyle: .file)
        return "\(warning) The history now takes \(size)."
    }

    /// What changes when a Clipboard Item is added or removed.
    private struct HistoryVersion: Equatable {
        let count: Int
        let newest: UUID?
    }

    private var removalTitle: String {
        guard let pendingMaxItems else { return "" }
        let count = ClipboardHistory.shared.items.count - pendingMaxItems
        return count == 1
            ? "Remove the oldest clipboard item?"
            : "Remove the \(count.formatted()) oldest clipboard items?"
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
