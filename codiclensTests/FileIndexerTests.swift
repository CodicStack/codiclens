import CoreServices
import Foundation
import Testing
@testable import codiclens

/// `FileIndexer` against a real folder and a real database, driven by direct
/// calls: a crawl, then the path batches FSEvents would deliver. Whether
/// FSEvents delivers them is `FileIndexWatcherTests`' business.
struct FileIndexerTests {

    private final class Fixture {
        let folder: TemporaryFolder
        // Optional so `deinit` can close the database before deleting it:
        // SQLite reports a file unlinked under an open connection.
        var writer: FileIndexWriter!
        var reader: FileIndexReader!
        var indexer: FileIndexer!

        init(rules: FileIndexRules = .defaults) throws {
            folder = try TemporaryFolder()
            try folder.makeFolder("Source")
            let url = folder.url.appendingPathComponent("FileIndex.sqlite")
            writer = try FileIndexWriter(url: url)
            reader = FileIndexReader(url: url)
            indexer = FileIndexer(writer: writer, rules: rules)
        }

        deinit {
            (writer, reader, indexer) = (nil, nil, nil)
            folder.remove()
        }

        var root: String { folder.path("Source") }

        func path(_ relative: String) -> String {
            relative.isEmpty ? root : root + "/" + relative
        }

        func make(_ relative: String, contents: String = "x") throws {
            try folder.makeFile("Source/" + relative, contents: contents)
        }

        func makeFolder(_ relative: String) throws {
            try folder.makeFolder("Source/" + relative)
        }

        func move(_ from: String, _ to: String) throws {
            try FileManager.default.moveItem(atPath: path(from), toPath: path(to))
        }

        func remove(_ relative: String) throws {
            try FileManager.default.removeItem(atPath: path(relative))
        }

        /// Sets the folder Sources (relative paths) and crawls what that asks for.
        func sources(_ relatives: [String], disabled: Set<String> = []) throws {
            let folders = relatives.map { (path: path($0), isEnabled: !disabled.contains($0)) }
            for root in try indexer.setSources(folders) { try indexer.crawl(root) }
        }

        /// Adopts `rules` and crawls what that asks for, as `FileIndex` does.
        /// Returns the roots it crawled, relative.
        @discardableResult
        func rules(_ rules: FileIndexRules) throws -> [String] {
            let roots = try indexer.setRules(rules)
            for root in roots { try indexer.crawl(root) }
            return roots.map { $0 == root ? "" : String($0.dropFirst(root.count + 1)) }
        }

        func events(_ relatives: [String], flags: Int = 0) throws {
            try indexer.handle(relatives.map {
                FileIndexWatcher.Event(path: path($0), flags: FSEventStreamEventFlags(flags))
            })
        }

        /// Every indexed path, relative to the Source.
        var indexed: Set<String> {
            get throws {
                Set(try writer.rows(inTree: folder.path).map { row in
                    row.path == root ? "" : String(row.path.dropFirst(root.count + 1))
                })
            }
        }

        func id(_ relative: String) throws -> Int64? {
            try writer.row(atPath: path(relative))?.id
        }

        func source(of relative: String) throws -> String? {
            try writer.row(atPath: path(relative))?.source
        }
    }

    // MARK: - Crawl

    private static func makeMixedTree(_ f: Fixture) throws {
        try f.make("a.txt")
        try f.make("sub/b.pdf")
        try f.make(".hidden")
        try f.make(".DS_Store")
        try f.make(".secrets/c.txt")
        try f.make("node_modules/x/index.js")
        try f.make("repo/.git/HEAD")
        try f.make("repo/README.md")
        try f.make("Tool.app/Contents/Info.plist")
        try f.make("Notes.rtfd/TXT.rtf")
        try f.make("id_rsa")
        try f.make("app/.env")
    }

