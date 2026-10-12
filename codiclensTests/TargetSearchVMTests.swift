import AppKit
import Testing
@testable import codiclens

@MainActor
struct TargetSearchVMTests {

    /// Finder file search debounces its query. Moving from a promoted file to
    /// Share must revoke that queued work before sharing services take over.
    @Test func queuedFileSearchCannotClearShareTargets() async throws {
        let service = NSSharingService(
            title: "Test Recipient",
            image: NSImage(),
            alternateImage: nil
        ) {}
        let shareTarget = ActionTarget(
            name: "Test Recipient",
            icon: NSImage(),
            url: nil,
            sharingService: service
        )
        let viewModel = TargetSearchVM(shareTargetProvider: { _ in [shareTarget] }, searchFiles: { _ in [] })
        let finder = Subject(
            displayName: "Finder",
            path: "/System/Library/CoreServices/Finder.app",
            url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
            icon: NSImage(),
            kind: .app(bundleIdentifier: "com.apple.finder", isRunning: true)
        )
        let useAsSubject = SubjectAction(
            name: "Use as Subject",
            icon: .sfSymbol("arrow.turn.up.left"),
            isFinal: false,
            handler: .useAsSubject
        )

        viewModel.loadTargets(for: finder, action: useAsSubject)
        viewModel.searchText = "note"
        viewModel.loadShareTargets(for: .text("hello"))

        try await Task.sleep(for: .milliseconds(250))

        #expect(viewModel.filteredTargets.map(\.name) == ["Test Recipient"])
        #expect(!viewModel.isSearching)
    }
}
