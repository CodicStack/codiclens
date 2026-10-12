import AppKit
import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import codiclens

/// The Subject Card in Subject search is always there and never blank between
/// a keystroke and its answer: it shows what is highlighted, and while the
/// Query has not been answered yet it goes on showing what it showed last.
/// "No match" is said only once the Query has been answered with nothing.
///
/// Nothing runs on a clock: the searches and the pause are held by a
/// `HeldSearchSchedule`, as in `SubjectSourceListTests`.
@MainActor
struct SubjectCardHoldTests {

    /// Word answers on the keystroke and settled answers after the pause,
    /// each per Query; anything not listed answers nothing.
    final class FakeFiles: Sendable {
        private let state: Mutex<(words: [String: [FileHit]], settled: [String: [FileHit]])>

        init(words: [String: [FileHit]] = [:], settled: [String: [FileHit]] = [:]) {
            state = Mutex((words, settled))
        }

        var search: FileIndex.Search {
            { [self] query in state.withLock { $0.words[query] ?? [] } }
        }

        var searchSettled: FileIndex.SettledSearch {
            { [self] query in state.withLock { $0.settled[query] ?? [] } }
        }
    }

    private struct Fixture {
        let coordinator: CommandCoordinator
        let schedule: HeldSearchSchedule
        let index: AppIndex
        let root: URL

        var vm: SubjectSearchVM { coordinator.subjectVM }

        func type(_ query: String) {
            coordinator.acceptTypedText(query)
        }

        func tearDown() {
            index.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A coordinator over an Index holding the apps named, so a Query can be
    /// answered, and over `files` for the list below the apps. Clipboard and
    /// Emoji are off, so the list is the files alone.
    private func makeFixture(
        apps: [String],
        files: FakeFiles,
        history: ClipboardHistory? = nil
    ) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-card-hold-\(UUID().uuidString)")
        for app in apps {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("\(app).app"),
                withIntermediateDirectories: true
            )
        }
        let index = AppIndex(directories: [root.path])
        index.refresh()
        await withCheckedContinuation { continuation in
            index.onFirstPopulation { continuation.resume() }
        }
        let sources = SourceStore(defaults: ThrowawayDefaults())
        for kind in [Source.Kind.emoji, .clipboardHistory, .builtIns] {
            sources.setEnabled(false, for: Source(kind: kind, isEnabled: true).id)
        }
        let schedule = HeldSearchSchedule()
        let coordinator = CommandCoordinator.isolated(
            history: history,
            index: index,
            sources: sources,
            searchFiles: files.search,
            searchSettled: files.searchSettled,
            searchSchedule: schedule
        )
        return Fixture(coordinator: coordinator, schedule: schedule, index: index, root: root)
    }

    private func doc(_ name: String) -> FileHit {
        let url = URL(fileURLWithPath: "/docs/" + name)
        return FileHit(url: url, name: name, folder: "/docs", kind: .file, score: 0)
    }

    /// What the Subject Card says: the name of the Subject it shows, or its
    /// placeholder, as `SubjectCardView` words it.
    private func card(_ coordinator: CommandCoordinator) -> String {
        let vm = coordinator.subjectVM
        if let subject = coordinator.standingSubject ?? vm.cardSubject { return subject.displayName }
        if vm.searchText.isEmpty { return "Type..." }
        return vm.hasAnswered ? "No match" : "Searching…"
    }

    /// The Card's state at one step, checked in full: what it shows, that the
    /// row holds exactly the one Card, and whether the Panel shakes.
    private func expectCard(
        _ fixture: Fixture,
        shows expected: String,
        noMatch: Bool = false,
        _ step: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(card(fixture.coordinator) == expected, "\(step)", sourceLocation: sourceLocation)
        #expect(fixture.coordinator.cardCount == 1, "\(step): one Card", sourceLocation: sourceLocation)
        #expect(fixture.coordinator.hasNoSubjectMatch == noMatch, "\(step): shakes", sourceLocation: sourceLocation)
    }

    // MARK: - Typing

    /// An app that matches every prefix: the Card is on it from the first
    /// key, and the list landing later below it changes nothing.
    @Test func anAppMatchingEveryPrefixStaysOnTheCard() async throws {
        let fixture = try await makeFixture(
            apps: ["Notes"],
            files: FakeFiles(words: ["note": [doc("note to self.txt")]], settled: ["note": [doc("note to self.txt")]])
        )
        defer { fixture.tearDown() }

        for query in ["n", "no", "not", "note"] {
            fixture.type(query)
            expectCard(fixture, shows: "Notes", "typed \(query)")
            await fixture.schedule.runSearches()
            expectCard(fixture, shows: "Notes", "\(query)'s words landed")
        }
        await fixture.schedule.typingPaused()
        expectCard(fixture, shows: "Notes", "note settled")
    }

