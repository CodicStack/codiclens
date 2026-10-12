import Foundation
import Testing
@testable import codiclens

/// `FileIndexRules`: what the File Index leaves out. Every case here is one
/// the crawl and the FSEvents handler would otherwise have to agree on.
struct FileIndexRulesTests {
    private static let home = "/Users/someone"
    private static let root = "/Users/someone/Documents"

    private func verdict(
        _ path: String,
        directory: Bool = false,
        root: String = FileIndexRulesTests.root,
        rules: FileIndexRules = .defaults,
        configure: (inout FileIndexRules.Entry) -> Void = { _ in }
    ) -> FileIndexRules.Verdict {
        var entry = FileIndexRules.Entry(path: path, isDirectory: directory)
        configure(&entry)
        return rules.verdict(for: entry, root: root, home: Self.home)
    }

    private static func rules(skipping groups: FileIndexRules.SkipGroup..., patterns: [String] = []) -> FileIndexRules {
        FileIndexRules(skipped: Set(groups), patterns: patterns.compactMap(SkipPattern.init))
    }

    private static let everything = FileIndexRules(skipped: Set(FileIndexRules.SkipGroup.allCases), patterns: [])
    private static let nothing = FileIndexRules(skipped: [], patterns: [])

    // MARK: - Defaults

    @Test func aNewInstallSkipsCachesDependenciesAndBundlesOnly() {
        #expect(FileIndexRules.defaults.skipped == [.caches, .dependencies, .bundles])
        #expect(FileIndexRules.defaults.patterns.isEmpty)
    }

    @Test func ordinaryFilesAndFoldersAreIndexed() {
        #expect(verdict("/Users/someone/Documents/Skatteårsopgørelse.pdf") == .index)
        #expect(verdict("/Users/someone/Documents/Taxes", directory: true) == .index)
    }

    /// The user wants to find these, and it is all local.
    @Test func byDefaultHiddenFilesReposEnvFilesAndKeysAreIndexed() {
        #expect(verdict("/Users/someone/Documents/.gitignore") == .index)
        #expect(verdict("/Users/someone/Documents/.config", directory: true) == .index)
        #expect(verdict("/Users/someone/Documents/codiclens", directory: true) { $0.containsGit = true } == .index)
        #expect(verdict("/Users/someone/Documents/app/.env") == .index)
        #expect(verdict("/Users/someone/Documents/id_rsa") == .index)
        #expect(verdict("/Users/someone/Documents/server.pem") == .index)
    }

