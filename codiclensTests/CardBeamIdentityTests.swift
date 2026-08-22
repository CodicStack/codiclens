import AppKit
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// When a Card is about something new, and when it is only a selection moving.
///
/// The Border Beam's trigger used to be a false→true edge on the Card's own
/// `isFocused`, and that missed every case where a Card became about a
/// *different thing* without the keyboard moving: Enter into the Clipboard
/// (`.searchingSubject` and `.browsingClipboard` are both Query Phases, so the
/// Subject Card's focus never moved), the second and every later summon (the
/// Card row is not rebuilt, so there is no edge and no `onAppear` either), OCR
/// Text landing, and a transform's output — the last two both arriving through
/// `retarget`, which replaces the Subject and does not touch the Phase.
///
/// So the trigger is a token, and this is the file that pins it. The half of the
/// rule that is a *hard constraint* is the second half: **a selection moving
/// inside a Card must not sweep it.** The Subject Card previews the highlighted
/// Result while the Query is still live, so a token that tracked the previewed
/// item would strobe the Panel once per arrow key —
/// `docs/adr/0003-motion-budget.md` is explicit that selection movement is
/// instant on purpose. Every "is unchanged" test below is that constraint.
///
/// Nothing here renders anything: `CardBeamIdentity` is three functions of the
/// coordinator precisely so the claim is checkable without a Panel on screen,
/// which is the one thing this environment cannot produce.
@MainActor
struct CardBeamIdentityTests {

    // MARK: - Fixtures

    private func makeCoordinator(
        seededWith texts: [String] = []
    ) -> (CommandCoordinator, ClipboardHistory) {
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        for text in texts { history.recordText(text) }
        let coordinator = CommandCoordinator(
            runner: RecordingEffectRunner(),
            history: history,
            index: inertAppIndex
        )
        return (coordinator, history)
    }