    /// A file found only by what it says: its prefix finds nothing on the
    /// keystroke and the settled pass finds it. The Card keeps it through
    /// the keystroke's empty answer and never says "No match" on the way.
    @Test func theCardHoldsItsSubjectWhileTheSettledPassIsOut() async throws {
        let report = doc("q3 report.pdf")
        let fixture = try await makeFixture(
            apps: ["Notes"],
            files: FakeFiles(settled: ["bud": [report], "budg": [report]])
        )
        defer { fixture.tearDown() }

        fixture.type("bud")
        expectCard(fixture, shows: "Searching…", "bud typed, nothing shown before")
        await fixture.schedule.runSearches()
        expectCard(fixture, shows: "Searching…", "bud's words found nothing, the pause has not come")
        await fixture.schedule.typingPaused()
        expectCard(fixture, shows: "q3 report.pdf", "bud settled")

        fixture.type("budg")
        expectCard(fixture, shows: "q3 report.pdf", "budg typed")
        await fixture.schedule.runSearches()
        expectCard(fixture, shows: "q3 report.pdf", "budg's words found nothing")
        try renderPanel(fixture.coordinator, to: "/tmp/codiclens-card-gap.png")
        await fixture.schedule.typingPaused()
        expectCard(fixture, shows: "q3 report.pdf", "budg settled")
    }

    /// A Query answered with nothing, words and settled pass alike, says
    /// "No match" — on the Card, which is still there — and shakes once.
    @Test func aQueryAnsweredWithNothingSaysNoMatchOnTheCard() async throws {
        let report = doc("q3 report.pdf")
        let fixture = try await makeFixture(apps: ["Notes"], files: FakeFiles(settled: ["bud": [report]]))
        defer { fixture.tearDown() }

        fixture.type("bud")
        await fixture.schedule.typingPaused()
        expectCard(fixture, shows: "q3 report.pdf", "bud settled")

        fixture.type("budzq")
        await fixture.schedule.runSearches()
        expectCard(fixture, shows: "q3 report.pdf", "budzq's words found nothing, the settled pass is out")
        #expect(!fixture.coordinator.canReportNoResults)

        await fixture.schedule.typingPaused()
        expectCard(fixture, shows: "No match", noMatch: true, "budzq settled with nothing")
        #expect(fixture.coordinator.canReportNoResults)
    }

    /// Clearing the Query is not a pending answer: the Card goes back to
    /// asking, and holds nothing over.
    @Test func clearingTheQueryHoldsNothingOver() async throws {
        let fixture = try await makeFixture(apps: ["Notes"], files: FakeFiles())
        defer { fixture.tearDown() }

        fixture.type("no")
        expectCard(fixture, shows: "Notes", "no typed")
        fixture.type("")
        expectCard(fixture, shows: "Type...", "cleared")
    }

    // MARK: - From the empty Panel

    /// The Panel opened with nothing typed and no Last Subject: the one Card,
    /// asking.
    @Test func theEmptyPanelShowsTheCard() async throws {
        let fixture = try await makeFixture(apps: ["FindMy"], files: FakeFiles())
        defer { fixture.tearDown() }

        fixture.coordinator.reset()
        #expect(fixture.coordinator.standingSubject == nil)
        expectCard(fixture, shows: "Type...", "opened empty")
    }

    /// Typing into the empty Panel: the apps answer on the keystroke, so the
    /// highlighted app is on the Card from the first key, while the list
    /// below them is still out and before the settled pass. The row stays
    /// one Card throughout, so nothing on typing is an Arrival.
    @Test func typingIntoTheEmptyPanelPutsTheHighlightedAppOnTheCard() async throws {
        let fixture = try await makeFixture(
            apps: ["FindMy", "Finder", "USB File Manager", "Microsoft PowerPoint"],
            files: FakeFiles(settled: ["fin": [doc("final-final.mp4")]])
        )
        defer { fixture.tearDown() }
        fixture.coordinator.reset()
        expectCard(fixture, shows: "Type...", "opened empty")

        for query in ["f", "fi", "fin"] {
            fixture.type(query)
            #expect(fixture.vm.searchText == query)
            #expect(fixture.vm.results.first?.displayName == "FindMy", "\(query): the top row")
            expectCard(fixture, shows: "FindMy", "typed \(query)")
        }
        try renderPanel(fixture.coordinator, to: "/tmp/codiclens-card-fresh.png")

        await fixture.schedule.typingPaused()
        expectCard(fixture, shows: "FindMy", "fin settled")
        #expect(fixture.vm.results.map(\.displayName).contains("final-final.mp4"))
    }

    /// Each Card's glass is on one view that stays, never on a `Group`: a
    /// `Group` gives the glass to each branch inside it, so a content change
    /// inside an animation took the whole Card away for its length
    /// (`SubjectCardView.body`). Only the window server shows that, so this
    /// pins the shape that caused it.
    @Test func noCardsGlassIsOnAGroup() {
        for body in [
            String(reflecting: SubjectCardView.Body.self),
            String(reflecting: ActionCardView.Body.self),
            String(reflecting: TargetCardView.Body.self)
        ] {
            #expect(!body.contains("SwiftUI.Group<"), "\(body.prefix(120))")
        }
    }

