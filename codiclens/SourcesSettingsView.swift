import SwiftUI
import UniformTypeIdentifiers

/// The Sources page in Settings: every Source with its switch and how much of
/// it has been read, then what is skipped inside the folders, then search by
/// meaning. `SourcesPage` builds the rows; this only draws them.
struct SourcesSettingsView: View {
    var page: SourcesPage = .live
    @State private var isAddingFolders = false
    @State private var newPattern = ""
    @State private var isConfirmingRemove = false

    var body: some View {
        Form {
            Section {
                ForEach(page.builtInRows) { row in
                    sourceRow(row)
                }
            } header: {
                Text("Built in")
            }

            Section {
                ForEach(page.folderRows) { row in
                    sourceRow(row)
                        .contextMenu {
                            Button("Remove") { page.remove(row) }
                        }
                }
                Button("Add Folder…") { isAddingFolders = true }
            } header: {
                Text("Folders")
            } footer: {
                Text("A folder added here is read even if a skip below would leave it out. Removing a folder forgets what was read from it; the files stay where they are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(page.skipRows) { row in
                    Toggle(isOn: Binding(
                        get: { row.isSkipped },
                        set: { page.setSkipped($0, for: row) }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title)
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                ForEach(page.skipPatterns, id: \.self) { pattern in
                    HStack(spacing: 8) {
                        Text(pattern.text)
                            .font(.body.monospaced())
                        Spacer(minLength: 12)
                        Button {
                            page.removeSkipPattern(pattern)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(pattern.text)")
                        .accessibilityLabel("Remove \(pattern.text)")
                    }
                }
                HStack(spacing: 8) {
                    TextField("Pattern", text: $newPattern, prompt: Text("*.log, Archive/, Work/**/old"))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .onSubmit(addPattern)
                    Button(action: addPattern) {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!page.canAddSkipPattern(newPattern))
                    .help("Skip this pattern")
                    .accessibilityLabel("Add pattern")
                }
            } header: {
                Text("Skip")
            } footer: {
                Text("*.log matches a name anywhere, Archive/ only folders, and Work/**/old a path from the top of the folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let meaning = page.meaningRow {
                meaningSection(meaning)
            }
        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: $isAddingFolders,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { page.addFolders(urls) }
        }
    }

    private func meaningSection(_ row: MeaningRow) -> some View {
        Section {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { row.isOn }, set: { page.setMeaningEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Search by meaning")
                        Text(row.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!row.isAvailable)

                Spacer(minLength: 12)

                // The ring says work is going on, never how much: the line
                // under the switch says that.
                if row.isWorking {
                    LoadingRing()
                }
                if let counts = row.counts {
                    countsLabel(counts)
                        .help(row.vectors.map { "\($0.formatted()) passages, pictures and moments searchable" } ?? "")
                }
            }
            if row.canRemove {
                Button("Remove Model and Vectors…", role: .destructive) { isConfirmingRemove = true }
                    .confirmationDialog(
                        "Remove the model and what it learned?",
                        isPresented: $isConfirmingRemove
                    ) {
                        Button("Remove", role: .destructive) { page.removeMeaning() }
                    } message: {
                        Text("Search by meaning turns off. The 865 MB model and the vectors made from your files are deleted; your files are not touched.")
                    }
            }
        } header: {
            Text("Search by meaning")
        }
    }

    private func addPattern() {
        if page.addSkipPattern(newPattern) { newPattern = "" }
    }

    private func sourceRow(_ row: SourceRow) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { row.isEnabled },
                set: { page.setEnabled($0, for: row) }
            )) {
                HStack(spacing: 8) {
                    icon(for: row.source)
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                        if let location = row.location {
                            Text(location)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: 12)

            // The ring never stands alone: "Reading" says what it is for,
            // and is all that is left of the pair under Reduce Motion.
            if row.isReading {
                LoadingRing()
                Text("Reading")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if row.hasNoAccess {
                Text("No access")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Link("Open Privacy & Security", destination: FolderAccess.privacySettings)
                    .font(.callout)
                    .help("Turn Codiclens on for this folder in Files and Folders")
            } else if let counts = row.counts {
                countsLabel(counts)
            }
            if row.isRemovable {
                Button {
                    page.remove(row)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove \(row.name)")
                .accessibilityLabel("Remove \(row.name)")
            }
        }
    }

    /// Indexed in green, total in grey, as Tuna draws them. For a folder,
    /// indexed is the files whose contents are read; it catches up with the
    /// total as the contents backfill runs.
    private func countsLabel(_ counts: SourceCounts) -> some View {
        HStack(spacing: 6) {
            Text(counts.indexed, format: .number)
                .foregroundStyle(.green)
                .help("Indexed")
            Text(counts.total, format: .number)
                .foregroundStyle(.secondary)
                .help("Total")
        }
        .font(.callout.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(counts.indexed) of \(counts.total) indexed")
    }

    @ViewBuilder
    private func icon(for source: Source) -> some View {
        switch source.kind {
        case .applications:
            Image(nsImage: NSWorkspace.shared.icon(forFile: "/Applications")).resizable()
        case .folder(let path):
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
        case .clipboardHistory:
            Image(systemName: "clipboard").foregroundStyle(.secondary)
        case .emoji:
            Image(systemName: "face.smiling").foregroundStyle(.secondary)
        case .builtIns:
            Image(systemName: "gear").foregroundStyle(.secondary)
        }
    }
}
