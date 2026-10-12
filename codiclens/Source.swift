import Foundation

/// A place Subjects come from — see `CONTEXT.md`, **Source**. Four are built
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

/// How much of a Source has been read. For a folder Source both numbers come
/// from the File Index; for the others they are the size of what the app
/// already holds in memory, which is read whole, so `indexed == total`.
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
    static let shared = SourceStore()

    /// The folder Sources a new install starts with.
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

    /// - Parameter defaults: where the Sources live. Tests pass their own.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let folders = defaults.stringArray(forKey: Self.foldersKey) ?? Self.defaultFolders
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

    var folders: [Source] {
        sources.filter { $0.folderPath != nil }
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
        let path = url.standardizedFileURL.path
        guard !folders.contains(where: { $0.folderPath == path }) else { return false }
        sources.append(Source(kind: .folder(path: path), isEnabled: true))
        save()
        onFoldersChange?()
        return true
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
