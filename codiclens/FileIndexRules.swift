// Skip lists adapted from DigUp's Rules.swift (https://github.com/ARahim3/DigUp), MIT licence — see docs/licenses/digup/LICENSE.
import Foundation

/// What the File Index leaves out, in one place. The crawl and the FSEvents
/// handler both ask here, so a file can never be skipped by one and indexed
/// by the other.
///
/// The user sets these on the Sources page: a switch per `SkipGroup` and a
/// list of `SkipPattern`s, kept by `SourceStore`. This is the plain value the
/// writer is handed, so it can cross into a helper process as it is.
///
/// The rules apply *inside* a Source, never to the Source itself: a folder the
/// user added is read even when it is a repo, a cache, or inside `~/Library`.
/// Choosing it is the user overriding the rule. Symbolic links and iCloud
/// files that are not downloaded are always left out: neither is a file here
/// to read.
nonisolated struct FileIndexRules: Equatable, Sendable {

    /// A kind of thing the user can have skipped, one switch each.
    enum SkipGroup: String, CaseIterable, Sendable {
        /// `~/Library`, caches, and Finder's `.DS_Store` litter.
        case caches
        /// Installed dependencies, generated code and reports, and build
        /// output beside a project marker.
        case dependencies
        /// Code bundles whole; the insides of packages and of `.git`.
        case bundles
        /// Any name starting with a dot.
        case hidden
        /// A folder with a `.git`, or a bare repo.
        case repos
        /// A linked worktree: a folder whose `.git` is a file pointing into
        /// another checkout's `.git/worktrees`. The same repo again, file for
        /// file, so it is out by default even while Repos is in.
        case worktrees
        /// What git ignores in a repo inside a Source (`GitIgnored`): its
        /// `.gitignore` files, `.git/info/exclude` and the user's global
        /// excludes. Not `.env` files or keys, which keep to their own
        /// switches even where a repo ignores them.
        case gitIgnored
        /// `.env` and its variants.
        case envFiles
        /// Private keys, certificates and keychains.
        case keys
    }

    /// What to do with one entry of a walk.
    enum Verdict: Equatable {
        /// A row, and for a folder, its contents too.
        case index
        /// A row, but nothing inside it: a document package such as `.pages`.
        case indexWithoutDescending
        /// No row, and nothing inside it.
        case skip
        /// No row, but what is inside is judged on its own: a folder git
        /// ignores, walked only for the `.env` files and keys in it.
        case descendWithoutIndexing
    }

    /// Everything the rules look at, read once per entry. `init(url:)` fills
    /// it from disk; tests build one by hand.
    struct Entry {
        var path: String
        var isDirectory: Bool
        var isPackage = false
        var isSymbolicLink = false
        /// A dataless iCloud placeholder: reading it would download it.
        var isNotDownloaded = false
        /// A folder with a `.git` entry — folder or file — directly in it.
        var containsGit = false
        /// A folder whose `.git` is a file naming a `worktrees` folder: a
        /// linked worktree, made by `git worktree add`. A submodule's `.git`
        /// is a file too, but it names `modules`, and is not one.
        var isLinkedWorktree = false
        /// A repo with no working tree: `HEAD`, `objects` and `refs` and no
        /// `.git`. What is in it is git's, as a `.git` folder's is.
        var isBareRepo = false
        /// A folder whose parent holds a project marker (`Package.swift`,
        /// `package.json`…), so a `build` or `dist` in it is build output.
        var isInsideProject = false
        /// Leading bytes, for the one rule that needs them: `.key` is
        /// Keynote's extension as well as a private key's.
        var startsWithZipMagic = false
        /// Ignored by git, as the indexer's `GitIgnored` says: nothing on
        /// disk in the entry's own place says so.
        var isGitIgnored = false

        var name: String { (path as NSString).lastPathComponent }
    }

    /// The groups switched on: skipped.
    var skipped: Set<SkipGroup>
    /// The user's own patterns, in the order they were added.
    var patterns: [SkipPattern]

    /// A new install's: tool output and internals out, everything the user
    /// might go looking for in.
    static let defaultSkipped: Set<SkipGroup> = [.caches, .dependencies, .bundles, .worktrees, .gitIgnored]

    static let defaults = FileIndexRules(skipped: defaultSkipped, patterns: [])

    func skips(_ group: SkipGroup) -> Bool {
        skipped.contains(group)
    }

    /// Whether a `.env` file or a key can be indexed: then a folder git
    /// ignores is still walked for them.
    var keepsSecretFiles: Bool {
        !skips(.envFiles) || !skips(.keys)
    }

    /// Whether these rules leave out everything `other` does, and perhaps
    /// more: nothing they would include was skipped before.
    func skipsAtLeast(_ other: FileIndexRules) -> Bool {
        skipped.isSuperset(of: other.skipped) && Set(patterns).isSuperset(of: other.patterns)
    }

    /// - Parameter root: the Source the entry is in.
    func verdict(for entry: Entry, root: String, home: String = NSHomeDirectory()) -> Verdict {
        if entry.path == root { return .index }
        if entry.isSymbolicLink || entry.isNotDownloaded { return .skip }

        let name = entry.name
        let relative = entry.path.hasPrefix(root + "/") ? String(entry.path.dropFirst(root.count + 1)) : name

        if entry.isDirectory {
            if skipsFolder(named: name) { return .skip }
            if skips(.caches), entry.path == home + "/Library" { return .skip }
            if skips(.repos), entry.containsGit || entry.isBareRepo { return .skip }
            if skips(.worktrees), entry.isLinkedWorktree { return .skip }
            if skips(.dependencies), entry.isInsideProject, Self.buildOutputFolderNames.contains(name) {
                return .skip
            }
        } else {
            if skips(.caches), Self.finderFileNames.contains(name) || name.hasPrefix("._") { return .skip }
            // A worktree's or a submodule's `.git` is a file: git's all the same.
            if skips(.bundles), name == ".git" { return .skip }
            if skips(.hidden), name.hasPrefix(".") { return .skip }
            if skips(.envFiles), Self.isEnvironmentFile(name) { return .skip }
            if skips(.keys), Self.isKey(entry) { return .skip }
        }
        if patterns.contains(where: { $0.matches(relativePath: relative, isDirectory: entry.isDirectory) }) {
            return .skip
        }

        if skips(.gitIgnored), entry.isGitIgnored {
            if entry.isDirectory {
                // Never a package or git's own: no `.env` lives in those.
                let walks = keepsSecretFiles && !entry.isPackage && !entry.isBareRepo
                return walks ? .descendWithoutIndexing : .skip
            }
            // `.env` files and keys keep to their own switches, above.
            if !Self.isEnvironmentFile(name), !Self.isKey(entry) { return .skip }
        }
        if skips(.bundles), entry.isPackage || entry.isBareRepo { return .indexWithoutDescending }
        return .index
    }

    /// The folder rules that need nothing but the name. A folder they skip
    /// takes everything inside it along, so the FSEvents handler can drop an
    /// event under one without looking at the disk.
    func skipsFolder(named name: String) -> Bool {
        if skips(.hidden), name.hasPrefix(".") { return true }
        if skips(.caches), Self.cacheFolderNames.contains(name) || name.hasSuffix(".noindex") { return true }
        if skips(.dependencies), Self.dependencyFolderNames.contains(name) || Self.generatedFolderNames.contains(name) {
            return true
        }
        // By extension, not by `isPackage`: a `.framework` is a bundle Finder
        // lets you walk into, and is no less code for it.
        if skips(.bundles), name == ".git" || Self.codeBundleExtensions.contains(Self.pathExtension(of: name)) {
            return true
        }
        return patterns.contains { $0.matchesName(name, isDirectory: true) }
    }

    // MARK: - Names

    /// What the system and tools keep for themselves. Hidden ones are named
    /// too, because hidden files are indexed unless that switch is on.
    static let cacheFolderNames: Set<String> = [
        "Caches", "DerivedData", "__pycache__", ".build", ".cache", ".npm", ".gradle", ".pytest_cache",
        ".mypy_cache", ".ruff_cache", ".parcel-cache", ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd",
        ".TemporaryItems", ".DocumentRevisions-V100"
    ]

    /// Finder's files: `.DS_Store`, a custom folder icon, a localised folder
    /// name. AppleDouble `._` files are matched by prefix.
    static let finderFileNames: Set<String> = [".DS_Store", "Icon\r", ".localized"]

    /// Installed dependencies: somebody else's code, in bulk.
    static let dependencyFolderNames: Set<String> = [
        "node_modules", "bower_components", "Pods", "Carthage", "venv", ".venv", "site-packages", ".next"
    ]

    /// What a tool writes and rewrites: generated code, coverage reports,
    /// framework and deploy output, tool state. Names no one gives a folder
    /// of their own, so they go wherever they are, project or not.
    static let generatedFolderNames: Set<String> = [
        "paraglide", "__generated__", ".svelte-kit", ".turbo", "coverage", ".coverage", ".nyc_output",
        ".nuxt", ".output", ".vercel", ".expo", ".angular", ".docusaurus", ".dart_tool", ".terraform",
        ".wrangler", ".cxx"
    ]

    /// Only build output when the folder beside it is a project, because a
    /// folder of drawings called "build" is somebody's work.
    static let buildOutputFolderNames: Set<String> = ["build", "Build", "dist", "out", "target", "_build"]

    /// What makes a folder a project, for `buildOutputFolderNames`. Not a
    /// `.git`: a repo of drawings can have a "build" folder too.
    static let projectMarkers: Set<String> = [
        "Package.swift", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "setup.py",
        "pom.xml", "build.gradle", "build.gradle.kts", "CMakeLists.txt", "Makefile", "Gemfile",
        "dune-project", "mix.exs"
    ]
    static let projectBundleExtensions: Set<String> = ["xcodeproj", "xcworkspace"]

    /// Bundles that are code, not documents: never a File Result, never
    /// walked into. `.app` belongs to the App Index.
    static let codeBundleExtensions: Set<String> = [
        "app", "appex", "framework", "bundle", "plugin", "kext", "xpc", "dsym", "prefpane",
        "qlgenerator", "mdimporter", "saver", "systemextension", "component", "driver"
    ]

    /// Keys, certificates and keychains, by extension. `.key` is handled on
    /// its own in `isKey`.
    static let keyExtensions: Set<String> = [
        "pem", "p12", "pfx", "cer", "crt", "der", "p8", "jks", "keystore", "ppk", "kdbx",
        "keychain", "keychain-db"
    ]
    static let keyNamePrefixes = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]

    static func isKey(_ entry: Entry) -> Bool {
        let lower = entry.name.lowercased()
        let ext = pathExtension(of: lower)
        if keyExtensions.contains(ext) { return true }
        // A Keynote presentation is a `.key` too: a zip, or a package (which
        // is a folder, and never gets here). A private key is text.
        if ext == "key" { return !entry.startsWithZipMagic }
        return keyNamePrefixes.contains(where: lower.hasPrefix)
    }

    /// `.env`, `.env.local`, `.env.production`, and direnv's `.envrc`.
    static func isEnvironmentFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == ".env" || lower == ".envrc" || lower.hasPrefix(".env.")
    }

    /// The rules as one string, kept beside the index so a launch can tell
    /// whether the rows were read under these. The switches and patterns, and
    /// the lists the groups are made of: a list that grows in an update
    /// changes what is skipped as surely as a switch does.
    var fingerprint: String {
        let lists: [Set<String>] = [
            Self.cacheFolderNames, Self.finderFileNames, Self.dependencyFolderNames, Self.generatedFolderNames,
            Self.buildOutputFolderNames, Self.projectMarkers, Self.projectBundleExtensions,
            Self.codeBundleExtensions, Self.keyExtensions, Set(Self.keyNamePrefixes)
        ]
        let switches = skipped.map(\.rawValue).sorted().joined(separator: ",")
        let patterns = patterns.map { $0.text.lowercased() }.sorted().joined(separator: "\n")
        return ([switches, patterns] + lists.map { $0.sorted().joined(separator: ",") }).joined(separator: "\n--\n")
    }

    fileprivate static func pathExtension(of name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    // MARK: - Reading an entry from disk

    /// The resource keys `Entry(url:values:)` reads. A crawl passes these to
    /// its enumerator so they are fetched with the listing, not one by one.
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
    ]
}

