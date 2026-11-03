import Foundation

/// A place Subjects come from — see `GLOSSARY.md`, **Source**. Four are built
/// in and always listed; the rest are folders the user added, and only those
/// feed the File Index.
nonisolated struct Source: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case applications
        case clipboardHistory
        case emoji
        case builtIns
        case folder(path: String)
    }

    let kind: Kind
    var isEnabled: Bool

    var id: String {
        switch kind {
        case .applications: "applications"
        case .clipboardHistory: "clipboard-history"
        case .emoji: "emoji"
        case .builtIns: "built-ins"
        case .folder(let path): "folder:" + path
        }
    }

    var name: String {
        switch kind {
        case .applications: "Applications"
        case .clipboardHistory: "Clipboard History"
        case .emoji: "Emoji"
        case .builtIns: "Built-ins"
        case .folder(let path): FileManager.default.displayName(atPath: path)
        }
    }

    var folderPath: String? {
        if case .folder(let path) = kind { return path }
        return nil
    }
}

/// Whether macOS lets Codiclens read a folder. Downloads, Documents and
/// Desktop each need the user's yes, asked the first time anything lists
/// them; after a no, listing fails until it is turned on in Privacy &
/// Security → Files and Folders.
nonisolated enum FolderAccess {
    /// Files and Folders in Privacy & Security.
    static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    /// Listing `path` is refused. Asks macOS if it has not been asked, so it
    /// is only for a folder that is about to be read anyway. A folder that
    /// is not there is not refused.
    static func isDenied(_ path: String) -> Bool {
        guard let directory = opendir(path) else { return errno == EPERM || errno == EACCES }
        closedir(directory)
        return false
    }
}

/// How much of a Source has been read. For a folder Source both numbers come
/// from the File Index: `total` is every file and folder the crawl found,
/// `indexed` those whose contents are read too, or that have none to read.
/// For the others they are the size of what the app already holds in memory,
/// which is read whole, so `indexed == total`.
nonisolated struct SourceCounts: Equatable, Sendable {
    var indexed: Int
    var total: Int
}

/// The Sources and their switches, and what the File Index skips inside the
/// folder ones, kept in `UserDefaults` beside the app's other settings.
///
/// There is no priority between Sources: ranking is the search's business.
@Observable
final class SourceStore {
    static let shared = SourceStore(isFromBeforeSetup: isFromBeforeSetup())

    /// The folders Setup offers with Allow, and that an install from before
    /// Setup has always read.
    static let defaultFolders: [String] = {
        let home = NSHomeDirectory()
        return [home + "/Downloads", home + "/Documents", home + "/Desktop"]
    }()

    private static let foldersKey = "codiclens.sources.folders"
    private static let disabledKey = "codiclens.sources.disabled"
    private static let skippedKey = "codiclens.sources.skipped"
    private static let skipPatternsKey = "codiclens.sources.skipPatterns"

    private let defaults: UserDefaults

    /// The built-in Sources first, then the folders in the order they were
    /// added.
    private(set) var sources: [Source]

    /// The skip switches that are on, and the user's own patterns.
    private(set) var fileIndexRules: FileIndexRules

    /// Called after a folder Source is added, removed, or switched. The File
    /// Index listens here; the other Sources' switches are read where they
    /// are searched.
    var onFoldersChange: (() -> Void)?

    /// Called after a skip switch or pattern changes. The File Index listens.
    var onRulesChange: (() -> Void)?

    /// - Parameters:
    ///   - defaults: where the Sources live. Tests pass their own.
    ///   - isFromBeforeSetup: the install read the default folders before
    ///     Setup asked about them, and goes on reading them. Only looked at
    ///     while no folder Sources have been written down: otherwise a new
    ///     install has none until Allow in Setup.
    init(defaults: UserDefaults = .standard, isFromBeforeSetup: Bool = false) {
        self.defaults = defaults
        let folders = defaults.stringArray(forKey: Self.foldersKey) ?? (isFromBeforeSetup ? Self.defaultFolders : [])
        let disabled = Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
        let kinds: [Source.Kind] = [.applications, .clipboardHistory, .emoji, .builtIns]
            + folders.map { .folder(path: $0) }
        sources = kinds.map { kind in
            var source = Source(kind: kind, isEnabled: true)
            source.isEnabled = !disabled.contains(source.id)
            return source
        }
        fileIndexRules = FileIndexRules(
            skipped: defaults.stringArray(forKey: Self.skippedKey)
                .map { Set($0.compactMap(FileIndexRules.SkipGroup.init(rawValue:))) }
                ?? FileIndexRules.defaultSkipped,
            patterns: (defaults.stringArray(forKey: Self.skipPatternsKey) ?? []).compactMap(SkipPattern.init)
        )
    }

