import Foundation
import Testing
@testable import codiclens

/// The Sources and their switches, persisted. Each test gets its own
/// `UserDefaults` suite, so nothing reads or writes the app's own.
@MainActor
struct SourceStoreTests {
    private let defaults = ThrowawayDefaults()

    @Test func aNewInstallHasTheBuiltInSourcesAndThreeFoldersAllOn() {
        let store = SourceStore(defaults: defaults)

        #expect(store.sources.map(\.kind) == [
            .applications, .clipboardHistory, .emoji, .builtIns,
            .folder(path: NSHomeDirectory() + "/Downloads"),
            .folder(path: NSHomeDirectory() + "/Documents"),
            .folder(path: NSHomeDirectory() + "/Desktop")
        ])
        #expect(store.sources.allSatisfy { $0.isEnabled })
    }

    @Test func addingAndRemovingFoldersIsRemembered() {
        let store = SourceStore(defaults: defaults)

        #expect(store.addFolder(URL(fileURLWithPath: "/Volumes/Archive/Projects")))
        #expect(!store.addFolder(URL(fileURLWithPath: "/Volumes/Archive/Projects/")), "already a Source")
        store.removeFolder(NSHomeDirectory() + "/Desktop")

        let reopened = SourceStore(defaults: defaults)
        #expect(reopened.folders.compactMap(\.folderPath) == [
            NSHomeDirectory() + "/Downloads", NSHomeDirectory() + "/Documents", "/Volumes/Archive/Projects"
        ])
    }

    @Test func everySourceHasASwitchThatIsRemembered() {
        let store = SourceStore(defaults: defaults)

        store.setEnabled(false, for: "emoji")
        store.setEnabled(false, for: "folder:" + NSHomeDirectory() + "/Downloads")

        let reopened = SourceStore(defaults: defaults)
        #expect(!reopened.isEnabled(.emoji))
        #expect(!reopened.isEnabled(.folder(path: NSHomeDirectory() + "/Downloads")))
        #expect(reopened.isEnabled(.applications))
    }

    @Test func onlyFolderChangesReachTheFileIndex() {
        let store = SourceStore(defaults: defaults)
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
        #expect(reopened.fileIndexRules.skipped == [.dependencies, .bundles, .repos, .worktrees])
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
