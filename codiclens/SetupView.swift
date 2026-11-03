import AppKit
import Combine
import SwiftUI

/// Setup's window: one row per `SetupRow`, in `Setup`'s order, and Done,
/// which always closes it. No step is required and nothing here says so.
struct SetupView: View {
    let setup: Setup
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ShortcutsRowView(row: setup.shortcuts)
                } header: {
                    Text("Shortcuts")
                }
                Section {
                    PasteRowView(row: setup.paste)
                } header: {
                    Text("Paste into apps")
                }
                Section {
                    LoginRowView(row: setup.login)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Text("You can change all of this later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Rows

private struct ShortcutsRowView: View {
    @Bindable var row: ShortcutsRow

    var body: some View {
        if row.showsSpotlightFallback {
            SpotlightFallbackNote()
        } else {
            Toggle("Use ⌘Space for Codiclens (replaces Spotlight)", isOn: $row.takesSpotlight)
        }
        if row.canTakeEmoji {
            Toggle("Open emoji with ⌃⌘Space (replaces Emoji & Symbols)", isOn: $row.takesEmoji)
            if row.emojiFailed { EmojiFallbackNote() }
        } else {
            EmojiFallbackNote()
        }
    }
}

private struct PasteRowView: View {
    let row: PasteRow
    /// macOS says nothing when the grant changes, so the tick asks again
    /// while the window is up, and whenever the app comes back to the front
    /// from System Settings.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        LabeledContent {
            if row.isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                Button("Grant") { row.grant() }
            }
        } label: {
            Text("Accessibility")
            Text("Lets Codiclens paste into the app you were using. Skip it and macOS asks the first time you paste.")
        }
        .onReceive(tick) { _ in row.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            row.refresh()
        }
    }
}

private struct LoginRowView: View {
    @Bindable var row: LoginRow

    var body: some View {
        Toggle("Open at login", isOn: $row.opensAtLogin)
    }
}

// MARK: - When macOS keeps a shortcut

/// Shown in place of the ⌘Space checkbox, in Setup and in Settings, when
/// macOS would not let go of it (ADR 0016).
struct SpotlightFallbackNote: View {
    /// System Settings → Keyboard, where the Keyboard Shortcuts… button is.
    static let keyboardSettings = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("macOS kept ⌘Space for Spotlight. To use it for Codiclens, open Keyboard, click Keyboard Shortcuts, choose Spotlight and turn off Show Spotlight search.")
                .fixedSize(horizontal: false, vertical: true)
            Link("Open Keyboard Settings", destination: Self.keyboardSettings)
        }
    }
}

/// Emoji & Symbols has no row in Keyboard Shortcuts (ADR 0006), so there is
/// nothing to point at.
struct EmojiFallbackNote: View {
    var body: some View {
        Text("macOS kept ⌃⌘Space for Emoji & Symbols.")
            .foregroundStyle(.secondary)
    }
}