    /// Whether this Mac's install is older than Setup's question about
    /// folders: Setup was finished, or a File Index is on disk. Only asked
    /// while no folder Sources have been written down (`rememberFolders`).
    static func isFromBeforeSetup(
        defaults: UserDefaults = .standard,
        fileIndex: URL = FileIndex.defaultDatabaseURL
    ) -> Bool {
        defaults.object(forKey: Setup.finishedKey) as? Bool == true
            || FileManager.default.fileExists(atPath: fileIndex.path)
    }

    var folders: [Source] {
        sources.filter { $0.folderPath != nil }
    }

    /// Writes the folder Sources down as they are, before the File Index
    /// starts. A new install's empty list has to outlive the File Index its
    /// first launch creates, or the next launch would find it and take the
    /// install for one from before Setup.
    func rememberFolders() {
        save()
    }

    func isEnabled(_ kind: Source.Kind) -> Bool {
        sources.first { $0.kind == kind }?.isEnabled ?? false
    }

    func setEnabled(_ isEnabled: Bool, for id: Source.ID) {
        guard let index = sources.firstIndex(where: { $0.id == id }),
              sources[index].isEnabled != isEnabled else { return }
        sources[index].isEnabled = isEnabled
        save()
        if sources[index].folderPath != nil { onFoldersChange?() }
    }

    /// Adds a folder Source, enabled. Returns false if it is already one.
    @discardableResult
    func addFolder(_ url: URL) -> Bool {
        addFolders([url]) == 1
    }

    /// Adds each folder that is not already a Source, enabled, as one change
    /// for the File Index. Returns how many were added.
    @discardableResult
    func addFolders(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !folders.contains(where: { $0.folderPath == path }) else { continue }
            sources.append(Source(kind: .folder(path: path), isEnabled: true))
            added += 1
        }
        guard added > 0 else { return 0 }
        save()
        onFoldersChange?()
        return added
    }

    /// Removes a folder Source. Its rows leave the File Index.
    func removeFolder(_ path: String) {
        let count = sources.count
        sources.removeAll { $0.folderPath == path }
        guard sources.count != count else { return }
        save()
        onFoldersChange?()
    }

    // MARK: - Skipping

    func setSkipped(_ isSkipped: Bool, _ group: FileIndexRules.SkipGroup) {
        guard fileIndexRules.skips(group) != isSkipped else { return }
        if isSkipped { fileIndexRules.skipped.insert(group) } else { fileIndexRules.skipped.remove(group) }
        defaults.set(fileIndexRules.skipped.map(\.rawValue).sorted(), forKey: Self.skippedKey)
        onRulesChange?()
    }

    /// Whether `text` would be added: a pattern, and not one already listed.
    func canAddSkipPattern(_ text: String) -> Bool {
        guard let pattern = SkipPattern(text) else { return false }
        return !fileIndexRules.patterns.contains(pattern)
    }

    /// Adds a skip pattern. Returns false, and changes nothing, for a blank
    /// one or one already listed under any spelling.
    @discardableResult
    func addSkipPattern(_ text: String) -> Bool {
        guard canAddSkipPattern(text), let pattern = SkipPattern(text) else { return false }
        fileIndexRules.patterns.append(pattern)
        savePatterns()
        onRulesChange?()
        return true
    }

    func removeSkipPattern(_ pattern: SkipPattern) {
        let count = fileIndexRules.patterns.count
        fileIndexRules.patterns.removeAll { $0 == pattern }
        guard fileIndexRules.patterns.count != count else { return }
        savePatterns()
        onRulesChange?()
    }

    private func savePatterns() {
        defaults.set(fileIndexRules.patterns.map(\.text), forKey: Self.skipPatternsKey)
    }

    private func save() {
        defaults.set(folders.compactMap(\.folderPath), forKey: Self.foldersKey)
        defaults.set(sources.filter { !$0.isEnabled }.map(\.id), forKey: Self.disabledKey)
    }
}
