import AppKit
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// OCR, entirely on this side of the Effect seam.
///
/// **Vision never runs here, and that is the point of the seam.** The
/// coordinator returns `.ocr(url)` and stops; a test plays the runner's part by
/// calling `receiveOCRText` with a canned string. See
/// `docs/adr/0007-async-action-behind-the-effect-seam.md`.
@MainActor
struct OCRCommandTests {

    // MARK: - Fixtures

    private func makeCoordinator(
    ) -> (CommandCoordinator, RecordingEffectRunner, ClipboardHistory) {
        let runner = RecordingEffectRunner()
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        let coordinator = CommandCoordinator(runner: runner, history: history, index: inertAppIndex)
        return (coordinator, runner, history)
    }

    private func selectAction(_ name: String, in coordinator: CommandCoordinator) throws {
        let index = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == name },
            "no action named \(name)"
        )
        coordinator.actionVM.selectedIndex = index
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

    /// Puts an image-file Subject on the Action Phase with OCR selected.
    private func readyToOCRAFile(
        _ coordinator: CommandCoordinator
    ) throws -> Subject {
        let subject = imageFileSubject()
        coordinator.subjectVM.results = [subject]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.advancePhase()
        try selectAction("OCR", in: coordinator)
        return subject
    }

    /// Puts a Clipboard Image on the Action Phase with OCR selected.
    private func readyToOCRAClipboardImage(
        _ coordinator: CommandCoordinator,
        _ history: ClipboardHistory
    ) throws {
        history.recordImage(Data([0x89, 0x50, 0x4E, 0x47]))
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()
        coordinator.advancePhase()
        try selectAction("OCR", in: coordinator)
    }

    // MARK: - The Action exists exactly where it should

    @Test func aClipboardImageOffersOCRAndAClipboardTextDoesNot() {
        let (coordinator, _, history) = makeCoordinator()
        history.recordImage(Data([0x89, 0x50]))
        history.recordText("just words")
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()

        coordinator.clipboardVM.selectedIndex = 0     // the text, recorded last
        coordinator.advancePhase()
        #expect(!coordinator.actionVM.filteredActions.contains { $0.name == "OCR" })

        coordinator.retreatPhase()
        coordinator.clipboardVM.selectedIndex = 1     // the image
        coordinator.advancePhase()
        #expect(coordinator.actionVM.filteredActions.contains { $0.name == "OCR" })
    }

    /// OCR turns on the content type, not on the kind, and the question is the
    /// system's: `conforms(to: .image)`.
    ///
    /// PDF does not conform to `.image`, so it is out without a special case —
    /// which is the whole reason the gate is a conformance rather than a list
    /// of extensions. `public.svg-image` *does* conform, so an SVG is offered
    /// OCR; nothing here rasterises or otherwise handles one specially, and if
    /// Vision cannot read it the run comes back with no OCR Text and the Panel
    /// shakes. Deliberately not the extension list in
    /// `TargetSearchVM.imageExtensions`, which files `pdf` under images for
    /// *thumbnails* — a different question, left alone.
    @Test(arguments: [
        (UTType.png, true),
        (.jpeg, true),
        (.heic, true),
        (.tiff, true),
        (.svg, true),
        (.plainText, false),
        (.pdf, false),
        (.json, false),
    ])
    func onlyAnImageFileOffersOCR(contentType: UTType, offersOCR: Bool) {
        let names = SubjectAction.actions(for: Subject(
            displayName: "thing",
            path: "/tmp/thing",
            url: URL(fileURLWithPath: "/tmp/thing"),
            icon: NSImage(),
            kind: .file(contentType: contentType)
        )).map(\.name)

        #expect(names.contains("OCR") == offersOCR)
    }

    @Test func aFolderNeverOffersOCR() {
        let names = SubjectAction.actions(for: Subject(
            displayName: "Downloads",
            path: "/tmp",
            url: URL(fileURLWithPath: "/tmp"),
            icon: NSImage(),
            kind: .folder
        )).map(\.name)

        #expect(!names.contains("OCR"))
        #expect(names.first == "Open")
    }

    // MARK: - The Effect

    /// A URL crosses the seam, never image bytes — and never a `.hide`, because
    /// the OCR Text lands *in* the Panel.
    @Test func ocrOnAnImageFileAsksForThatURLAndDoesNotHide() throws {
        let (coordinator, runner, _) = makeCoordinator()
        _ = try readyToOCRAFile(coordinator)

        let effects = coordinator.submit()

        #expect(effects == [.ocr(Self.imageURL)])
        #expect(!effects.contains(.hide), "the Panel has to still be there")
        #expect(runner.recorded == effects)
        #expect(coordinator.isOCRInFlight)
    }

    @Test func ocrOnAClipboardImageAsksForTheStoredImageURL() throws {
        let (coordinator, runner, history) = makeCoordinator()
        try readyToOCRAClipboardImage(coordinator, history)
        let item = try #require(history.items.first)
        let url = try #require(history.imageURL(for: item))

        let effects = coordinator.submit()

        #expect(effects == [.ocr(url)])
        #expect(!effects.contains(.hide))
        #expect(runner.recorded == effects)
    }

    /// Two runs racing to retarget the same Subject would have the loser
    /// overwrite the winner, so the second Enter does nothing at all.
    @Test func aSecondEnterWhileOCRIsRunningDoesNothing() throws {
        let (coordinator, runner, _) = makeCoordinator()
        _ = try readyToOCRAFile(coordinator)
        _ = coordinator.submit()
        let recordedSoFar = runner.recorded

        #expect(coordinator.submit().isEmpty)
        #expect(runner.recorded == recordedSoFar, "nothing further reached the runner")
    }

    // MARK: - Where the OCR Text lands

    /// The Subject becomes the OCR Text, the Phase does not move, and the Query
    /// is left alone — `PanelLayout.queryFieldHeight` is a one-line bar and a
    /// page of OCR Text cannot survive in it.
    @Test func theOCRTextBecomesTheSubjectWithoutTouchingTheQuery() throws {
        let (coordinator, _, _) = makeCoordinator()
        coordinator.subjectVM.searchText = "shot"
        _ = try readyToOCRAFile(coordinator)
        _ = coordinator.submit()

        coordinator.receiveOCRText("Hello from the image\nsecond line")

        #expect(!coordinator.isOCRInFlight)
        #expect(coordinator.phase == .pickingAction, "OCR fired from here and stays here")
        #expect(coordinator.subjectVM.searchText == "shot", "the Query is not a page of prose")

        guard case .text(let rawText)? = coordinator.selectedSubject?.kind else {
            Issue.record("expected a text Subject holding the OCR Text")
            return
        }
        #expect(rawText == "Hello from the image\nsecond line")
        #expect(coordinator.actionVM.selectedIndex == 0, "back to the top of the new Actions")
    }

    /// The user's "Enter right after OCR pastes" depends entirely on this
    /// ordering, and on nothing else.
    @Test func theOCRTextsActionsStartWithPaste() throws {
        let (coordinator, _, _) = makeCoordinator()
        _ = try readyToOCRAFile(coordinator)
        _ = coordinator.submit()

        coordinator.receiveOCRText("some text")

        #expect(coordinator.actionVM.filteredActions.first?.name == "Paste")
        #expect(coordinator.submit() == [.paste(.text("some text"))])
    }

    // MARK: - No text found

    @Test(arguments: [nil, "", "   \n  "] as [String?])
    func anImageWithNoTextLeavesTheSubjectAloneAndShakes(answer: String?) throws {
        let (coordinator, _, _) = makeCoordinator()
        let subject = try readyToOCRAFile(coordinator)
        _ = coordinator.submit()

        coordinator.receiveOCRText(answer)

        #expect(!coordinator.isOCRInFlight)
        #expect(coordinator.ocrFoundNoText, "the state the Panel shakes about")
        #expect(coordinator.phase == .pickingAction)

        let kind = try #require(coordinator.selectedSubject?.kind)
        guard case .file(let contentType) = kind else {
            Issue.record("the Subject must be left exactly as it was")
            return
        }
        #expect(contentType == .png)
        #expect(coordinator.selectedSubject?.url == subject.url)
    }

    /// Two barren images in a row shake twice: the flag is cleared as each run
    /// starts, so the change the Panel watches for happens again.
    @Test func theShakeStateIsClearedWhenTheNextRunStarts() throws {
        let (coordinator, _, _) = makeCoordinator()
        _ = try readyToOCRAFile(coordinator)
        _ = coordinator.submit()
        coordinator.receiveOCRText(nil)
        #expect(coordinator.ocrFoundNoText)

        try selectAction("OCR", in: coordinator)
        _ = coordinator.submit()

        #expect(!coordinator.ocrFoundNoText)
    }

    // MARK: - The Clipboard Image survives

    /// OCR retargets, it never rewrites. A transform on a Clipboard Item
    /// replaces it in history in place; an image replaced by its own OCR Text
    /// is an image that is gone.
    @Test func ocrOnAClipboardImageLeavesTheImageInHistory() throws {
        let (coordinator, _, history) = makeCoordinator()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        history.recordImage(png)
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()
        coordinator.advancePhase()
        try selectAction("OCR", in: coordinator)
        let itemBefore = try #require(history.items.first)

        _ = coordinator.submit()
        coordinator.receiveOCRText("text that was in the picture")

        #expect(history.items.count == 1)
        let itemAfter = try #require(history.items.first)
        #expect(itemAfter.isImage, "still an image")
        #expect(itemAfter.imageFileName == itemBefore.imageFileName)
        #expect(history.imageData(for: itemAfter) == png, "the bytes are still there")

        guard case .text? = coordinator.selectedSubject?.kind else {
            Issue.record("the Subject is the OCR Text now")
            return
        }
    }

    // MARK: - What the Slab may say while it runs

    /// "No results" is a claim, and a Mode in the middle of an OCR run is not
    /// entitled to it — it is saying "Reading text…" instead.
    @Test func nothingClaimsNoResultsWhileOCRIsRunning() throws {
        let (coordinator, _, _) = makeCoordinator()
        _ = try readyToOCRAFile(coordinator)
        #expect(coordinator.canReportNoResults, "before the run, an ordinary Action list")

        _ = coordinator.submit()

        #expect(coordinator.isOCRInFlight)
        #expect(!coordinator.canReportNoResults)
        #expect(!coordinator.isSearchInFlight, "OCR is not a search, and does not borrow that flag")

        coordinator.receiveOCRText("done")
        #expect(coordinator.canReportNoResults)
    }

    /// Dismissing the Panel abandons the run: the answer arrives to a
    /// coordinator that is no longer waiting for it and is dropped.
    @Test func anAnswerThatArrivesAfterAResetIsDropped() throws {
        let (coordinator, _, _) = makeCoordinator()
        _ = try readyToOCRAFile(coordinator)
        _ = coordinator.submit()

        coordinator.reset()
        coordinator.receiveOCRText("too late")

        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.selectedSubject == nil)
        #expect(!coordinator.ocrFoundNoText)
    }
}
