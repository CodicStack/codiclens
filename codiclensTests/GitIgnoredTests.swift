import Foundation
import Testing
@testable import codiclens

/// "Ignored by git" (`FileIndexRules.SkipGroup.gitIgnored`, `GitIgnored`):
/// real repos made with `git init` in a temporary folder, crawled and sent
/// the batches FSEvents would send, against a real database. Git judges,
/// so these pin what reaches the index, not gitignore's grammar.
@Suite(.enabled(if: GitIgnored.installedGit != nil))
struct GitIgnoredTests {

    private final class Fixture {
        let folder: TemporaryFolder
        // Optional so `deinit` can close the database before deleting it.
        var writer: FileIndexWriter!
        var indexer: FileIndexer!
        private let git: String?

        init(rules: FileIndexRules = .defaults, git: String? = GitIgnored.installedGit) throws {
            folder = try TemporaryFolder()
            try folder.makeFolder("Source")
            self.git = git
            writer = try FileIndexWriter(url: folder.url.appendingPathComponent("FileIndex.sqlite"))
            indexer = FileIndexer(writer: writer, rules: rules, gitIgnored: GitIgnored(git: git))
        }

        deinit {
            (writer, indexer) = (nil, nil)
            folder.remove()
        }

        var root: String { folder.path("Source") }

        func path(_ relative: String) -> String {
            relative.isEmpty ? root : root + "/" + relative
        }

        func make(_ relative: String, contents: String = "x") throws {
            try folder.makeFile("Source/" + relative, contents: contents)
        }

        func remove(_ relative: String) throws {
            try FileManager.default.removeItem(atPath: path(relative))
        }

        /// Runs git in `relative`, as the user would in a Terminal.
        func git(_ arguments: String..., in relative: String) throws {
            try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: GitIgnored.installedGit ?? "/usr/bin/git")
            process.arguments = ["-C", path(relative)] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
        }

        /// Sets the folder Sources (relative paths) and crawls what that asks for.
        func sources(_ relatives: [String] = [""]) throws {
            for root in try indexer.setSources(relatives.map { (path: path($0), isEnabled: true) }) {
                try indexer.crawl(root)
            }
        }

        /// Adopts `rules` and crawls what that asks for, as `FileIndex` does.
        /// Returns the roots it crawled, relative.
        @discardableResult
        func rules(_ rules: FileIndexRules) throws -> [String] {
            let roots = try indexer.setRules(rules)
            for root in roots { try indexer.crawl(root) }
            return roots.map { $0 == root ? "" : String($0.dropFirst(root.count + 1)) }
        }

        func events(_ relatives: [String]) throws {
            try indexer.handle(relatives.map { FileIndexWatcher.Event(path: path($0)) })
        }

        /// A fresh indexer over the same database, as at an app launch: it
        /// has asked git nothing yet. Returns the roots it crawled.
        @discardableResult
        func relaunch(_ relatives: [String] = [""]) throws -> [String] {
            indexer = FileIndexer(writer: writer, rules: indexer.rules, gitIgnored: GitIgnored(git: git))
            let roots = try indexer.setSources(relatives.map { (path: path($0), isEnabled: true) })
            for root in roots { try indexer.crawl(root) }
            return roots
        }

