import Foundation

/// What the Sources page in Settings lists, and what its controls do. One
/// switch and two counts per Source; no priority, because ranking is the
/// search's business (`SourceStore`). Below the folders, what the File Index
/// skips inside them: a switch per group and the user's own patterns.
///
/// The counts and the reading state are closures so that the page reads them
/// from the live indexes and a test can hand in its own. Called from a view's
/// `body`, they are tracked like any other `@Observable` read.
struct SourcesPage {
    let store: SourceStore
    /// How much of a Source has been read, or nil before anything has been
    /// counted, such as a folder added a moment ago.
    let counts: (Source) -> SourceCounts?
    /// Whether a Source is being read right now.
    let isReading: (Source) -> Bool

    /// The page as the app shows it.
    static var live: SourcesPage {
        SourcesPage(
            store: .shared,
            counts: { source in
                switch source.kind {
                case .applications:
                    guard AppIndex.shared.hasPopulated else { return nil }
                    return .whole(AppIndex.shared.apps.count)
                case .clipboardHistory:
                    return .whole(ClipboardHistory.shared.items.count)
                case .emoji:
                    return .whole(EmojiIndex.shared.all.count)
                case .builtIns:
                    return .whole(BuiltInType.allCases.count)
                case .folder(let path):
                    return FileIndex.shared.counts[path]
                }
            },
            isReading: { source in
                switch source.kind {
                case .applications: AppIndex.shared.isRefreshing
                case .folder(let path): FileIndex.shared.readingFolders.contains(path)
                case .clipboardHistory, .emoji, .builtIns: false
                }
            }
        )
    }

    /// Applications, Clipboard History, Emoji and the Built-ins, always
    /// listed and never removable.
    var builtInRows: [SourceRow] {
        store.sources.filter { $0.folderPath == nil }.map(row)
    }

    /// The folder Sources, in the order they were added.
    var folderRows: [SourceRow] {
        store.folders.map(row)
    }

    func setEnabled(_ isEnabled: Bool, for row: SourceRow) {
        store.setEnabled(isEnabled, for: row.id)
    }

    /// Adds each folder that is not already a Source.
    func addFolders(_ urls: [URL]) {
        for url in urls { store.addFolder(url) }
    }

    /// Removes a folder Source. What the File Index read from it goes; the
    /// files themselves are not touched.
    func remove(_ row: SourceRow) {
        guard let path = row.source.folderPath else { return }
        store.removeFolder(path)
    }

    // MARK: - Skipping

    /// One switch per group, in the order they are listed.
    var skipRows: [SkipRow] {
        FileIndexRules.SkipGroup.allCases.map { group in
            SkipRow(group: group, isSkipped: store.fileIndexRules.skips(group))
        }
    }

    func setSkipped(_ isSkipped: Bool, for row: SkipRow) {
        store.setSkipped(isSkipped, row.group)
    }

    /// The user's own patterns, in the order they were added.
    var skipPatterns: [SkipPattern] {
        store.fileIndexRules.patterns
    }

    /// Whether the "+" is worth pressing for `text`.
    func canAddSkipPattern(_ text: String) -> Bool {
        store.canAddSkipPattern(text)
    }

    @discardableResult
    func addSkipPattern(_ text: String) -> Bool {
        store.addSkipPattern(text)
    }

    func removeSkipPattern(_ pattern: SkipPattern) {
        store.removeSkipPattern(pattern)
    }

    private func row(_ source: Source) -> SourceRow {
        SourceRow(source: source, counts: counts(source), isReading: isReading(source))
    }
}

/// One line of the Sources page.
struct SourceRow: Identifiable, Equatable {
    let source: Source
    let counts: SourceCounts?
    let isReading: Bool

    var id: Source.ID { source.id }
    var name: String { source.name }
    var isEnabled: Bool { source.isEnabled }
    var isRemovable: Bool { source.folderPath != nil }

    /// Where a folder Source is, with the home folder as `~`. Two folders can
    /// share a name; they cannot share this.
    var location: String? {
        source.folderPath.map { ($0 as NSString).abbreviatingWithTildeInPath }
    }
}

/// One skip switch: on means the File Index leaves the group out.
struct SkipRow: Identifiable, Equatable {
    let group: FileIndexRules.SkipGroup
    let isSkipped: Bool

    var id: FileIndexRules.SkipGroup { group }

    var title: String {
        switch group {
        case .caches: "Caches"
        case .dependencies: "node_modules and build output"
        case .bundles: "App bundles and packages"
        case .hidden: "Hidden files and folders"
        case .repos: "Repos"
        case .worktrees: "Git worktrees"
        case .envFiles: ".env files"
        case .keys: "Keys and certificates"
        }
    }

    /// One plain line under the title.
    var detail: String {
        switch group {
        case .caches: "~/Library, Caches, DerivedData, .build and Finder's .DS_Store files"
        case .dependencies: "Installed packages, generated code like paraglide and coverage, and build output inside a project"
        case .bundles: "Apps and frameworks, what is inside packages, and .git folders"
        case .hidden: "Names that start with a dot"
        case .repos: "Folders with a .git inside, unless you added the folder above"
        case .worktrees: "Extra checkouts made with git worktree, unless you added the folder above"
        case .envFiles: ".env, .env.local and other environment files"
        case .keys: "Private keys, certificates and keychains, like id_rsa and .pem"
        }
    }
}

extension SourceCounts {
    /// A Source the app holds whole in memory: everything in it is indexed.
    static func whole(_ count: Int) -> SourceCounts {
        SourceCounts(indexed: count, total: count)
    }
}