    /// Repos are in, their insides are not: those are git's.
    @Test func byDefaultGitsInsidesAreSkippedInAnIncludedRepo() {
        #expect(verdict("/Users/someone/Documents/codiclens/.git", directory: true) == .skip)
        #expect(verdict("/Users/someone/Documents/worktree/.git") == .skip, "a worktree's .git is a file")
        #expect(verdict("/Users/someone/Documents/backup.git", directory: true) { $0.isBareRepo = true }
            == .indexWithoutDescending, "a bare repo is listed, its objects are not")
        #expect(verdict("/Users/someone/Documents/.git", directory: true, rules: Self.nothing) == .index)
    }

    @Test func byDefaultFindersFilesAreSkipped() {
        #expect(verdict("/Users/someone/Documents/.DS_Store") == .skip)
        #expect(verdict("/Users/someone/Documents/Icon\r") == .skip)
        #expect(verdict("/Users/someone/Documents/._Report.pdf") == .skip)
        #expect(verdict("/Users/someone/Documents/.DS_Store", rules: Self.nothing) == .index)
    }

    // MARK: - Each group

    @Test func cachesTakeLibraryCacheFoldersAndNoindex() {
        let rules = Self.rules(skipping: .caches)
        #expect(verdict("/Users/someone/Library", directory: true, root: Self.home, rules: rules) == .skip)
        #expect(verdict("/Users/someone/LibraryBooks", directory: true, root: Self.home, rules: rules) == .index)
        for name in ["DerivedData", "Caches", "__pycache__", ".build", ".cache", "Photos.noindex"] {
            #expect(verdict("/Users/someone/Documents/" + name, directory: true, rules: rules) == .skip, "\(name)")
            #expect(verdict("/Users/someone/Documents/" + name, directory: true, rules: Self.nothing) == .index, "\(name)")
        }
    }

    @Test func dependenciesTakeNodeModulesAndBuildOutput() {
        let rules = Self.rules(skipping: .dependencies)
        for name in ["node_modules", "Pods", "venv", ".venv", "site-packages"] {
            #expect(verdict("/Users/someone/Documents/" + name, directory: true, rules: rules) == .skip, "\(name)")
            #expect(verdict("/Users/someone/Documents/" + name, directory: true, rules: Self.nothing) == .index, "\(name)")
        }
        #expect(verdict("/Users/someone/Documents/tool/build", directory: true, rules: Self.nothing) {
            $0.isInsideProject = true
        } == .index)
    }

    /// `build` is build output only beside a project. A folder of drawings
    /// called "build" is somebody's work.
    @Test func aBuildFolderIsSkippedOnlyInsideAProject() {
        #expect(verdict("/Users/someone/Documents/tool/build", directory: true) { $0.isInsideProject = true } == .skip)
        #expect(verdict("/Users/someone/Documents/tool/dist", directory: true) { $0.isInsideProject = true } == .skip)
        #expect(verdict("/Users/someone/Documents/house/build", directory: true) == .index)
        #expect(verdict("/Users/someone/Documents/tool/docs", directory: true) { $0.isInsideProject = true } == .index)
    }

    @Test func bundlesTakeAppsWholeAndPackageInsides() {
        let rules = Self.rules(skipping: .bundles)
        #expect(verdict("/Users/someone/Downloads/Tool.app", directory: true, rules: rules) { $0.isPackage = true } == .skip)
        #expect(verdict("/Users/someone/Downloads/Ext.framework", directory: true, rules: rules) == .skip,
                "a framework is not a package to Finder, and is code all the same")
        #expect(verdict("/Users/someone/Documents/Notes.rtfd", directory: true, rules: rules) { $0.isPackage = true }
            == .indexWithoutDescending)
    }

    @Test func withBundlesOffAppsAndPackagesAreFolders() {
        #expect(verdict("/Users/someone/Downloads/Tool.app", directory: true, rules: Self.nothing) { $0.isPackage = true }
            == .index)
        #expect(verdict("/Users/someone/Documents/Notes.rtfd", directory: true, rules: Self.nothing) { $0.isPackage = true }
            == .index)
        #expect(verdict("/Users/someone/Documents/backup.git", directory: true, rules: Self.nothing) {
            $0.isBareRepo = true
        } == .index)
    }

    @Test func hiddenTakesEveryNameWithALeadingDot() {
        let rules = Self.rules(skipping: .hidden)
        #expect(verdict("/Users/someone/Documents/.gitignore", rules: rules) == .skip)
        #expect(verdict("/Users/someone/Documents/.config", directory: true, rules: rules) == .skip)
        #expect(verdict("/Users/someone/Documents/notes.txt", rules: rules) == .index)
    }

    @Test func reposTakeARepoWholeUnlessItIsTheSource() {
        let rules = Self.rules(skipping: .repos)
        #expect(verdict("/Users/someone/Documents/codiclens", directory: true, rules: rules) { $0.containsGit = true }
            == .skip)
        #expect(verdict("/Users/someone/Documents/backup.git", directory: true, rules: rules) { $0.isBareRepo = true }
            == .skip)
        #expect(verdict("/Users/someone/Documents/codiclens", directory: true,
                        root: "/Users/someone/Documents/codiclens", rules: rules) { $0.containsGit = true } == .index)
    }

    @Test func envFilesTakeDotEnvAndItsVariants() {
        let rules = Self.rules(skipping: .envFiles)
        for name in [".env", ".env.production", ".env.local", ".envrc"] {
            #expect(verdict("/Users/someone/Documents/app/" + name, rules: rules) == .skip, "\(name)")
        }
        #expect(verdict("/Users/someone/Documents/app/.environment-notes", rules: rules) == .index)
        #expect(verdict("/Users/someone/Documents/app/env.txt", rules: rules) == .index)
    }

    @Test func keysTakeKeysCertificatesAndKeychains() {
        let rules = Self.rules(skipping: .keys)
        for name in ["server.pem", "cert.p12", "bundle.pfx", "apple.cer", "ca.crt", "login.keychain",
                     "login.keychain-db", "id_rsa", "id_rsa.pub", "id_ed25519", "private.key", "Vault.kdbx"] {
            #expect(verdict("/Users/someone/Downloads/" + name, root: "/Users/someone/Downloads", rules: rules) == .skip,
                    "\(name) should be skipped")
        }
    }

    /// `.key` is also Keynote's. A Keynote file is a zip; a private key is text.
    @Test func aKeynoteFileIsNotAKey() {
        let rules = Self.rules(skipping: .keys, .bundles)
        #expect(verdict("/Users/someone/Documents/Talk.key", rules: rules) { $0.startsWithZipMagic = true } == .index)
        #expect(verdict("/Users/someone/Documents/Talk.key", directory: true, rules: rules) { $0.isPackage = true }
            == .indexWithoutDescending)
    }

    @Test func everyGroupOnLeavesOnlyOrdinaryThingsIn() {
        #expect(verdict("/Users/someone/Documents/report.pdf", rules: Self.everything) == .index)
        #expect(verdict("/Users/someone/Documents/.env", rules: Self.everything) == .skip)
        #expect(verdict("/Users/someone/Documents/repo", directory: true, rules: Self.everything) {
            $0.containsGit = true
        } == .skip)
    }

    @Test func aSourceRootIsIndexedWhateverItIs() {
        for rules in [Self.everything, Self.rules(skipping: .caches, patterns: ["Notes"])] {
            #expect(verdict("/Users/someone/Library/Notes", directory: true,
                            root: "/Users/someone/Library/Notes", rules: rules) == .index)
        }
        #expect(verdict("/Users/someone/node_modules", directory: true, root: "/Users/someone/node_modules") == .index)
    }

    @Test func iCloudPlaceholdersAndSymlinksAreAlwaysSkipped() {
        #expect(verdict("/Users/someone/Documents/Big.mov", rules: Self.nothing) { $0.isNotDownloaded = true } == .skip)
        #expect(verdict("/Users/someone/Documents/link", rules: Self.nothing) { $0.isSymbolicLink = true } == .skip)
    }

    @Test func rulesThatSkipMoreSkipAtLeastTheOldOnes() {
        let base = Self.rules(skipping: .caches, patterns: ["*.log"])
        #expect(Self.rules(skipping: .caches, .repos, patterns: ["*.log", "tmp/"]).skipsAtLeast(base))
        #expect(!Self.rules(skipping: .caches, .repos).skipsAtLeast(base), "a pattern removed lets things in")
        #expect(!Self.rules(skipping: .repos, patterns: ["*.log"]).skipsAtLeast(base), "a group switched off")
        #expect(Self.rules(skipping: .caches, patterns: ["*.LOG"]).skipsAtLeast(base), "one pattern, two spellings")
    }

    // MARK: - Patterns

    private func skips(_ pattern: String, _ relative: String, directory: Bool = false) -> Bool {
        verdict(Self.root + "/" + relative, directory: directory, rules: Self.rules(patterns: [pattern])) == .skip
    }

    @Test func aPatternWithoutASlashMatchesANameAnywhere() {
        #expect(skips("*.log", "server.log"))
        #expect(skips("*.log", "deep/inside/Server.LOG"), "case does not matter")
        #expect(skips("*.log", "logs", directory: true) == false)
        #expect(skips("Archive", "old/Archive", directory: true))
        #expect(skips("Archive", "Archive.zip") == false, "the whole name, not a prefix")
        #expect(skips("draft?.txt", "draft2.txt"))
        #expect(skips("draft?.txt", "draft10.txt") == false)
        #expect(skips("*report*", "Q3 report final.pdf"))
    }

    @Test func aTrailingSlashMatchesFoldersOnly() {
        #expect(skips("Archive/", "old/Archive", directory: true))
        #expect(skips("Archive/", "old/Archive") == false)
        #expect(skips("*.tmp/", "x.tmp", directory: true))
    }

    @Test func aPatternWithASlashMatchesThePathFromTheSourceFolder() {
        #expect(skips("Work/old", "Work/old", directory: true))
        #expect(skips("Work/old", "Other/Work/old", directory: true) == false, "anchored at the Source folder")
        #expect(skips("/Archive", "Archive", directory: true))
        #expect(skips("/Archive", "old/Archive", directory: true) == false, "a leading / anchors a name")
        #expect(skips("docs/*.md", "docs/a.md"))
        #expect(skips("docs/*.md", "docs/sub/a.md") == false, "* stays within a name")
    }

    @Test func doubleStarMatchesAnyNumberOfFolders() {
        #expect(skips("**/fixtures/**", "fixtures", directory: true))
        #expect(skips("**/fixtures/**", "a/b/fixtures", directory: true))
        #expect(skips("**/fixtures/**", "a/fixtures/x.json"))
        #expect(skips("Work/**/old", "Work/old", directory: true))
        #expect(skips("Work/**/old", "Work/2023/q1/old", directory: true))
        #expect(skips("Work/**/old", "Home/old", directory: true) == false)
    }

    @Test func aBlankPatternIsNoPatternAndSpellingsCoincide() {
        #expect(SkipPattern("") == nil)
        #expect(SkipPattern("   ") == nil)
        #expect(SkipPattern("/") == nil)
        #expect(SkipPattern("//") == nil)
        #expect(SkipPattern("  *.log ")?.text == "*.log")
        #expect(SkipPattern("*.log") == SkipPattern("*.LOG"))
        #expect(SkipPattern("Archive") != SkipPattern("Archive/"))
        #expect(SkipPattern("Archive") != SkipPattern("/Archive"))
    }

    @Test func aNamePatternSkipsAFolderByNameAlone() {
        let rules = Self.rules(patterns: ["Archive/", "*.log", "Work/old"])
        #expect(rules.skipsFolder(named: "Archive"))
        #expect(rules.skipsFolder(named: "x.log"))
        #expect(!rules.skipsFolder(named: "old"), "a path pattern needs the path")
    }

    // MARK: - Reading an entry from disk

    @Test func entriesReadFromDiskCarryWhatTheRulesNeed() throws {
        let root = try TemporaryFolder()
        defer { root.remove() }
        try root.makeFolder("repo/.git")
        try root.makeFile("worktree/.git", contents: "gitdir: elsewhere")
        try root.makeFile("backup.git/HEAD", contents: "ref: refs/heads/main")
        try root.makeFolder("backup.git/objects/9c")
        try root.makeFolder("backup.git/refs/heads")
        try root.makeFile("notes/HEAD", contents: "a heading")
        try root.makeFile("tool/Package.swift")
        try root.makeFolder("tool/build")
        try root.makeFolder("house/build")
        try root.makeFile("Talk.key", data: Data([0x50, 0x4B, 0x03, 0x04, 0x00]))
        try root.makeFile("private.key", contents: "-----BEGIN PRIVATE KEY-----")
        try root.makeFolder("Tool.app/Contents")
        try FileManager.default.createSymbolicLink(atPath: root.path("link"), withDestinationPath: root.path("repo"))

        func entry(_ relative: String) -> FileIndexRules.Entry {
            FileIndexRules.Entry(url: URL(fileURLWithPath: root.path(relative)))
        }

        #expect(entry("repo").containsGit)
        #expect(entry("worktree").containsGit, "a .git file — a worktree or submodule — is a repo too")
        #expect(entry("backup.git").isBareRepo, "a bare repo has no .git, and is one")
        #expect(!entry("backup.git").containsGit)
        #expect(!entry("repo").isBareRepo)
        #expect(!entry("notes").containsGit && !entry("notes").isBareRepo, "a file called HEAD is not a repo")
        #expect(entry("tool/build").isInsideProject)
        #expect(!entry("house/build").isInsideProject)
        #expect(entry("Talk.key").startsWithZipMagic)
        #expect(!entry("private.key").startsWithZipMagic)
        #expect(entry("Tool.app").isPackage)
        #expect(entry("link").isSymbolicLink)
    }
}

/// A folder under the temporary directory, by its real path — FSEvents and
/// the enumerator report `/private/var/…` where `temporaryDirectory` says
/// `/var/…`.
struct TemporaryFolder {
    let url: URL

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-file-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.url = URL(fileURLWithPath: FileIndexer.realPath(url.path))
    }

    var path: String { url.path }

    func path(_ relative: String) -> String {
        url.appendingPathComponent(relative).path
    }

    func makeFolder(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    func makeFile(_ relative: String, contents: String = "x") throws {
        try makeFile(relative, data: Data(contents.utf8))
    }

    func makeFile(_ relative: String, data: Data) throws {
        let url = URL(fileURLWithPath: path(relative))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func move(_ from: String, to: String) throws {
        try FileManager.default.moveItem(atPath: path(from), toPath: path(to))
    }

    func removeItem(_ relative: String) throws {
        try FileManager.default.removeItem(atPath: path(relative))
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
