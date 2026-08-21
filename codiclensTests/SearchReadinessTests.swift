import AppKit
import Testing
@testable import codiclens

/// When a Mode is entitled to say "No results", and when it is still waiting.
///
/// The defect: a Subject search run before the app Index had finished its first
/// scan matched nothing — because there was nothing to match against — and the
/// Slab said "No results" for a question it had not been able to ask. Then the
/// Index landed and Results appeared. Two separate things produced that, and
/// both are covered here: the Index having no answer yet, and the 600ms
/// debounce that used to withhold the answer once it did.
@MainActor
struct SearchReadinessTests {

    private func makeCoordinator(index: AppIndex) -> CommandCoordinator {
        CommandCoordinator(
            runner: RecordingEffectRunner(),
            history: ClipboardHistory(store: InMemoryClipboardStore()),
            index: index
        )
    }

    /// An Index that has actually scanned something.
    ///
    /// A directory holding one `.app` is all the scan looks for, and
    /// `onFirstPopulation` is the event that says it landed — so the wait is the
    /// Index's own signal rather than a guess at how long a scan takes.
    private func populatedIndex() async throws -> (AppIndex, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Fixture.app"),
            withIntermediateDirectories: true
        )

        let index = AppIndex(directories: [root.path])
        index.refresh()
        await withCheckedContinuation { continuation in
            index.onFirstPopulation { continuation.resume() }
        }

        #expect(index.hasPopulated)
        return (index, root)
    }

    // MARK: - Before the Index has answered

    /// The whole defect, at the view model: a Query the Index could not be
    /// consulted about produces neither a "No results" claim nor a text Subject
    /// standing in for the app that was never looked for.
    @Test func aQueryPutBeforeTheIndexLandsIsNotAnsweredAtAll() {
        let coordinator = makeCoordinator(index: inertAppIndex)

        coordinator.subjectVM.searchText = "zzqqzz"

        #expect(!coordinator.subjectVM.isIndexReady)
        #expect(coordinator.subjectVM.results.isEmpty, "no Results, and no invented one")
        #expect(!coordinator.isTextMode, "the Query is not text just because nothing was found")
        #expect(!coordinator.canReportNoResults, "nothing may say No results yet")
        #expect(!coordinator.hasNoSubjectMatch, "and nothing may shake about it")
    }

    /// The Built-ins are not in the Index, so they match at once — a cold start
    /// still finds Clipboard, Emoji and Settings.
    @Test func builtInsMatchBeforeTheIndexLands() {
        let coordinator = makeCoordinator(index: inertAppIndex)

        coordinator.subjectVM.searchText = "clip"

        #expect(coordinator.subjectVM.results.map(\.displayName) == ["Clipboard"])
        #expect(!coordinator.canReportNoResults, "an app could still turn up")
    }

    // MARK: - Once it has

    /// The other half: with the Index in, zero matches is an answer. The message
    /// is allowed, the Query stands as text, and the Panel is entitled to shake.
    @Test func aQueryPutAfterTheIndexLandsIsAnswered() async throws {
        let (index, root) = try await populatedIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = makeCoordinator(index: index)

        coordinator.subjectVM.searchText = "zzqqzz"

        #expect(coordinator.subjectVM.isIndexReady)
        #expect(coordinator.canReportNoResults)
        #expect(coordinator.isTextMode, "nothing matched, so the Query is text")
        #expect(coordinator.hasNoSubjectMatch)
        index.stop()
    }

    /// And a Query that matches an indexed app finds it.
    @Test func anIndexedAppIsFoundOnceTheScanHasLanded() async throws {
        let (index, root) = try await populatedIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = makeCoordinator(index: index)

        coordinator.subjectVM.searchText = "fixture"

        #expect(coordinator.subjectVM.results.map(\.displayName) == ["Fixture"])
        #expect(!coordinator.isTextMode)
        #expect(!coordinator.hasNoSubjectMatch)
        index.stop()
    }

    // MARK: - The answer is not withheld

    /// Results reach the Slab on the keystroke that produced them.
    ///
    /// They used to be held back for 600ms by a debounced visibility flag,
    /// which left the "No results" row as the only thing the Slab could draw in
    /// the meantime — every search said no, then changed its mind. There is no
    /// waiting to assert on here, and that is the point: this runs in one turn.
    @Test func resultsAreNotWithheldFromTheSlab() {
        let coordinator = makeCoordinator(index: inertAppIndex)

        coordinator.subjectVM.searchText = "clip"

        #expect(coordinator.currentResults.count == 1)
        #expect(coordinator.currentResults.first?.name == "Clipboard")
    }

    // MARK: - The other Modes answer on their own terms

    /// Clipboard search matches what is already in memory, so a Query that
    /// matches nothing is answered immediately — no gate, no delay.
    @Test func clipboardReportsNoResultsAtOnce() {
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        _ = history.recordText("something copied earlier")
        let coordinator = CommandCoordinator(
            runner: RecordingEffectRunner(),
            history: history,
            index: inertAppIndex
        )
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()

        coordinator.currentSearchText = "zzqqzz"

        #expect(coordinator.currentResults.isEmpty)
        #expect(coordinator.canReportNoResults, "in-memory matching has its answer already")
        #expect(!coordinator.isSearchInFlight)
    }

    /// So does Emoji — and the grid is never empty anyway.
    @Test func emojiReportsNoResultsAtOnce() {
        let coordinator = makeCoordinator(index: inertAppIndex)
        coordinator.phase = .browsingEmoji

        coordinator.currentSearchText = "zzqqzz"

        #expect(coordinator.canReportNoResults)
        #expect(!coordinator.isSearchInFlight)
    }

    /// Target search shells out to `mdfind`, so it has a running state of its
    /// own — and while it is running, "No results" is not available.
    @Test func targetSearchSaysItIsSearchingRatherThanEmpty() {
        let coordinator = makeCoordinator(index: inertAppIndex)
        coordinator.phase = .pickingTarget

        coordinator.targetVM.isSearching = true
        #expect(coordinator.isSearchInFlight)
        #expect(!coordinator.canReportNoResults)

        coordinator.targetVM.isSearching = false
        #expect(!coordinator.isSearchInFlight)
        #expect(coordinator.canReportNoResults)
    }

    /// A Target search left half-finished must not silence the *next* Mode's
    /// message. The flag belongs to Target search and is read only there.
    @Test func aStaleTargetSearchDoesNotSilenceAnotherMode() {
        let coordinator = makeCoordinator(index: inertAppIndex)
        coordinator.targetVM.isSearching = true

        coordinator.phase = .browsingClipboard

        #expect(!coordinator.isSearchInFlight)
        #expect(coordinator.canReportNoResults)
    }
}
