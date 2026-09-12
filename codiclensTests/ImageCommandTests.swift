import AppKit
import Testing
import UniformTypeIdentifiers
@testable import codiclens

@MainActor
struct ImageCommandTests {
    private func makeCoordinator(
        store: InMemoryClipboardStore? = nil
    ) -> (CommandCoordinator, RecordingEffectRunner, ClipboardHistory) {
        let runner = RecordingEffectRunner()
        let history = ClipboardHistory(store: store ?? InMemoryClipboardStore())
        return (
            CommandCoordinator(runner: runner, history: history, index: inertAppIndex),
            runner,
            history
        )
    }

    private func selectAction(_ name: String, in coordinator: CommandCoordinator) throws {
        coordinator.actionVM.selectedIndex = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == name },
            "no Action named \(name)"
        )
    }

    private func readyText(_ text: String, in coordinator: CommandCoordinator) {
        coordinator.subjectVM.results = [Subject(text: text)]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.advancePhase()
    }

    private func imageFileSubject(_ url: URL = URL(fileURLWithPath: "/tmp/photo.png")) -> Subject {
        Subject(
            displayName: url.lastPathComponent,
            path: url.path,
            url: url,
            icon: NSImage(),
            kind: .file(contentType: .png)
        )
    }

    // MARK: - Availability

    @Test func qrCodeAppearsOnlyForTextThatFits() throws {
        let maximum = String(repeating: "a", count: 2_331)
        let tooLarge = maximum + "a"
        let emoji = Emoji(string: "🔥", name: "fire", keywords: ["hot"], groupIndex: 0)

        #expect(SubjectAction.actions(for: Subject(text: maximum)).contains { $0.name == "QR Code" })
        #expect(!SubjectAction.actions(for: Subject(text: tooLarge)).contains { $0.name == "QR Code" })
        #expect(!SubjectAction.actions(for: Subject(emoji: emoji)).contains { $0.name == "QR Code" })

        let textItem = ClipboardItem(content: "clipboard text")
        let imageItem = ClipboardItem(imageFileName: "image.png")
        #expect(SubjectAction.actions(for: Subject(clipboardItem: textItem)).contains { $0.name == "QR Code" })
        #expect(!SubjectAction.actions(for: Subject(clipboardItem: imageItem)).contains { $0.name == "QR Code" })

        let names = SubjectAction.actions(for: Subject(text: "ordered")).map(\.name)
        let searchIndex = try #require(names.firstIndex(of: "Search Web"))
        let qrIndex = try #require(names.firstIndex(of: "QR Code"))
        #expect(searchIndex < qrIndex)
    }

    @Test func rotateAndPreviewAppearOnlyForImageSubjects() {
        let imageNames = SubjectAction.actions(for: imageFileSubject()).map(\.name)
        let textNames = SubjectAction.actions(for: Subject(
            displayName: "note.txt", path: "/tmp/note.txt", url: URL(fileURLWithPath: "/tmp/note.txt"),
            icon: NSImage(), kind: .file(contentType: .plainText)
        )).map(\.name)
        let folderNames = SubjectAction.actions(for: Subject(
            displayName: "folder", path: "/tmp/folder", url: URL(fileURLWithPath: "/tmp/folder"),
            icon: NSImage(), kind: .folder
        )).map(\.name)

        #expect(imageNames.contains("Rotate Left"))
        #expect(imageNames.contains("Rotate Right"))
        #expect(imageNames.contains("Open in Preview"))
        #expect(!textNames.contains("Rotate Left"))
        #expect(!textNames.contains("Open in Preview"))
        #expect(!folderNames.contains("Rotate Right"))
    }

    // MARK: - QR Code

    @Test func qrCodeRunsAcrossEffectSeamWithoutHiding() throws {
        let (coordinator, runner, _) = makeCoordinator()
        readyText("hello", in: coordinator)
        try selectAction("QR Code", in: coordinator)

        let effects = coordinator.submit()
        guard case .generateQRCode(let text, generation: _) = try #require(effects.first) else {
            Issue.record("expected QR Code effect")
            return
        }
        #expect(text == "hello")
        #expect(effects.count == 1)
        #expect(!effects.contains(.hide))
        #expect(runner.recorded == effects)
        #expect(coordinator.isImageActionInFlight)

        let recorded = runner.recorded
        #expect(coordinator.submit().isEmpty)
        #expect(runner.recorded == recorded)
    }

    @Test func qrCodeAnswerBecomesNewClipboardImageSubject() throws {
        let (coordinator, _, history) = makeCoordinator()
        readyText("hello", in: coordinator)
        try selectAction("QR Code", in: coordinator)
        let effects = coordinator.submit()
        guard case .generateQRCode(_, generation: let generation) = try #require(effects.first) else {
            Issue.record("expected QR Code effect")
            return
        }

        let png = Data([0x89, 0x50, 0x4e, 0x47])
        coordinator.receiveQRCode(png, generation: generation)

        #expect(!coordinator.isImageActionInFlight)
        #expect(coordinator.phase == .pickingAction)
        let item = try #require(history.items.first)
        #expect(item.isImage)
        #expect(history.imageData(for: item) == png)
        #expect(coordinator.selectedClipboardItem?.id == item.id)
        #expect(coordinator.actionVM.filteredActions.contains { $0.name == "Rotate Left" })
    }

    @Test func staleQRCodeAnswerAfterResetIsDropped() throws {
        let (coordinator, _, history) = makeCoordinator()
        readyText("hello", in: coordinator)
        try selectAction("QR Code", in: coordinator)
        let effects = coordinator.submit()
        guard case .generateQRCode(_, generation: let generation) = try #require(effects.first) else {
            Issue.record("expected QR Code effect")
            return
        }

        coordinator.reset()
        coordinator.receiveQRCode(Data([1]), generation: generation)

        #expect(history.items.isEmpty)
        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.selectedSubject == nil)
    }

    @Test func qrCodeAnswerAfterLeavingActionPhaseClearsBusyStateAndIsDropped() throws {
        let (coordinator, _, history) = makeCoordinator()
        readyText("hello", in: coordinator)
        try selectAction("QR Code", in: coordinator)
        let effects = coordinator.submit()
        guard case .generateQRCode(_, generation: let generation) = try #require(effects.first) else {
            Issue.record("expected QR Code effect")
            return
        }

        coordinator.retreatPhase()
        coordinator.receiveQRCode(Data([1]), generation: generation)

        #expect(!coordinator.isImageActionInFlight)
        #expect(history.items.isEmpty)
        #expect(coordinator.phase == .searchingSubject)
    }

    // MARK: - Rotate

    @Test func clipboardRotateUsesStoredSnapshotAndKeepsHistoryOrder() throws {
        let (coordinator, _, history) = makeCoordinator()
        history.recordImage(Data([1]), timestamp: Date(timeIntervalSince1970: 1))
        history.recordText("newer", timestamp: Date(timeIntervalSince1970: 2))
        let orderBefore = history.items.map(\.id)

        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()
        coordinator.clipboardVM.selectedIndex = 1
        coordinator.advancePhase()
        let oldSubjectID = try #require(coordinator.selectedSubject?.id)
        let item = try #require(coordinator.selectedClipboardItem)
        let storedURL = try #require(history.imageURL(for: item))
        coordinator.actionVM.searchText = "Left"
        try selectAction("Rotate Left", in: coordinator)
        let selectedActionIndex = coordinator.actionVM.selectedIndex
        let filteredActionsBefore = coordinator.actionVM.filteredActions.map(\.name)

        let effects = coordinator.submit()
        guard case .rotateImage(let url, direction: let direction, generation: let generation) = try #require(effects.first) else {
            Issue.record("expected Rotate effect")
            return
        }
        #expect(url == storedURL)
        #expect(direction == .left)
        #expect(!effects.contains(.hide))

        coordinator.receiveImageRotation(succeeded: true, generation: generation)

        #expect(history.items.map(\.id) == orderBefore)
        #expect(coordinator.selectedClipboardItem?.id == item.id)
        #expect(coordinator.selectedSubject?.id != oldSubjectID, "fresh Subject reloads thumbnail")
        #expect(coordinator.phase == .pickingAction)
        #expect(coordinator.actionVM.selectedIndex == selectedActionIndex, "same Action remains selected")
        #expect(coordinator.actionVM.searchText == "Left", "Action filter remains in force")
        #expect(coordinator.actionVM.filteredActions.map(\.name) == filteredActionsBefore)
    }

    @Test func fileRotateUsesOriginalFileURL() throws {
        let (coordinator, _, _) = makeCoordinator()
        let subject = imageFileSubject()
        coordinator.subjectVM.results = [subject]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.advancePhase()
        try selectAction("Rotate Right", in: coordinator)

        let effects = coordinator.submit()
        guard case .rotateImage(let url, direction: let direction, generation: _) = try #require(effects.first) else {
            Issue.record("expected Rotate effect")
            return
        }
        #expect(url == subject.url)
        #expect(direction == .right)
        #expect(!effects.contains(.hide))
    }

    @Test func failedRotateClearsBusyStateAndShakesWithoutChangingSubject() throws {
        let (coordinator, _, _) = makeCoordinator()
        let subject = imageFileSubject()
        coordinator.subjectVM.results = [subject]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.advancePhase()
        try selectAction("Rotate Left", in: coordinator)
        let effects = coordinator.submit()
        guard case .rotateImage(_, direction: _, generation: let generation) = try #require(effects.first) else {
            Issue.record("expected Rotate effect")
            return
        }

        coordinator.receiveImageRotation(succeeded: false, generation: generation)

        #expect(!coordinator.isImageActionInFlight)
        #expect(coordinator.imageActionFailed)
        #expect(coordinator.selectedSubject?.id == subject.id)
        #expect(coordinator.phase == .pickingAction)
    }

    @Test func rotateAnswerAfterLeavingActionPhaseClearsBusyStateAndIsDropped() throws {
        let (coordinator, _, _) = makeCoordinator()
        let subject = imageFileSubject()
        coordinator.subjectVM.results = [subject]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.advancePhase()
        try selectAction("Rotate Left", in: coordinator)
        let effects = coordinator.submit()
        guard case .rotateImage(_, direction: _, generation: let generation) = try #require(effects.first) else {
            Issue.record("expected Rotate effect")
            return
        }

        coordinator.retreatPhase()
        coordinator.receiveImageRotation(succeeded: true, generation: generation)

        #expect(!coordinator.isImageActionInFlight)
        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.selectedSubject?.id == subject.id, "stale completion does not refresh Subject")
    }

    @Test func openInPreviewExplicitlyTargetsPreviewEffect() throws {
        let (coordinator, _, _) = makeCoordinator()
        let subject = imageFileSubject()
        coordinator.subjectVM.results = [subject]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.advancePhase()
        try selectAction("Open in Preview", in: coordinator)

        let url = try #require(subject.url)
        #expect(coordinator.submit() == [.hide, .openInPreview(url)])
    }

    @Test func clipboardOpenInPreviewUsesStoredSnapshot() throws {
        let (coordinator, _, history) = makeCoordinator()
        history.recordImage(Data([1]))
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()
        coordinator.advancePhase()
        let item = try #require(coordinator.selectedClipboardItem)
        let storedURL = try #require(history.imageURL(for: item))
        try selectAction("Open in Preview", in: coordinator)

        #expect(coordinator.submit() == [.hide, .openInPreview(storedURL)])
    }

    // MARK: - Storage identity

    @Test func generatedImagesInSameSecondKeepDistinctSnapshots() throws {
        let store = InMemoryClipboardStore()
        let history = ClipboardHistory(store: store)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let old = try #require(history.recordGeneratedImage(Data([1]), timestamp: stamp))
        let oldName = try #require(old.imageFileName)

        let new = try #require(history.recordGeneratedImage(Data([2]), timestamp: stamp))

        #expect(new.imageFileName != oldName)
        #expect(history.imageData(for: old) == Data([1]))
        #expect(history.imageData(for: new) == Data([2]))
    }
}
