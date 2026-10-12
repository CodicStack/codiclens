import AppKit
import Foundation
import Testing
@testable import codiclens

/// Finder's Target list, with `/bin/sh` standing in for `mdfind` so nothing
/// here depends on the Spotlight index. A test that hangs has failed: every
/// stand-in that would outlive a broken cap or cancel runs for minutes, and
/// the time limit catches it.
@Suite(.timeLimit(.minutes(1)))
struct FileTargetSearchTests {

    /// A launcher that runs `script` under `/bin/sh` for every scope, with
    /// the scope's name as `$1`.
    private static func shell(_ script: String) -> FileTargetSearch.Launcher {
        { _, scope in
            (URL(fileURLWithPath: "/bin/sh"),
             ["-c", script, "sh", scope == .priorityFolders ? "priority" : "system-wide"])
        }
    }

    /// Never prints, never exits on its own.
    private static let neverAnswers = shell("exec sleep 600")

    /// A File Index with nothing in it, for the tests about `mdfind`.
    private static let noIndex: FileIndex.Search = { _ in [] }

    @Test func lookupStopsAtItsLineCap() {
        let search = FileTargetSearch(query: "x", searchFiles: Self.noIndex, launcher: Self.shell("exec yes /tmp/endless"))

        #expect(search.lookup(.systemWide).count == FileTargetSearch.Scope.systemWide.lineCap)
        #expect(search.lookup(.priorityFolders).count == FileTargetSearch.Scope.priorityFolders.lineCap)
    }

    @Test func lookupSkipsAppsAndBlankLinesAndKeepsAnUnterminatedLastLine() {
        let search = FileTargetSearch(
            query: "x",
            searchFiles: Self.noIndex,
            launcher: Self.shell(#"printf '/a/one.txt\n\n/Applications/Notes.app\n/a/two.txt'"#)
        )

        #expect(search.lookup(.systemWide) == ["/a/one.txt", "/a/two.txt"])
    }

    /// Each lookup prints what the other sent it through a FIFO. Opening a
    /// FIFO blocks until its other end is open, so run one after the other
    /// they would wait on each other forever.
    @Test func bothLookupsRunAtTheSameTime() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let toSystemWide = directory.appendingPathComponent("to-system-wide").path
        let toPriority = directory.appendingPathComponent("to-priority").path
        #expect(mkfifo(toSystemWide, 0o600) == 0)
        #expect(mkfifo(toPriority, 0o600) == 0)

        let search = FileTargetSearch(query: "x", searchFiles: Self.noIndex) { _, scope in
            let script = scope == .priorityFolders
                ? #"echo /from/priority > "$1"; cat "$2""#
                : #"cat "$1"; echo /from/system-wide > "$2""#
            return (URL(fileURLWithPath: "/bin/sh"), ["-c", script, "sh", toSystemWide, toPriority])
        }

        #expect(search.candidatePaths() == ["/from/system-wide", "/from/priority"])
    }

    @Test func priorityFolderPathsComeFirstAndOnlyOnce() {
        let inDownloads = FileTargetSearch.priorityFolders[0] + "old notes.txt"
        let search = FileTargetSearch(query: "notes", searchFiles: Self.noIndex) { _, scope in
            let paths = scope == .priorityFolders
                ? [inDownloads]
                : ["/Volumes/Archive/notes", inDownloads]
            return (URL(fileURLWithPath: "/usr/bin/printf"), ["%s\\n"] + paths)
        }

        let candidates = search.candidatePaths()
        #expect(candidates == [inDownloads, "/Volumes/Archive/notes"])

        // An exact match elsewhere still ranks below a weaker one in a
        // priority folder.
        #expect(FileTargetSearch.rank(Array(candidates.reversed()), query: "notes")
                == [inDownloads, "/Volumes/Archive/notes"])
    }

    @Test func rankingKeepsTheBestFifty() {
        let paths = (0..<80).map { "/elsewhere/report \($0).pdf" } + ["/elsewhere/report"]

        let ranked = FileTargetSearch.rank(paths, query: "report")

        #expect(ranked.count == FileTargetSearch.resultLimit)
        #expect(ranked.first == "/elsewhere/report")
    }

    @Test func cancellingARunningSearchStopsItsLookups() async {
        let search = FileTargetSearch(query: "x", searchFiles: Self.noIndex, launcher: Self.neverAnswers)

        async let answered = Task.detached { search.run() == nil }.value
        search.cancel()

        #expect(await answered)
        #expect(search.isCancelled)
    }

    /// The File Index answers first and its Targets come first; Spotlight's
    /// follow, without a path the index already gave, and an app from either
    /// is left to the Subject list.
    @Test func fileIndexTargetsComeFirstAndSpotlightAddsOnlyWhatTheyLack() {
        let hits = ["/indexed/notes.txt", "/indexed/notes.app"].map { path in
            let url = URL(fileURLWithPath: path)
            return FileHit(url: url, name: url.lastPathComponent, folder: "/indexed", kind: .file, score: 1)
        }
        let search = FileTargetSearch(query: "notes", searchFiles: { _ in hits }) { _, scope in
            let paths = scope == .priorityFolders
                ? ["/indexed/notes.txt"]
                : ["/elsewhere/notes.md", "/indexed/notes.txt", "/elsewhere/Notes.app"]
            return (URL(fileURLWithPath: "/usr/bin/printf"), ["%s\\n"] + paths)
        }

        let indexed = search.indexTargets()
        #expect(indexed.map(\.url?.path) == ["/indexed/notes.txt"])
        #expect(indexed.first?.subtitle == "/indexed")

        let rest = search.spotlightTargets(excluding: indexed)
        #expect(rest?.map(\.url?.path) == ["/elsewhere/notes.md"])

        #expect(search.run()?.map(\.url?.path) == ["/indexed/notes.txt", "/elsewhere/notes.md"])
    }

    @Test func aCancelledSearchLaunchesNothing() {
        let search = FileTargetSearch(query: "x", searchFiles: Self.noIndex, launcher: Self.neverAnswers)
        search.cancel()

        #expect(search.run() == nil)
    }
}

@MainActor
struct TargetSearchVMFileSearchTests {
    private let finder = Subject(
        displayName: "Finder",
        path: "/System/Library/CoreServices/Finder.app",
        url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
        icon: NSImage(),
        kind: .app(bundleIdentifier: "com.apple.finder", isRunning: true)
    )
    private let openFile = SubjectAction(
        name: "Open File",
        icon: .sfSymbol("doc"),
        isFinal: false,
        handler: .openFile
    )

    /// The bug this replaces: the view model kept a `Process` it never
    /// assigned, so every keystroke left the last `mdfind` running.
    @Test func aNewerQueryAndLeavingFileSearchCancelTheSearchInFlight() throws {
        let viewModel = TargetSearchVM(
            shareTargetProvider: { _ in [] },
            searchFiles: { _ in [] },
            fileSearchLauncher: { _, _ in (URL(fileURLWithPath: "/bin/sleep"), ["600"]) }
        )
        viewModel.loadTargets(for: finder, action: openFile)

        viewModel.searchText = "first"
        viewModel.performFileSearch("first")
        let first = try #require(viewModel.fileSearch)
        #expect(viewModel.isSearching)

        viewModel.searchText = "second"
        #expect(first.isCancelled)
        #expect(viewModel.isSearching)

        viewModel.performFileSearch("second")
        let second = try #require(viewModel.fileSearch)
        #expect(!second.isCancelled)

        viewModel.reset()
        #expect(second.isCancelled)
        #expect(viewModel.fileSearch == nil)
        #expect(!viewModel.isSearching)
    }
}
