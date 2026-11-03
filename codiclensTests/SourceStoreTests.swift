import Foundation
import Testing
@testable import codiclens

/// The Sources and their switches, persisted. Each test gets its own
/// `UserDefaults` suite, so nothing reads or writes the app's own.
@MainActor
struct SourceStoreTests {
    private let defaults = ThrowawayDefaults()

    /// The folder Sources wait for Allow in Setup: until then Codiclens
    /// reads no folder, and apps, Clipboard History and Emoji work anyway.
    @Test func aNewInstallHasTheBuiltInSourcesAllOnAndNoFolders() {
        let store = SourceStore(defaults: defaults)

        #expect(store.sources.map(\.kind) == [.applications, .clipboardHistory, .emoji, .builtIns])
        #expect(store.sources.allSatisfy { $0.isEnabled })
    }

    /// An install from before Setup asked about folders has always read the
    /// three default ones, and keeps reading them.
    @Test func anInstallFromBeforeSetupKeepsTheThreeDefaultFolders() {
        let store = SourceStore(defaults: defaults, isFromBeforeSetup: true)

        #expect(store.folders.map(\.kind) == [
            .folder(path: NSHomeDirectory() + "/Downloads"),
            .folder(path: NSHomeDirectory() + "/Documents"),
            .folder(path: NSHomeDirectory() + "/Desktop")
        ])
        #expect(store.folders.allSatisfy { $0.isEnabled })
    }

    /// The first launch writes down that it had no folders, so a later
    /// launch, which finds the File Index that launch created, does not take
    /// itself for an install from before Setup.
    @Test func aNewInstallsEmptyFolderListIsRememberedOnceWrittenDown() {
        SourceStore(defaults: defaults).rememberFolders()

        #expect(SourceStore(defaults: defaults, isFromBeforeSetup: true).folders.isEmpty)
    }

    @Test func folderSourcesSavedAnyWayAreKeptAsTheyAre() {
        let store = SourceStore(defaults: defaults, isFromBeforeSetup: true)
        store.removeFolder(NSHomeDirectory() + "/Desktop")

        #expect(SourceStore(defaults: defaults).folders.compactMap(\.folderPath) == [
            NSHomeDirectory() + "/Downloads", NSHomeDirectory() + "/Documents"
        ])
    }

    /// Whether this Mac's install is from before Setup: Setup was finished,
    /// or there is a File Index on disk.
    @Test func anInstallIsFromBeforeSetupWhenSetupWasFinishedOrAFileIndexExists() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fileIndex = folder.url.appendingPathComponent("FileIndex.sqlite")

        #expect(!SourceStore.isFromBeforeSetup(defaults: defaults, fileIndex: fileIndex))

        try folder.makeFile("FileIndex.sqlite")
        #expect(SourceStore.isFromBeforeSetup(defaults: defaults, fileIndex: fileIndex))

        let finished = ThrowawayDefaults()
        finished.set(true, forKey: Setup.finishedKey)
        #expect(SourceStore.isFromBeforeSetup(defaults: finished, fileIndex: folder.url.appendingPathComponent("none")))
    }

    @Test func severalFoldersAreAddedAsOneChange() {
        let store = SourceStore(defaults: defaults)
        var changes = 0
        store.onFoldersChange = { changes += 1 }

        store.addFolders([
            URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b"), URL(fileURLWithPath: "/tmp/a/")
        ])
        store.addFolders([URL(fileURLWithPath: "/tmp/b")])

        #expect(store.folders.compactMap(\.folderPath) == ["/tmp/a", "/tmp/b"])
        #expect(changes == 1, "nothing new, no change")
        #expect(SourceStore(defaults: defaults).folders.count == 2)
    }

    @Test func addingAndRemovingFoldersIsRemembered() {
        let store = SourceStore(defaults: defaults, isFromBeforeSetup: true)

        #expect(store.addFolder(URL(fileURLWithPath: "/Volumes/Archive/Projects")))
        #expect(!store.addFolder(URL(fileURLWithPath: "/Volumes/Archive/Projects/")), "already a Source")
        store.removeFolder(NSHomeDirectory() + "/Desktop")

        let reopened = SourceStore(defaults: defaults)
        #expect(reopened.folders.compactMap(\.folderPath) == [
            NSHomeDirectory() + "/Downloads", NSHomeDirectory() + "/Documents", "/Volumes/Archive/Projects"
        ])
    }

    @Test func everySourceHasASwitchThatIsRemembered() {
        let store = SourceStore(defaults: defaults, isFromBeforeSetup: true)

        store.setEnabled(false, for: "emoji")
        store.setEnabled(false, for: "folder:" + NSHomeDirectory() + "/Downloads")

        let reopened = SourceStore(defaults: defaults)
        #expect(!reopened.isEnabled(.emoji))
        #expect(!reopened.isEnabled(.folder(path: NSHomeDirectory() + "/Downloads")))
        #expect(reopened.isEnabled(.applications))
    }

    @Test func onlyFolderChangesReachTheFileIndex() {
        let store = SourceStore(defaults: defaults, isFromBeforeSetup: true)
        var changes = 0
        store.onFoldersChange = { changes += 1 }

        store.setEnabled(false, for: "clipboard-history")
        #expect(changes == 0)

        store.setEnabled(false, for: "folder:" + NSHomeDirectory() + "/Documents")
        store.addFolder(URL(fileURLWithPath: "/tmp/elsewhere"))
        store.removeFolder("/tmp/elsewhere")
        store.removeFolder("/not/a/source")
        #expect(changes == 3)
    }

    // MARK: - Skipping

    @Test func aNewInstallSkipsCachesDependenciesBundlesAndWorktrees() {
        let store = SourceStore(defaults: defaults)

        #expect(store.fileIndexRules == .defaults)
    }

    @Test func skipSwitchesAndPatternsAreRemembered() {
        let store = SourceStore(defaults: defaults)

        store.setSkipped(true, .repos)
        store.setSkipped(false, .caches)
        #expect(store.addSkipPattern("*.log"))
        #expect(store.addSkipPattern("  Archive/ "))
        #expect(store.addSkipPattern("**/fixtures/**"))
        store.removeSkipPattern(SkipPattern("Archive/")!)

        let reopened = SourceStore(defaults: defaults)
        #expect(reopened.fileIndexRules.skipped == [.dependencies, .bundles, .repos, .worktrees, .gitIgnored])
        #expect(reopened.fileIndexRules.patterns.map(\.text) == ["*.log", "**/fixtures/**"])
    }

    @Test func everySwitchOffIsRememberedAsOff() {
        let store = SourceStore(defaults: defaults)
        for group in FileIndexRules.SkipGroup.allCases { store.setSkipped(false, group) }

        #expect(SourceStore(defaults: defaults).fileIndexRules.skipped.isEmpty)
    }

    @Test func blankAndDuplicatePatternsAreIgnored() {
        let store = SourceStore(defaults: defaults)

        #expect(store.addSkipPattern("*.log"))
        #expect(!store.addSkipPattern(""))
        #expect(!store.addSkipPattern("  "))
        #expect(!store.addSkipPattern("/"))
        #expect(!store.addSkipPattern("*.log"))
        #expect(!store.addSkipPattern("*.LOG "), "the same pattern, spelled otherwise")
        #expect(!store.canAddSkipPattern("*.log"))
        #expect(store.canAddSkipPattern("*.tmp"))
        #expect(store.fileIndexRules.patterns.map(\.text) == ["*.log"])
    }

    @Test func onlyRuleChangesReachTheFileIndexAsRules() {
        let store = SourceStore(defaults: defaults)
        var rules = 0
        var folders = 0
        store.onRulesChange = { rules += 1 }
        store.onFoldersChange = { folders += 1 }

        store.setSkipped(true, .caches)
        store.setSkipped(true, .keys)
        store.addSkipPattern("*.log")
        store.addSkipPattern("*.log")
        store.removeSkipPattern(SkipPattern("*.log")!)
        store.removeSkipPattern(SkipPattern("*.tmp")!)

        #expect(rules == 3, "an already-on switch, a duplicate and an absent pattern change nothing")
        #expect(folders == 0)
    }
}