    @Test func aCrawlIndexesWhatTheDefaultRulesAllow() throws {
        let f = try Fixture()
        try Self.makeMixedTree(f)

        try f.sources([""])

        #expect(try f.indexed == [
            "", "a.txt", "sub", "sub/b.pdf", ".hidden", ".secrets", ".secrets/c.txt", "repo", "repo/README.md",
            "Notes.rtfd", "id_rsa", "app", "app/.env"
        ])
        #expect(f.reader.counts() == [f.root: 13])
    }

    @Test func aCrawlWithEveryGroupOnIndexesOnlyOrdinaryThings() throws {
        let f = try Fixture(rules: FileIndexRules(skipped: Set(FileIndexRules.SkipGroup.allCases), patterns: []))
        try Self.makeMixedTree(f)

        try f.sources([""])

        #expect(try f.indexed == ["", "a.txt", "sub", "sub/b.pdf", "Notes.rtfd", "app"])
    }

    @Test func aCrawlWithEveryGroupOffIndexesEverything() throws {
        let f = try Fixture(rules: FileIndexRules(skipped: [], patterns: []))
        try Self.makeMixedTree(f)

        try f.sources([""])

        #expect(try f.indexed.isSuperset(of: [
            ".DS_Store", "node_modules/x/index.js", "repo/.git/HEAD", "Tool.app/Contents/Info.plist",
            "Notes.rtfd/TXT.rtf"
        ]))
    }

    @Test func aRepoAddedAsASourceIsReadAsOne() throws {
        let f = try Fixture()
        try f.make("repo/.git/HEAD")
        try f.make("repo/README.md")
        try f.make("repo/node_modules/x.js")

        try f.sources(["", "repo"])

        #expect(try f.indexed == ["", "repo", "repo/README.md"])
        #expect(try f.source(of: "repo/README.md") == f.path("repo"))
    }

    /// A repo checked out three times is indexed once: the main checkout,
    /// not the worktrees beside it, unless a worktree is a Source itself or
    /// the switch is off. Generated code goes with node_modules.
    @Test func worktreesAndGeneratedCodeStayOutByDefault() throws {
        let f = try Fixture()
        try f.make("app/.git/HEAD")
        try f.make("app/src/main.ts")
        try f.make("app/src/paraglide/messages/hello.js")
        try f.make("app/.svelte-kit/output/x.js")
        try f.make("app-wt-1/.git", contents: "gitdir: \(f.path("app/.git/worktrees/app-wt-1"))")
        try f.make("app-wt-1/src/main.ts")
        try f.make("app-wt-2/.git", contents: "gitdir: \(f.path("app/.git/worktrees/app-wt-2"))")
        try f.make("app-wt-2/src/main.ts")

        try f.sources(["", "app-wt-2"])
        #expect(try f.indexed == ["", "app", "app/src", "app/src/main.ts", "app-wt-2", "app-wt-2/src", "app-wt-2/src/main.ts"])

        var keepWorktrees = FileIndexRules.defaults
        keepWorktrees.skipped.remove(.worktrees)
        #expect(try f.rules(keepWorktrees) == ["", "app-wt-2"])
        #expect(try f.indexed.isSuperset(of: ["app-wt-1", "app-wt-1/src/main.ts"]))
    }

    @Test func aFolderThatBecomesAWorktreeLeaves() throws {
        let f = try Fixture()
        try f.make("checkout/notes.txt")
        try f.sources([""])

        try f.make("checkout/.git", contents: "gitdir: /elsewhere/.git/worktrees/checkout")
        try f.events(["checkout/.git"])

        #expect(try f.indexed == [""])
    }

    @Test func aSecondCrawlKeepsRowsAndFindsAMoveByInode() throws {
        let f = try Fixture()
        try f.make("a/report.pdf")
        try f.makeFolder("b")
        try f.sources([""])
        let id = try f.id("a/report.pdf")

        try f.move("a/report.pdf", "b/report.pdf")
        try f.indexer.crawl(f.root)

        #expect(try f.indexed == ["", "a", "b", "b/report.pdf"])
        #expect(try f.id("b/report.pdf") == id, "moved, not deleted and re-added")
    }

    // MARK: - Events

    @Test func aNewFileIsAdded() throws {
        let f = try Fixture()
        try f.sources([""])

        try f.make("new.txt")
        try f.events(["new.txt"])

        #expect(try f.indexed == ["", "new.txt"])
    }

    @Test func aDeletedFileOrFolderIsRemovedWithItsContents() throws {
        let f = try Fixture()
        try f.make("a.txt")
        try f.make("dir/b.txt")
        try f.make("dir/deeper/c.txt")
        try f.sources([""])

        try f.remove("a.txt")
        try f.remove("dir")
        try f.events(["a.txt", "dir"])

        #expect(try f.indexed == [""])
    }

    @Test func aRenameKeepsTheRow() throws {
        let f = try Fixture()
        try f.make("draft.txt")
        try f.sources([""])
        let id = try f.id("draft.txt")

        try f.move("draft.txt", "final.txt")
        try f.events(["draft.txt", "final.txt"])

        #expect(try f.indexed == ["", "final.txt"])
        #expect(try f.id("final.txt") == id)
        #expect(f.reader.search("final", limit: 5, sources: [f.root]).map(\.name) == ["final.txt"])
        #expect(f.reader.search("draft", limit: 5, sources: [f.root]).isEmpty)
    }

    @Test func aMovedFolderTakesItsContentsWithIt() throws {
        let f = try Fixture()
        try f.make("old/a.txt")
        try f.make("old/inner/b.txt")
        try f.sources([""])
        let ids = try ["old", "old/a.txt", "old/inner/b.txt"].map(f.id)

        try f.move("old", "new")
        try f.events(["new", "old"])

        #expect(try f.indexed == ["", "new", "new/a.txt", "new/inner", "new/inner/b.txt"])
        #expect(try ["new", "new/a.txt", "new/inner/b.txt"].map(f.id) == ids)
        #expect(f.reader.search("b", limit: 5, sources: [f.root]).first?.folder.hasSuffix("/new/inner") == true)
    }

    /// A case-only rename arrives under both names, and on a case-insensitive
    /// volume both of them exist. Whichever comes first, one row survives.
    @Test(arguments: [["notes.txt", "Notes.txt"], ["Notes.txt", "notes.txt"]])
    func aCaseOnlyRenameKeepsOneRow(order: [String]) throws {
        let f = try Fixture()
        try f.make("notes.txt")
        try f.sources([""])
        let id = try f.id("notes.txt")

        try f.move("notes.txt", "Notes.txt")
        for path in order { try f.events([path]) }

        #expect(try f.indexed == ["", "Notes.txt"])
        #expect(try f.id("Notes.txt") == id)
    }

    @Test func aFolderMovedInFromOutsideIsReadWhole() throws {
        let f = try Fixture()
        try f.sources([""])
        try f.folder.makeFile("Elsewhere/album/one.jpg")
        try f.folder.makeFile("Elsewhere/album/two.jpg")

        try FileManager.default.moveItem(atPath: f.folder.path("Elsewhere/album"), toPath: f.path("album"))
        try f.events(["album"])

        #expect(try f.indexed == ["", "album", "album/one.jpg", "album/two.jpg"])
    }

    @Test func aFolderThatBecomesARepoLeavesAndComesBack() throws {
        let f = try Fixture(rules: FileIndexRules(skipped: [.repos, .bundles], patterns: []))
        try f.make("project/notes.txt")
        try f.sources([""])

        try f.makeFolder("project/.git")
        try f.events(["project/.git"])
        #expect(try f.indexed == [""])

        try f.remove("project/.git")
        try f.events(["project/.git"])
        #expect(try f.indexed == ["", "project", "project/notes.txt"])
    }

    @Test func aFileInsideASkippedFolderStaysOut() throws {
        let f = try Fixture(rules: FileIndexRules(skipped: [.dependencies, .bundles, .hidden],
                                                  patterns: [SkipPattern("Archive/")!]))
        try f.make("node_modules/pkg/index.js")
        try f.make("Tool.app/Contents/Info.plist")
        try f.make(".config/settings.json")
        try f.make("repo/.git/HEAD")
        try f.make("old/Archive/a.txt")
        try f.sources([""])

        try f.make("node_modules/pkg/other.js")
        try f.make("Tool.app/Contents/Resources/x.png")
        try f.make(".config/more.json")
        try f.make("repo/.git/objects/ab")
        try f.make("old/Archive/b.txt")
        try f.events(["node_modules/pkg/other.js", "Tool.app/Contents/Resources/x.png", ".config/more.json",
                      "repo/.git/objects/ab", "old/Archive/b.txt"])

        #expect(try f.indexed == ["", "repo", "old"])
    }

    @Test func aHiddenFileArrivesWhenHiddenFilesAreIncluded() throws {
        let f = try Fixture()
        try f.sources([""])

        try f.make(".config/settings.json")
        try f.make(".DS_Store")
        try f.events([".config", ".config/settings.json", ".DS_Store"])

        #expect(try f.indexed == ["", ".config", ".config/settings.json"])
    }

    @Test func mustScanSubDirsRereadsTheSubtree() throws {
        let f = try Fixture()
        try f.make("dir/a.txt")
        try f.sources([""])

        try f.make("dir/b.txt")
        try f.make("dir/deep/c.txt")
        try f.remove("dir/a.txt")
        try f.events(["dir"], flags: kFSEventStreamEventFlagMustScanSubDirs)

        #expect(try f.indexed == ["", "dir", "dir/b.txt", "dir/deep", "dir/deep/c.txt"])
    }

    @Test func droppedEventsRereadEverySource() throws {
        let f = try Fixture()
        try f.sources([""])

        try f.make("a.txt")
        try f.make("dir/b.txt")
        try f.indexer.handle([FileIndexWatcher.Event(
            path: "/", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
        )])

        #expect(try f.indexed == ["", "a.txt", "dir", "dir/b.txt"])
    }

    @Test func eventsOutsideEverySourceAreIgnored() throws {
        let f = try Fixture()
        try f.sources([""])
        try f.folder.makeFile("Elsewhere/x.txt")

        try f.indexer.handle([FileIndexWatcher.Event(path: f.folder.path("Elsewhere/x.txt"))])

        #expect(try f.indexed == [""])
    }

    // MARK: - Sources

    @Test func removingASourceDeletesItsRows() throws {
        let f = try Fixture()
        try f.make("a.txt")
        try f.make("b/c.txt")
        try f.sources([""])
        #expect(f.reader.counts()[f.root] == 4)

        try f.sources([])

        #expect(try f.indexed.isEmpty)
        #expect(f.reader.counts().isEmpty)
    }

    @Test func removingANestedSourceHandsItsFilesBackToTheOuterOne() throws {
        let f = try Fixture()
        try f.make("Taxes/2024.pdf")
        try f.sources(["", "Taxes"])
        #expect(try f.source(of: "Taxes/2024.pdf") == f.path("Taxes"))

        try f.sources([""])

        #expect(try f.indexed == ["", "Taxes", "Taxes/2024.pdf"])
        #expect(try f.source(of: "Taxes/2024.pdf") == f.root)
    }

    @Test func addingANestedSourceTakesOverItsFiles() throws {
        let f = try Fixture()
        try f.make("Taxes/2024.pdf")
        try f.sources([""])
        let id = try f.id("Taxes/2024.pdf")

        try f.sources(["", "Taxes"])

        #expect(try f.source(of: "Taxes/2024.pdf") == f.path("Taxes"))
        #expect(try f.id("Taxes/2024.pdf") == id)
        #expect(f.reader.counts() == [f.root: 1, f.path("Taxes"): 2])
    }

    @Test func aDisabledSourceKeepsItsRowsButIsNotRead() throws {
        let f = try Fixture()
        try f.make("a.txt")
        try f.sources([""])

        try f.make("b.txt")
        let toCrawl = try f.indexer.setSources([(path: f.root, isEnabled: false)])
        try f.events(["b.txt"])

        #expect(toCrawl.isEmpty)
        #expect(f.indexer.watchedPaths.isEmpty)
        #expect(try f.indexed == ["", "a.txt"])
    }

    @Test func switchingASourceBackOnCatchesUp() throws {
        let f = try Fixture()
        try f.make("a.txt")
        try f.sources([""])
        try f.sources([""], disabled: [""])

        try f.make("b.txt")
        try f.sources([""])

        #expect(try f.indexed == ["", "a.txt", "b.txt"])
    }

    // MARK: - Rules

    @Test func switchingReposOnRemovesThemWithoutACrawlAndOffBringsThemBack() throws {
        let f = try Fixture()
        try f.make("repo/.git/HEAD")
        try f.make("repo/src/main.swift")
        try f.make("notes.txt")
        try f.sources([""])
        #expect(try f.indexed == ["", "notes.txt", "repo", "repo/src", "repo/src/main.swift"])
        let id = try f.id("notes.txt")

        var rules = FileIndexRules.defaults
        rules.skipped.insert(.repos)
        #expect(try f.rules(rules).isEmpty, "skipping more needs no crawl")
        #expect(try f.indexed == ["", "notes.txt"])
        #expect(f.reader.counts() == [f.root: 2])

        #expect(try f.rules(.defaults) == [""])
        #expect(try f.indexed == ["", "notes.txt", "repo", "repo/src", "repo/src/main.swift"])
        #expect(try f.id("notes.txt") == id, "rows nothing changed for are kept")
    }

    @Test func switchingKeysAndEnvFilesOnAndOff() throws {
        let f = try Fixture()
        try f.make("ssh/id_ed25519")
        try f.make("ssh/server.pem")
        try f.make("app/.env.local")
        try f.make("app/main.py")
        try f.sources([""])

        try f.rules(FileIndexRules(skipped: FileIndexRules.defaultSkipped.union([.keys, .envFiles]), patterns: []))
        #expect(try f.indexed == ["", "ssh", "app", "app/main.py"])

        try f.rules(FileIndexRules(skipped: FileIndexRules.defaultSkipped.union([.envFiles]), patterns: []))
        #expect(try f.indexed == ["", "ssh", "ssh/id_ed25519", "ssh/server.pem", "app", "app/main.py"])
    }

    @Test func addingAPatternRemovesWhatItMatchesAndRemovingItBringsThemBack() throws {
        let f = try Fixture()
        try f.make("server.log")
        try f.make("deep/inside/debug.log")
        try f.make("Archive/2019/a.txt")
        try f.make("keep.txt")
        try f.sources([""])

        let patterns = ["*.log", "/Archive/"].compactMap(SkipPattern.init)
        #expect(try f.rules(FileIndexRules(skipped: FileIndexRules.defaultSkipped, patterns: patterns)).isEmpty)
        #expect(try f.indexed == ["", "deep", "deep/inside", "keep.txt"])

        try f.rules(FileIndexRules(skipped: FileIndexRules.defaultSkipped, patterns: [patterns[1]]))
        #expect(try f.indexed == ["", "deep", "deep/inside", "deep/inside/debug.log", "server.log", "keep.txt"])
    }

    @Test func switchingHiddenOnTakesAHiddenFolderWithItsContents() throws {
        let f = try Fixture()
        try f.make(".config/tool/settings.json")
        try f.make("a.txt")
        try f.sources([""])

        var rules = FileIndexRules.defaults
        rules.skipped.insert(.hidden)
        try f.rules(rules)

        #expect(try f.indexed == ["", "a.txt"])
    }

    @Test func switchingBundlesOffWalksIntoPackagesAndOnStopsAtThem() throws {
        let f = try Fixture()
        try f.make("Notes.rtfd/TXT.rtf")
        try f.make("repo/.git/HEAD")
        try f.sources([""])
        #expect(try f.indexed == ["", "Notes.rtfd", "repo"])

        let open = FileIndexRules(skipped: [.caches, .dependencies], patterns: [])
        try f.rules(open)
        #expect(try f.indexed == ["", "Notes.rtfd", "Notes.rtfd/TXT.rtf", "repo", "repo/.git", "repo/.git/HEAD"])

        try f.rules(.defaults)
        #expect(try f.indexed == ["", "Notes.rtfd", "repo"])
    }

    @Test func aRepoThatIsItsOwnSourceSurvivesReposSwitchedOn() throws {
        let f = try Fixture()
        try f.make("repo/.git/HEAD")
        try f.make("repo/README.md")
        try f.make("other/.git/HEAD")
        try f.sources(["", "repo"])

        var rules = FileIndexRules.defaults
        rules.skipped.insert(.repos)
        try f.rules(rules)

        #expect(try f.indexed == ["", "repo", "repo/README.md"])
    }

    @Test func aSourceInsideANewlySkippedFolderStays() throws {
        let f = try Fixture()
        try f.make("Archive/old.txt")
        try f.make("Archive/keep/note.txt")
        try f.sources(["", "Archive/keep"])

        try f.rules(FileIndexRules(skipped: FileIndexRules.defaultSkipped, patterns: [SkipPattern("Archive/")!]))

        #expect(try f.indexed == ["", "Archive/keep", "Archive/keep/note.txt"])
    }

    @Test func aChangeThatSkipsSomeAndIncludesOthersIsOneCrawl() throws {
        let f = try Fixture(rules: FileIndexRules(skipped: FileIndexRules.defaultSkipped.union([.keys]), patterns: []))
        try f.make("id_rsa")
        try f.make("server.log")
        try f.sources([""])
        #expect(try f.indexed == ["", "server.log"])

        let crawled = try f.rules(FileIndexRules(skipped: FileIndexRules.defaultSkipped,
                                                 patterns: [SkipPattern("*.log")!]))

        #expect(crawled == [""])
        #expect(try f.indexed == ["", "id_rsa"])
    }

    @Test func rulesBeforeAnySourcesCrawlNothing() throws {
        let f = try Fixture()
        try f.make("a.txt")

        #expect(try f.rules(FileIndexRules(skipped: [], patterns: [])).isEmpty)
        #expect(try f.indexed.isEmpty)
    }

    @Test func countsFollowTheCrawl() throws {
        let f = try Fixture()
        for index in 0..<(FileIndexer.batchSize + 20) { try f.make("bulk/\(index).txt") }
        var wrote = 0
        var reading: [Bool] = []
        let indexer = FileIndexer(writer: f.writer, onProgress: { progress in
            switch progress {
            case .wrote: wrote += 1
            case .reading(_, let isReading): reading.append(isReading)
            }
        })

        for root in try indexer.setSources([(path: f.root, isEnabled: true)]) { try indexer.crawl(root) }

        #expect(wrote == 2, "one batch mid-crawl, one at the end")
        #expect(reading == [true, false])
        #expect(f.reader.counts()[f.root] == FileIndexer.batchSize + 22)
    }
}