        /// Every indexed path, relative to the Source.
        var indexed: Set<String> {
            get throws {
                Set(try writer.rows(inTree: folder.path).map { row in
                    row.path == root ? "" : String(row.path.dropFirst(root.count + 1))
                })
            }
        }
    }

    private static var withoutGitIgnored: FileIndexRules {
        var rules = FileIndexRules.defaults
        rules.skipped.remove(.gitIgnored)
        return rules
    }

    // MARK: - What git ignores

    @Test func anIgnoredFileAndFolderAreSkipped() throws {
        let f = try Fixture()
        try f.git("init", "-q", in: "repo")
        try f.make("repo/.gitignore", contents: "*.log\n/cache/\n")
        try f.make("repo/a.txt")
        try f.make("repo/debug.log")
        try f.make("repo/sub/trace.log")
        try f.make("repo/cache/x.json")
        try f.make("repo/sub/cache/y.json")

        try f.sources()

        #expect(try f.indexed == [
            "", "repo", "repo/.gitignore", "repo/a.txt", "repo/sub", "repo/sub/cache", "repo/sub/cache/y.json"
        ], "/cache/ is anchored: the one in sub is not ignored")
    }

    @Test func aNegatedPatternIsKept() throws {
        let f = try Fixture()
        try f.git("init", "-q", in: "repo")
        try f.make("repo/.gitignore", contents: "data/*\n!data/keep.json\n")
        try f.make("repo/data/keep.json")
        try f.make("repo/data/drop.json")
        try f.make("repo/data/raw/x.json")

        try f.sources()

        #expect(try f.indexed == ["", "repo", "repo/.gitignore", "repo/data", "repo/data/keep.json"])
    }

    @Test func aNestedGitignoreCountsBelowItsFolder() throws {
        let f = try Fixture()
        try f.git("init", "-q", in: "repo")
        try f.make("repo/sub/.gitignore", contents: "*.tmp\n")
        try f.make("repo/a.tmp")
        try f.make("repo/sub/b.tmp")
        try f.make("repo/sub/deeper/c.tmp")

        try f.sources()

        #expect(try f.indexed == ["", "repo", "repo/a.tmp", "repo/sub", "repo/sub/.gitignore", "repo/sub/deeper"])
    }

    @Test func infoExcludeCounts() throws {
        let f = try Fixture()
        try f.git("init", "-q", in: "repo")
        try f.make("repo/.git/info/exclude", contents: "private/\n")
        try f.make("repo/private/notes.txt")
        try f.make("repo/public.txt")

        try f.sources()

        #expect(try f.indexed == ["", "repo", "repo/public.txt"])
    }

    /// Git does not ignore what it tracks, whatever `.gitignore` says.
    @Test func aTrackedFileIsNotIgnored() throws {
        let f = try Fixture()
        try f.git("init", "-q", in: "repo")
        try f.make("repo/.gitignore", contents: "*.log\n")
        try f.make("repo/tracked.log")
        try f.make("repo/untracked.log")
        try f.git("add", "-f", "tracked.log", in: "repo")

        try f.sources()

        #expect(try f.indexed == ["", "repo", "repo/.gitignore", "repo/tracked.log"])
    }

    // MARK: - .env files and keys

    /// They keep to their own switches, even in a folder git ignores. The
    /// folder itself has no row; switched on, they go too.
    @Test func envFilesAndKeysThatGitIgnoresAreKept() throws {
        let f = try Fixture()
        try f.git("init", "-q", in: "repo")
        try f.make("repo/.gitignore", contents: "secrets/\n.env\n*.pem\n")
        try f.make("repo/main.py")
        try f.make("repo/.env")
        try f.make("repo/server.pem")
        try f.make("repo/secrets/prod.pem")
        try f.make("repo/secrets/notes.txt")
        try f.make("repo/secrets/deep/.env.local")

        try f.sources()
        #expect(try f.indexed == [
            "", "repo", "repo/.gitignore", "repo/main.py", "repo/.env", "repo/server.pem",
            "repo/secrets/prod.pem", "repo/secrets/deep/.env.local"
        ])

        #expect(try f.rules(FileIndexRules(skipped: FileIndexRules.defaultSkipped.union([.envFiles, .keys]),
                                           patterns: [])).isEmpty, "skipping more needs no crawl")
        #expect(try f.indexed == ["", "repo", "repo/.gitignore", "repo/main.py"])
    }

    // MARK: - The switch

    @Test func switchingItOffBringsEverythingBackAndOnTakesItAwayWithoutACrawl() throws {
        let f = try Fixture()
        try f.git("init", "-q", in: "repo")
        try f.make("repo/.gitignore", contents: "*.log\nsecrets/\n")
        try f.make("repo/a.txt")
        try f.make("repo/debug.log")
        try f.make("repo/secrets/prod.pem")
        try f.make("repo/secrets/notes.txt")
        try f.sources()
        let kept: Set<String> = ["", "repo", "repo/.gitignore", "repo/a.txt", "repo/secrets/prod.pem"]
        #expect(try f.indexed == kept)

        #expect(try f.rules(Self.withoutGitIgnored) == [""])
        #expect(try f.indexed == kept.union(["repo/debug.log", "repo/secrets", "repo/secrets/notes.txt"]))

        #expect(try f.rules(.defaults).isEmpty, "skipping more needs no crawl")
        #expect(try f.indexed == kept)
    }

    @Test func withoutGitNothingIsIgnored() throws {
        let f = try Fixture(git: nil)
        try f.git("init", "-q", in: "repo")
        try f.make("repo/.gitignore", contents: "*.log\n")
        try f.make("repo/debug.log")

        try f.sources()
        try f.make("repo/new.log")
        try f.events(["repo/new.log"])

        #expect(try f.indexed == ["", "repo", "repo/.gitignore", "repo/debug.log", "repo/new.log"])
    }

    @Test func aFolderOutsideAnyRepoIsUnaffected() throws {
        let f = try Fixture()
        try f.make("plain/.gitignore", contents: "*.log\n")
        try f.make("plain/debug.log")

        try f.sources()

        #expect(try f.indexed == ["", "plain", "plain/.gitignore", "plain/debug.log"])
    }

    // MARK: - Where the repos are

    /// A Source that is a repo is asked; a repo around a Source is not — a
    /// dotfiles repo at `~` ignoring `*` would empty Documents.
    @Test func aSourceThatIsARepoIsAskedAndARepoAroundOneIsNot() throws {
        let f = try Fixture()
        try f.git("init", "-q", in: "repo")
        try f.make("repo/.gitignore", contents: "*.log\n")
        try f.make("repo/debug.log")
        try f.make("repo/docs/notes.log")

        try f.sources(["repo", "repo/docs"])

        #expect(try f.indexed == ["repo", "repo/.gitignore", "repo/docs", "repo/docs/notes.log"])
    }

    /// Git does not look inside a repo from the one around it: each keeps
    /// its own rules, and a folder the outer one ignores takes a repo in it
    /// along.
    @Test func nestedReposKeepTheirOwnRules() throws {
        let f = try Fixture()
        try f.git("init", "-q", in: "repo")
        try f.make("repo/.gitignore", contents: "vendor/\n*.log\n")
        try f.git("init", "-q", in: "repo/vendor/lib")
        try f.make("repo/vendor/lib/lib.c")
        try f.git("init", "-q", in: "repo/other")
        try f.make("repo/other/.gitignore", contents: "*.o\n")
        try f.make("repo/other/a.c")
        try f.make("repo/other/a.o")
        try f.make("repo/other/run.log")

        try f.sources()

        #expect(try f.indexed == [
            "", "repo", "repo/.gitignore", "repo/other", "repo/other/.gitignore", "repo/other/a.c", "repo/other/run.log"
        ])
    }

    // MARK: - FSEvents

    @Test func newPathsAreJudgedByGit() throws {
        let f = try Fixture()
        try f.git("init", "-q", in: "repo")
        try f.make("repo/.gitignore", contents: "*.log\nbuild/\nsecrets/\n")
        try f.make("repo/secrets/old.txt")
        try f.sources()

        try f.make("repo/new.log")
        try f.make("repo/new.txt")
        try f.make("repo/build/out.js")
        try f.make("repo/secrets/new.pem")
        try f.make("repo/fresh/notes.txt")
        try f.make("repo/fresh/trace.log")
        try f.events(["repo/new.log", "repo/new.txt", "repo/build", "repo/build/out.js", "repo/secrets/new.pem",
                      "repo/fresh"])

        #expect(try f.indexed == [
            "", "repo", "repo/.gitignore", "repo/new.txt", "repo/secrets/new.pem", "repo/fresh", "repo/fresh/notes.txt"
        ])
    }

    /// A launch that replays has listed no repo: what the replay brings is
    /// put to git as it arrives, and nothing is crawled.
    @Test func aLaunchThatReplaysAsksGitAboutWhatItBrings() throws {
        let f = try Fixture()
        try f.git("init", "-q", in: "repo")
        try f.make("repo/.gitignore", contents: "*.log\nsecrets/\n")
        try f.sources()

        try f.make("repo/closed.log")
        try f.make("repo/closed.txt")
        try f.make("repo/secrets/new.pem")
        try f.make("repo/secrets/new.txt")
        try f.make("repo/fresh/trace.log")
        try f.make("repo/fresh/notes.txt")
        #expect(try f.relaunch().isEmpty)
        try f.events(["repo/closed.log", "repo/closed.txt", "repo/secrets/new.pem", "repo/secrets/new.txt",
                      "repo/fresh"])

        #expect(try f.indexed == [
            "", "repo", "repo/.gitignore", "repo/closed.txt", "repo/secrets/new.pem", "repo/fresh", "repo/fresh/notes.txt"
        ])
    }

    @Test func editingAGitignoreAppliesItAgain() throws {
        let f = try Fixture()
        try f.git("init", "-q", in: "repo")
        try f.make("repo/.gitignore", contents: "*.log\n")
        try f.make("repo/a.txt")
        try f.make("repo/sub/b.txt")
        try f.make("repo/debug.log")
        try f.sources()

        try f.make("repo/.gitignore", contents: "*.txt\n")
        try f.events(["repo/.gitignore"])
        #expect(try f.indexed == ["", "repo", "repo/.gitignore", "repo/sub", "repo/debug.log"])

        try f.remove("repo/.gitignore")
        try f.events(["repo/.gitignore"])
        #expect(try f.indexed == ["", "repo", "repo/a.txt", "repo/sub", "repo/sub/b.txt", "repo/debug.log"])
    }

    @Test func editingInfoExcludeAppliesItAgain() throws {
        let f = try Fixture()
        try f.git("init", "-q", in: "repo")
        try f.make("repo/private/notes.txt")
        try f.sources()
        #expect(try f.indexed.contains("repo/private/notes.txt"))

        try f.make("repo/.git/info/exclude", contents: "private/\n")
        try f.events(["repo/.git/info/exclude"])

        #expect(try f.indexed == ["", "repo"])
    }

    /// The same applied again after a launch, when nothing was listed yet.
    @Test func aGitignoreChangedWhileClosedIsAppliedByTheReplay() throws {
        let f = try Fixture()
        try f.git("init", "-q", in: "repo")
        try f.make("repo/a.txt")
        try f.make("repo/debug.log")
        try f.sources()

        try f.make("repo/.gitignore", contents: "*.log\n")
        #expect(try f.relaunch().isEmpty)
        try f.events(["repo/.gitignore"])

        #expect(try f.indexed == ["", "repo", "repo/.gitignore", "repo/a.txt"])
    }

    @Test func aFolderThatBecomesARepoIsJudgedByGit() throws {
        let f = try Fixture()
        try f.make("project/.gitignore", contents: "*.log\n")
        try f.make("project/debug.log")
        try f.make("project/main.c")
        try f.sources()
        #expect(try f.indexed.contains("project/debug.log"))

        try f.git("init", "-q", in: "project")
        try f.events(["project/.git"])
        #expect(try f.indexed == ["", "project", "project/.gitignore", "project/main.c"])

        try FileManager.default.removeItem(atPath: f.path("project/.git"))
        try f.events(["project/.git"])
        #expect(try f.indexed.contains("project/debug.log"), "no repo, nothing ignored")
    }

    /// npm writes a `.gitignore` all over `node_modules`; git reads none of
    /// them, and neither are they a reason to read the repo again.
    @Test func aGitignoreInASkippedFolderIsNotNews() throws {
        let f = try Fixture()
        try f.git("init", "-q", in: "repo")
        try f.make("repo/a.txt")
        try f.sources()

        // Made with no event of its own: only reading the repo again finds it.
        try f.make("repo/unannounced.txt")
        try f.make("repo/node_modules/pkg/.gitignore", contents: "*.txt\n")
        try f.events(["repo/node_modules/pkg/.gitignore"])

        #expect(try f.indexed == ["", "repo", "repo/a.txt"])
    }
}