    private func selectAction(_ name: String, in coordinator: CommandCoordinator) throws {
        let index = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == name },
            "no action named \(name)"
        )
        coordinator.actionVM.selectedIndex = index
    }

    /// Puts `subject` under the Subject Card's selection, the way a Query that
    /// matched it would.
    private func seed(_ coordinator: CommandCoordinator, with subjects: [Subject]) {
        coordinator.subjectVM.results = subjects
        coordinator.subjectVM.selectedIndex = 0
    }

    private func appSubject(_ name: String, bundleIdentifier: String) -> Subject {
        Subject(
            displayName: name,
            path: "/Applications/\(name).app",
            url: URL(fileURLWithPath: "/Applications/\(name).app"),
            icon: NSImage(),
            kind: .app(bundleIdentifier: bundleIdentifier, isRunning: false)
        )
    }

    private func clipboardBuiltIn() -> Subject {
        Subject(
            displayName: "Clipboard",
            path: nil,
            url: nil,
            icon: NSImage(),
            kind: .builtIn(.clipboard)
        )
    }

    private static let imageURL = URL(fileURLWithPath: "/tmp/codiclens-fixture/screenshot.png")

    private func imageFileSubject() -> Subject {
        Subject(
            displayName: "screenshot.png",
            path: Self.imageURL.path,
            url: Self.imageURL,
            icon: NSImage(),
            kind: .file(contentType: .png)
        )
    }

    private func finderSubject() -> Subject {
        Subject(
            displayName: "Finder",
            path: "/System/Library/CoreServices/Finder.app",
            url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
            icon: NSImage(),
            kind: .app(bundleIdentifier: "com.apple.finder", isRunning: true)
        )
    }

    /// A directory holding one `note.txt`. Removed by the caller.
    private func fixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-beam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(
            to: root.appendingPathComponent("note.txt"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    // MARK: - The Subject Card: the summon

    /// The case that made the Subject Card essentially never sweep. It is
    /// focused the moment the row is built, so there was never a false→true
    /// edge, and the row is not rebuilt between summons so `onAppear` fired
    /// once in the app's whole life. `reset` runs from
    /// `PanelController.showPanel`, which is what makes a reset a summon.
    @Test func everySummonIsANewSubjectToken() {
        let (coordinator, _) = makeCoordinator()

        let first = CardBeamIdentity.subject(coordinator)
        coordinator.reset()
        let second = CardBeamIdentity.subject(coordinator)
        coordinator.reset()
        let third = CardBeamIdentity.subject(coordinator)

        #expect(first != second, "the first summon")
        #expect(second != third, "and the tenth, identically")
    }

    /// Two summons in a row leave the coordinator in exactly the same state
    /// otherwise, so the counter is the only thing that can carry them apart.
    @Test func aSummonWithNothingElseChangedStillChangesTheToken() {
        let (coordinator, _) = makeCoordinator()
        coordinator.reset()
        let before = CardBeamIdentity.subject(coordinator)

        coordinator.reset()

        #expect(before.phase == CardBeamIdentity.subject(coordinator).phase)
        #expect(before.chosen == CardBeamIdentity.subject(coordinator).chosen)
        #expect(before != CardBeamIdentity.subject(coordinator))
    }

    // MARK: - The Subject Card: the Phase

    /// Enter on Clipboard. Both Phases are Query Phases, so the Card's focus
    /// never moved and the old trigger produced nothing at all.
    @Test func enteringTheClipboardIsANewSubjectToken() {
        let (coordinator, _) = makeCoordinator(seededWith: ["hello"])
        seed(coordinator, with: [clipboardBuiltIn()])
        let before = CardBeamIdentity.subject(coordinator)

        #expect(coordinator.submit().isEmpty, "going in executes nothing")
        #expect(coordinator.phase == .browsingClipboard)
        #expect(CardBeamIdentity.subject(coordinator) != before)
    }

    /// Enter on Emoji, the other Mode reached from Subject search.
    @Test func enteringEmojiModeIsANewSubjectToken() {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: [Subject.emojiBuiltIn])
        let before = CardBeamIdentity.subject(coordinator)

        coordinator.submit()

        #expect(coordinator.phase == .browsingEmoji)
        #expect(CardBeamIdentity.subject(coordinator) != before)
    }

    @Test func tabbingToTheActionsAndBackAreBothNewSubjectTokens() {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: [appSubject("Safari", bundleIdentifier: "com.apple.Safari")])
        let searching = CardBeamIdentity.subject(coordinator)

        coordinator.advancePhase()
        let picking = CardBeamIdentity.subject(coordinator)
        #expect(picking != searching)

        coordinator.retreatPhase()
        #expect(CardBeamIdentity.subject(coordinator) != picking)
    }

    // MARK: - The Subject Card: the Subject being replaced

    /// OCR Text landing. `receiveOCRText` goes through `retarget`, which leaves
    /// the Phase exactly where it was — so the Phase and the summon are both
    /// unchanged here and the Subject is the only thing carrying the sweep.
    @Test func ocrTextArrivingIsANewSubjectToken() throws {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: [imageFileSubject()])
        coordinator.advancePhase()
        try selectAction("OCR", in: coordinator)
        coordinator.submit()
        let inFlight = CardBeamIdentity.subject(coordinator)

        coordinator.receiveOCRText("a page of prose")

        let landed = CardBeamIdentity.subject(coordinator)
        #expect(landed.phase == inFlight.phase, "OCR does not move the Phase")
        #expect(landed.summon == inFlight.summon)
        #expect(landed != inFlight, "the Subject was replaced, so the Card is about something new")
    }

    /// An image with no readable text replaces nothing, so nothing sweeps — the
    /// Subject is still the image it was.
    @Test func ocrFindingNoTextIsNotANewSubjectToken() throws {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: [imageFileSubject()])
        coordinator.advancePhase()
        try selectAction("OCR", in: coordinator)
        coordinator.submit()
        let before = CardBeamIdentity.subject(coordinator)

        coordinator.receiveOCRText("   \n ")

        #expect(coordinator.ocrFoundNoText)
        #expect(CardBeamIdentity.subject(coordinator) == before)
    }

    /// A text transform's output. The same `retarget` as OCR, and the same
    /// unmoved Phase — two text Subjects that differ only in their text have to
    /// be told apart.
    @Test func aTransformsOutputIsANewSubjectToken() throws {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: [Subject(text: "hello world")])
        coordinator.advancePhase()
        try selectAction("UPPERCASE", in: coordinator)
        let before = CardBeamIdentity.subject(coordinator)

        #expect(coordinator.submit().isEmpty, "a transform stays in the Panel")

        let after = CardBeamIdentity.subject(coordinator)
        #expect(after.phase == before.phase, "a transform does not move the Phase")
        #expect(after != before)
    }

    /// The same kind carrying different text is a different thing. This is the
    /// claim `Subject.id` could not have made: it is a fresh `UUID` per
    /// instance, so it says "another object" where the question is "another
    /// thing".
    @Test func twoTextSubjectsDifferingOnlyInTheirTextAreDifferentTokens() {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: [Subject(text: "hello")])
        coordinator.advancePhase()
        let before = CardBeamIdentity.subject(coordinator)

        coordinator.textSubjectEditText = "hello, edited"
        coordinator.isEditingTextSubject = true
        coordinator.saveTextSubjectEdit()

        #expect(CardBeamIdentity.subject(coordinator) != before)
    }

    /// "Use as Subject" promotes a Target into the Subject and lands back on the
    /// Actions.
    @Test func promotingATargetIsANewSubjectToken() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: [finderSubject()])
        coordinator.advancePhase()
        try selectAction("Use as Subject", in: coordinator)
        coordinator.submit()
        #expect(coordinator.phase == .pickingTarget)

        coordinator.targetVM.filteredTargets = [ActionTarget(
            name: "note.txt",
            icon: NSImage(),
            url: root.appendingPathComponent("note.txt"),
            sharingService: nil
        )]
        coordinator.targetVM.selectedIndex = 0
        let before = CardBeamIdentity.subject(coordinator)

        coordinator.submit()

        #expect(coordinator.phase == .pickingAction)
        #expect(CardBeamIdentity.subject(coordinator) != before)
    }

    // MARK: - The Subject Card: a selection moving

    /// The hard constraint. While the Query is live the Card previews the
    /// highlighted Result, so arrowing changes what is on the Card — and must
    /// not sweep it, or every arrow key strobes the Panel.
    @Test func movingTheSubjectSelectionIsNotANewSubjectToken() {
        let (coordinator, _) = makeCoordinator()
        let safari = appSubject("Safari", bundleIdentifier: "com.apple.Safari")
        let mail = appSubject("Mail", bundleIdentifier: "com.apple.mail")
        seed(coordinator, with: [safari, mail])
        let before = CardBeamIdentity.subject(coordinator)

        coordinator.moveDown()
        #expect(coordinator.subjectVM.selectedIndex == 1)
        #expect(CardBeamIdentity.subject(coordinator) == before)

        coordinator.moveUp()
        #expect(CardBeamIdentity.subject(coordinator) == before)
    }

    /// Typing that merely re-ranks the Results is the same thing as arrowing
    /// through them: the Phase has not moved and nothing has been chosen.
    @Test func reRankingTheResultsIsNotANewSubjectToken() {
        let (coordinator, _) = makeCoordinator()
        let safari = appSubject("Safari", bundleIdentifier: "com.apple.Safari")
        let mail = appSubject("Mail", bundleIdentifier: "com.apple.mail")
        seed(coordinator, with: [safari, mail])
        let before = CardBeamIdentity.subject(coordinator)

        coordinator.subjectVM.results = [mail, safari]

        #expect(CardBeamIdentity.subject(coordinator) == before)
    }

    /// The trap that makes the Query Phases read no `selectedSubject` at all:
    /// `moveUp` and `moveDown` *clear* it while the Clipboard is being browsed,
    /// so a token that read it there would sweep on the first arrow key after
    /// going in.
    @Test func arrowingThroughTheClipboardIsNotANewSubjectToken() {
        let (coordinator, _) = makeCoordinator(seededWith: ["older", "newer"])
        seed(coordinator, with: [clipboardBuiltIn()])
        coordinator.submit()
        #expect(coordinator.phase == .browsingClipboard)
        #expect(coordinator.selectedSubject != nil, "going in chose the Built-in")
        let before = CardBeamIdentity.subject(coordinator)

        coordinator.moveDown()

        #expect(coordinator.selectedSubject == nil, "arrowing clears the chosen Subject")
        #expect(CardBeamIdentity.subject(coordinator) == before)
    }

    /// Emoji Mode's grid, for the same reason: moving a cell is a selection
    /// moving, and the Subject Card follows it without becoming about anything
    /// new.
    @Test func movingThroughTheEmojiGridIsNotANewSubjectToken() {
        let (coordinator, _) = makeCoordinator()
        coordinator.enterEmojiMode()
        let before = CardBeamIdentity.subject(coordinator)

        coordinator.moveRight()
        coordinator.moveDown()

        #expect(CardBeamIdentity.subject(coordinator) == before)
    }

    // MARK: - The Action Card

    @Test func reachingTheActionsIsANewActionToken() {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: [appSubject("Safari", bundleIdentifier: "com.apple.Safari")])
        let before = CardBeamIdentity.action(coordinator)

        coordinator.advancePhase()

        #expect(coordinator.phase == .pickingAction)
        #expect(CardBeamIdentity.action(coordinator) != before)
    }

    /// Shift+Tab back from a Target reaches the Actions too, and the Action Card
    /// is not rebuilt on the way — it is still in the row — so the token is the
    /// only thing that can sweep it.
    @Test func comingBackFromATargetIsANewActionToken() throws {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: [Subject(text: "hello")])
        coordinator.advancePhase()
        try selectAction("Share…", in: coordinator)
        coordinator.submit()
        #expect(coordinator.phase == .pickingTarget)
        let onTheTarget = CardBeamIdentity.action(coordinator)

        coordinator.retreatPhase()

        #expect(coordinator.phase == .pickingAction)
        #expect(CardBeamIdentity.action(coordinator) != onTheTarget)
    }

    /// The list was rebuilt for a different Subject, so the Card is about
    /// something else even though the Phase never moved.
    @Test func theSubjectBehindTheActionsBeingReplacedIsANewActionToken() throws {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: [imageFileSubject()])
        coordinator.advancePhase()
        try selectAction("OCR", in: coordinator)
        coordinator.submit()
        let before = CardBeamIdentity.action(coordinator)

        coordinator.receiveOCRText("a page of prose")

        #expect(coordinator.phase == .pickingAction, "the Phase did not move")
        #expect(CardBeamIdentity.action(coordinator) != before)
    }

    @Test func movingTheActionSelectionIsNotANewActionToken() {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: [Subject(text: "hello")])
        coordinator.advancePhase()
        #expect(coordinator.actionVM.filteredActions.count > 1)
        let before = CardBeamIdentity.action(coordinator)

        coordinator.moveDown()
        #expect(coordinator.actionVM.selectedIndex == 1)

        #expect(CardBeamIdentity.action(coordinator) == before)
    }

    /// Filtering the Actions with a Query narrows the list and moves the
    /// selection to the top of it. Still the same Subject's Actions.
    @Test func filteringTheActionsIsNotANewActionToken() {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: [Subject(text: "hello")])
        coordinator.advancePhase()
        coordinator.actionVM.selectedIndex = 2
        let before = CardBeamIdentity.action(coordinator)

        coordinator.actionVM.searchText = "cop"

        #expect(coordinator.actionVM.filteredActions.count < coordinator.actionVM.allActions.count)
        #expect(CardBeamIdentity.action(coordinator) == before)
    }

    // MARK: - The Target Card

    @Test func reachingTheTargetsIsANewTargetToken() throws {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: [Subject(text: "hello")])
        coordinator.advancePhase()
        try selectAction("Share…", in: coordinator)
        let before = CardBeamIdentity.target(coordinator)

        coordinator.submit()

        #expect(coordinator.phase == .pickingTarget)
        #expect(CardBeamIdentity.target(coordinator) != before)
    }

    @Test func movingTheTargetSelectionIsNotANewTargetToken() throws {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: [finderSubject()])
        coordinator.advancePhase()
        try selectAction("Use as Subject", in: coordinator)
        coordinator.submit()
        coordinator.targetVM.filteredTargets = [
            ActionTarget(name: "one.txt", icon: NSImage(), url: nil, sharingService: nil),
            ActionTarget(name: "two.txt", icon: NSImage(), url: nil, sharingService: nil)
        ]
        coordinator.targetVM.selectedIndex = 0
        let before = CardBeamIdentity.target(coordinator)

        coordinator.moveDown()

        #expect(coordinator.targetVM.selectedIndex == 1)
        #expect(CardBeamIdentity.target(coordinator) == before)
    }

    /// `mdfind` answers out of process and rewrites the list when it does. That
    /// is the list being filled in, not the Card becoming about something else —
    /// which is why no token holds anything about the Targets themselves.
    @Test func mdfindResultsArrivingIsNotANewTargetToken() throws {
        let (coordinator, _) = makeCoordinator()
        seed(coordinator, with: [finderSubject()])
        coordinator.advancePhase()
        try selectAction("Use as Subject", in: coordinator)
        coordinator.submit()
        #expect(coordinator.targetVM.filteredTargets.isEmpty, "nothing has answered yet")
        let before = CardBeamIdentity.target(coordinator)

        coordinator.targetVM.isSearching = true
        coordinator.targetVM.filteredTargets = [
            ActionTarget(name: "note.txt", icon: NSImage(), url: nil, sharingService: nil)
        ]
        coordinator.targetVM.isSearching = false

        #expect(CardBeamIdentity.target(coordinator) == before)
    }
}