nonisolated extension FileIndexRules.Entry {
    /// Reads what the rules need about `url`. Only folders cost more than the
    /// listing's own resource values: a `.git` probe — and a read of it, where
    /// it is a file — and a listing of the parent for the few named like build
    /// output.
    init(url: URL, values: URLResourceValues? = nil) {
        let values = values ?? (try? url.resourceValues(forKeys: Set(FileIndexRules.resourceKeys)))
        self.init(path: url.path, isDirectory: values?.isDirectory ?? false)
        isSymbolicLink = values?.isSymbolicLink ?? false
        isPackage = values?.isPackage ?? false
        isNotDownloaded = values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus != .current
        probe()
    }

    /// What the rules need about an indexed row, for judging it again under
    /// new rules: its kind from the index, and the disk only where a rule has
    /// to look — the same probes as `init(url:)`.
    init(row: FileIndexRow) {
        self.init(path: row.path, isDirectory: row.kind != .file)
        isPackage = row.kind == .package
        probe()
    }

    private mutating func probe() {
        if isDirectory, !isPackage {
            let fileManager = FileManager.default
            var git = stat()
            containsGit = lstat(path + "/.git", &git) == 0
            isLinkedWorktree = containsGit && git.st_mode & S_IFMT == S_IFREG && Self.isWorktreePointer(path + "/.git")
            isBareRepo = !containsGit
                && fileManager.fileExists(atPath: path + "/HEAD")
                && fileManager.fileExists(atPath: path + "/objects")
                && fileManager.fileExists(atPath: path + "/refs")
            if FileIndexRules.buildOutputFolderNames.contains(name) {
                isInsideProject = Self.isProject((path as NSString).deletingLastPathComponent)
            }
        } else if !isDirectory, FileIndexRules.pathExtension(of: path) == "key" {
            startsWithZipMagic = Self.startsWithZipMagic(path)
        }
    }

    private static func isProject(_ folder: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return false }
        return names.contains { name in
            FileIndexRules.projectMarkers.contains(name)
                || FileIndexRules.projectBundleExtensions.contains((name as NSString).pathExtension)
        }
    }

    /// Whether the `.git` file at `path` is a worktree's: `gitdir:` naming
    /// `<repo>/.git/worktrees/<name>`. A submodule's names `.git/modules/…`.
    private static func isWorktreePointer(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let text = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return false }
        let gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return ((gitdir as NSString).deletingLastPathComponent as NSString).lastPathComponent == "worktrees"
    }

    private static func startsWithZipMagic(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let bytes = (try? handle.read(upToCount: 4)) ?? Data()
        return bytes == Data([0x50, 0x4B, 0x03, 0x04])
    }
}

