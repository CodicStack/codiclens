import Foundation
import Testing
@testable import codiclens

/// The Sources page's rows and controls, against a `SourceStore` on its own
/// `UserDefaults` suite and counts handed in by the test.
@MainActor
struct SourcesPageTests {
    private let store = SourceStore(defaults: UserDefaults(suiteName: "codiclens-tests-\(UUID().uuidString)")!)
    private let downloads = NSHomeDirectory() + "/Downloads"

    private func page(
        counts: @escaping (Source) -> SourceCounts? = { _ in nil },
        reading: Set<Source.ID> = []
    ) -> SourcesPage {
        SourcesPage(store: store, counts: counts, isReading: { reading.contains($0.id) })
    }

    @Test func theBuiltInSourcesAndTheFoldersAreListedApart() {
        let page = page()

        #expect(page.builtInRows.map(\.name) == ["Applications", "Clipboard History", "Emoji", "Built-ins"])
        #expect(page.builtInRows.map(\.isRemovable) == [false, false, false, false])
        #expect(page.builtInRows.map(\.location) == [nil, nil, nil, nil])
        #expect(page.folderRows.map(\.location) == ["~/Downloads", "~/Documents", "~/Desktop"])
        #expect(page.folderRows.map(\.isRemovable) == [true, true, true])
    }

    @Test func aRowCarriesItsCountsAndWhetherItIsBeingRead() {
        let page = page(
            counts: { source in
                switch source.kind {
                case .emoji: .whole(1914)
                case .folder(let path) where path == downloads: SourceCounts(indexed: 40, total: 120)
                default: nil
                }
            },
            reading: ["folder:" + downloads]
        )

        #expect(page.builtInRows.first { $0.id == "emoji" }?.counts == SourceCounts(indexed: 1914, total: 1914))
        #expect(page.builtInRows.first { $0.id == "applications" }?.counts == nil, "not counted yet")

        let downloadsRow = page.folderRows.first { $0.source.folderPath == downloads }
        #expect(downloadsRow?.counts == SourceCounts(indexed: 40, total: 120))
        #expect(downloadsRow?.isReading == true)
        #expect(page.folderRows.filter(\.isReading).count == 1)
    }

    @Test func aSwitchTurnsTheSourceOffInTheStore() throws {
        let page = page()
        let clipboard = try #require(page.builtInRows.first { $0.id == "clipboard-history" })

        page.setEnabled(false, for: clipboard)

        #expect(!store.isEnabled(.clipboardHistory))
        #expect(page.builtInRows.first { $0.id == "clipboard-history" }?.isEnabled == false)
    }

    @Test func severalFoldersAreAddedAtOnceAndADuplicateIsIgnored() {
        let page = page()

        page.addFolders([
            URL(fileURLWithPath: "/Volumes/Archive/Projects"),
            URL(fileURLWithPath: downloads),
            URL(fileURLWithPath: "/tmp/notes")
        ])

        #expect(page.folderRows.compactMap(\.source.folderPath) == [
            downloads, NSHomeDirectory() + "/Documents", NSHomeDirectory() + "/Desktop",
            "/Volumes/Archive/Projects", "/tmp/notes"
        ])
        #expect(!page.folderRows.map(\.isEnabled).contains(false))
    }

    @Test func removingAFolderTakesOnlyThatRow() throws {
        let page = page()
        let row = try #require(page.folderRows.first { $0.source.folderPath == downloads })

        page.remove(row)

        #expect(!page.folderRows.contains { $0.source.folderPath == downloads })
        #expect(page.folderRows.count == 2)
        #expect(page.builtInRows.count == 4)
    }

    @Test func aBuiltInSourceCannotBeRemoved() throws {
        let page = page()
        let emoji = try #require(page.builtInRows.first { $0.id == "emoji" })

        page.remove(emoji)

        #expect(page.builtInRows.count == 4)
    }

    // MARK: - Skipping

    @Test func theSkipSwitchesAreListedInOrderWithTheDefaultsOn() {
        let page = page()

        #expect(page.skipRows.map(\.title) == [
            "Caches", "node_modules and build output", "App bundles and packages", "Hidden files and folders",
            "Repos", ".env files", "Keys and certificates"
        ])
        #expect(page.skipRows.map(\.isSkipped) == [true, true, true, false, false, false, false])
        #expect(page.skipRows.allSatisfy { !$0.detail.isEmpty && !$0.detail.contains("\u{2014}") })
    }

    @Test func aSkipSwitchChangesTheRules() throws {
        let page = page()
        let repos = try #require(page.skipRows.first { $0.group == .repos })

        page.setSkipped(true, for: repos)

        #expect(store.fileIndexRules.skips(.repos))
        #expect(page.skipRows.first { $0.group == .repos }?.isSkipped == true)
    }

    @Test func patternsAreAddedAndRemoved() {
        let page = page()

        #expect(!page.canAddSkipPattern(" "))
        #expect(page.canAddSkipPattern("*.log"))
        #expect(page.addSkipPattern("*.log"))
        #expect(page.addSkipPattern("Archive/"))
        #expect(!page.canAddSkipPattern("*.log"))
        #expect(page.skipPatterns.map(\.text) == ["*.log", "Archive/"])

        page.removeSkipPattern(page.skipPatterns[0])

        #expect(page.skipPatterns.map(\.text) == ["Archive/"])
    }
}