    // MARK: - Selection

    /// The Card is on the highlighted row: into the list by hand, through the
    /// list re-ranking under the same Query, and pinned first under the next.
    @Test func theCardFollowsTheSelectionIntoTheListAndThroughAReRank() async throws {
        let fixture = try await makeFixture(
            apps: ["Notes"],
            files: FakeFiles(
                words: ["no": [doc("nordic.txt"), doc("north.txt")], "nor": [doc("north.txt")]],
                settled: ["no": [doc("north.txt"), doc("nordic.txt")], "nor": [doc("north.txt")]]
            )
        )
        defer { fixture.tearDown() }

        fixture.type("no")
        await fixture.schedule.runSearches()
        expectCard(fixture, shows: "Notes", "no's words landed")
        fixture.coordinator.moveDown()
        fixture.coordinator.moveDown()
        expectCard(fixture, shows: "north.txt", "moved into the list")

        await fixture.schedule.typingPaused()
        #expect(fixture.vm.selectedIndex == 1, "re-ranked under it")
        expectCard(fixture, shows: "north.txt", "no settled")

        fixture.type("nor")
        expectCard(fixture, shows: "north.txt", "nor typed: pinned first")
        await fixture.schedule.typingPaused()
        expectCard(fixture, shows: "north.txt", "nor settled")
        #expect(fixture.vm.selectedIndex == 0)
    }

    // MARK: - What else stands on the Card

    /// A standing Last Subject is what the Card showed, so the first
    /// keystroke keeps it there until the new Query has something to show,
    /// and a Query answered with nothing says "No match".
    @Test func aStandingLastSubjectStaysUntilTheNewQueryAnswers() async throws {
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        history.recordText("hello")
        let fixture = try await makeFixture(apps: ["Notes"], files: FakeFiles(), history: history)
        defer { fixture.tearDown() }
        fixture.coordinator.phase = .browsingClipboard
        fixture.coordinator.clipboardVM.load()
        fixture.coordinator.submit()
        fixture.coordinator.reset()
        let standing = try #require(fixture.coordinator.standingSubject)

        fixture.type("z")
        #expect(fixture.coordinator.standingSubject == nil, "typing ended it standing")
        expectCard(fixture, shows: standing.displayName, "z typed")
        await fixture.schedule.runSearches()
        expectCard(fixture, shows: standing.displayName, "z's words found nothing")
        await fixture.schedule.typingPaused()
        expectCard(fixture, shows: "No match", noMatch: true, "z settled with nothing")
    }

    /// ⌘E stands the Query as text, and the Card shows the text.
    @Test func aQueryStandingAsTextIsOnTheCard() async throws {
        let fixture = try await makeFixture(apps: ["Notes"], files: FakeFiles())
        defer { fixture.tearDown() }

        fixture.type("budget notes")
        fixture.coordinator.toggleTextSubjectEdit()
        fixture.coordinator.toggleTextSubjectEdit()
        #expect(fixture.coordinator.isTextMode)
        guard case .text(let text)? = fixture.vm.cardSubject?.kind else {
            Issue.record("the Card is not on the text")
            return
        }
        #expect(text == "budget notes")
        #expect(fixture.coordinator.cardCount == 1)
    }

    // MARK: - The picture

    /// The Panel's Card row and Results Slab as `PanelView` lays them out,
    /// without its entrance or the Slab's surface: the entrance's blur, even
    /// at zero, and the Slab's shadow each leave `cacheDisplay` with nothing
    /// of what is under them.
    private struct PanelContent: View {
        let coordinator: CommandCoordinator

        var body: some View {
            GlassEffectContainer(spacing: Style.glassMergeDistance) {
                VStack(spacing: Style.gap) {
                    CardContainerView(coordinator: coordinator, previewDriver: PassagePreviewDriver())
                        .frame(width: PanelLayout.cardRowWidth(coordinator.cardCount), height: PanelLayout.cardHeight)
                    ResultsListView(coordinator: coordinator)
                        .frame(width: PanelLayout.slabWidth(coordinator.cardCount))
                }
            }
            .frame(width: PanelLayout.contentWidth, height: PanelLayout.contentHeight, alignment: .top)
            .padding(PanelLayout.margin)
        }
    }

    /// Drawn offscreen, content layer only (see `SubjectCardPictureTests.render`),
    /// on a mid grey in dark appearance — the content alone is light glyphs and
    /// faint quaternary text — and written out to be looked at.
    private func renderPanel(_ coordinator: CommandCoordinator, to path: String) throws {
        let host = NSHostingView(rootView: PanelContent(coordinator: coordinator)
            .background(Color(white: 0.3))
            .environment(\.colorScheme, .dark)
            .environment(\.displayScale, 2))
        host.frame = NSRect(x: 0, y: 0, width: PanelLayout.panelWidth, height: PanelLayout.panelHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }
}