// MARK: - Patterns

/// One of the user's own skip patterns, as typed on the Sources page.
///
/// - Without a `/`, it matches a file or folder name anywhere: `*.log`.
/// - A trailing `/` matches folders only: `Archive/`.
/// - With a `/` anywhere else, it matches the path from the Source folder
///   down, whole: `Work/old`, `**/fixtures/**`, and `/Archive` for the one
///   at the top only.
///
/// `*` is any run of characters within a name, `?` is one character, and in
/// a path `**` is any number of folders, none included. Everything else is
/// literal, and case does not matter. A folder that matches takes everything
/// inside it along.
nonisolated struct SkipPattern: Hashable, Sendable {
    /// As the user typed it, trimmed: what is shown and stored.
    let text: String
    private let foldersOnly: Bool
    private let isPath: Bool
    /// The lowercased name glob, or the path globs split at `/`.
    private let components: [String]

    /// Nil for a pattern with nothing to match: blank, or only slashes.
    init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = text.lowercased()
        foldersOnly = body.hasSuffix("/")
        while body.hasSuffix("/") { body.removeLast() }
        isPath = body.contains("/")
        components = body.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        self.text = text
    }

    /// Two spellings of one pattern are one pattern: `*.LOG` is `*.log`.
    static func == (lhs: SkipPattern, rhs: SkipPattern) -> Bool {
        (lhs.foldersOnly, lhs.isPath, lhs.components) == (rhs.foldersOnly, rhs.isPath, rhs.components)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(foldersOnly)
        hasher.combine(isPath)
        hasher.combine(components)
    }

    /// `relativePath` is from the Source folder, without a leading `/`.
    func matches(relativePath: String, isDirectory: Bool) -> Bool {
        if foldersOnly, !isDirectory { return false }
        let path = relativePath.lowercased()
        if !isPath { return Self.glob(components[0], matches: (path as NSString).lastPathComponent) }
        return Self.match(components[...], path.split(separator: "/").map(String.init)[...])
    }

    /// The name-only half of `matches`: true only for a pattern without a
    /// path, which matches the same name wherever it is.
    func matchesName(_ name: String, isDirectory: Bool) -> Bool {
        guard !isPath, !foldersOnly || isDirectory else { return false }
        return Self.glob(components[0], matches: name.lowercased())
    }

    private static func match(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
        guard let first = pattern.first else { return path.isEmpty }
        if first == "**" {
            let rest = pattern.dropFirst()
            return path.indices.contains { match(rest, path[$0...]) } || match(rest, path[path.endIndex...])
        }
        guard let name = path.first, glob(first, matches: name) else { return false }
        return match(pattern.dropFirst(), path.dropFirst())
    }

    /// `*` and `?` over one name, by the classic backtracking walk.
    private static func glob(_ pattern: String, matches name: String) -> Bool {
        let pattern = Array(pattern), name = Array(name)
        var p = 0, n = 0
        var star: Int?, resume = 0
        while n < name.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == name[n] {
                p += 1
                n += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p
                resume = n
                p += 1
            } else if let star {
                p = star + 1
                resume += 1
                n = resume
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
