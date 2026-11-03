import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import codiclens

/// Search by meaning's choice: Off, Text or Text, images and audio. Off
/// until chosen, so a fresh install downloads nothing until Setup's Done; an
/// install from before the choice that had the model keeps it on. A choice
/// downloads what it needs, then starts the pass, then says ready; Text needs
/// the text model alone, and the encoders can be added later; off stops it;
/// Remove deletes the model and the vectors; nothing at all on Intel. Over a
/// fake download into a temporary folder and closures standing in for the
/// File Index.
@MainActor
struct MeaningSettingsTests {
    /// What the File Index was told.
    final class Index {
        var applied: [MeaningMode] = []
        var removed = 0
        var progress = MeaningSettings.Progress()
    }

    private func make(
        mode: MeaningMode = .off, isSupported: Bool = true, downloader: StubDownloader = StubDownloader()
    ) throws -> (MeaningSettings, Index, TemporaryFolder, Saved) {
        let folder = try TemporaryFolder()
        let files = ModelFiles(folder: folder.url, files: StubDownloader.files, downloader: downloader)
        let saved = Saved(mode)
        let settings = MeaningSettings(
            files: files, choice: MeaningSettings.Choice(mode: mode, save: { saved.value = $0 }), isSupported: isSupported
        )
        let index = Index()
        settings.apply = { index.applied.append($0) }
        settings.removeVectors = { index.removed += 1 }
        settings.progress = { index.progress }
        return (settings, index, folder, saved)
    }

    final class Saved {
        var value: MeaningMode
        init(_ value: MeaningMode) { self.value = value }
    }

    /// The app's settings over `defaults` and a models folder, as a launch
    /// makes them.
    private func launch(
        _ defaults: UserDefaults, models folder: TemporaryFolder, downloader: StubDownloader
    ) -> (MeaningSettings, Index) {
        let files = ModelFiles(folder: folder.url, files: StubDownloader.files, downloader: downloader)
        let settings = MeaningSettings(files: files, choice: .defaults(defaults, files: files), isSupported: true)
        let index = Index()
        settings.apply = { index.applied.append($0) }
        return (settings, index)
    }

    private func putModel(_ files: [ModelFile], in folder: TemporaryFolder) throws {
        for file in files { try StubDownloader.contents[file.name]!.write(to: folder.url.appendingPathComponent(file.name)) }
    }

    /// Nothing kept is off: a fresh install's launch (`start()`) downloads
    /// nothing, and Setup offers the full choice.
    @Test func aFreshInstallIsOffAndItsLaunchDownloadsNothing() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let downloader = StubDownloader()
        let defaults = ThrowawayDefaults()
        let (settings, index) = launch(defaults, models: folder, downloader: downloader)

        await settings.startAndWait()

        #expect(settings.mode == .off)
        #expect(settings.status == .off)
        #expect(settings.suggested == .full, "Setup preselects text, images and audio")
        #expect(downloader.requested.withLock { $0 }.isEmpty)
        #expect(index.applied.isEmpty)
        #expect(defaults.object(forKey: MeaningSettings.Choice.key) == nil, "nothing chosen yet")
    }

    /// Before the choice there was one switch, on unless turned off, that
    /// downloaded the model at launch. An install that had it on with the
    /// model on disk carries on exactly as it was: the full choice, nothing
    /// downloaded again.
    @Test func anInstallThatHadTheModelKeepsSearchingByMeaning() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try putModel(StubDownloader.files, in: folder)
        let downloader = StubDownloader()
        let defaults = ThrowawayDefaults()
        let (settings, index) = launch(defaults, models: folder, downloader: downloader)

        await settings.startAndWait()

        #expect(settings.mode == .full)
        #expect(settings.suggested == .full)
        #expect(downloader.requested.withLock { $0 }.isEmpty, "nothing downloads again")
        #expect(index.applied == [.full])
        #expect(defaults.object(forKey: MeaningSettings.Choice.key) as? String == "full")
        #expect(defaults.object(forKey: MeaningSettings.Choice.switchKey) == nil, "migrated: the old switch is gone")
    }

    /// One whose download was under way carries on with it, as it would
    /// have at launch.
    @Test func anInstallHalfwayThroughTheDownloadFinishesIt() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try putModel([StubDownloader.files[0]], in: folder)
        let downloader = StubDownloader()
        let defaults = ThrowawayDefaults()
        defaults.set(true, forKey: MeaningSettings.Choice.switchKey)
        let (settings, index) = launch(defaults, models: folder, downloader: downloader)

        await settings.startAndWait()

        #expect(settings.mode == .full)
        #expect(downloader.requested.withLock { $0 } == ["b.gguf"])
        #expect(index.applied == [.full])
    }

    /// The user's own off from before stays off, and Setup offers it as it is.
    @Test func anInstallThatTurnedItOffStaysOff() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try putModel(StubDownloader.files, in: folder)
        let defaults = ThrowawayDefaults()
        defaults.set(false, forKey: MeaningSettings.Choice.switchKey)
        let (settings, index) = launch(defaults, models: folder, downloader: StubDownloader())

        await settings.startAndWait()

        #expect(settings.mode == .off)
        #expect(settings.suggested == .off)
        #expect(index.applied.isEmpty)
        #expect(defaults.object(forKey: MeaningSettings.Choice.key) as? String == "off")
    }

    /// A choice is kept: the next launch carries on with it.
    @Test func aChoiceIsKeptForTheNextLaunch() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let defaults = ThrowawayDefaults()
        let (settings, _) = launch(defaults, models: folder, downloader: StubDownloader())

        settings.setMode(.text)
        await settings.startAndWait()

        let (next, index) = launch(defaults, models: folder, downloader: StubDownloader())
        #expect(next.mode == .text)
        #expect(next.suggested == .text)
        await next.startAndWait()
        #expect(index.applied == [.text])
    }

    @Test func onIntelAFreshInstallIsUnavailableAndDownloadsNothing() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let downloader = StubDownloader()
        let files = ModelFiles(folder: folder.url, files: StubDownloader.files, downloader: downloader)
        let settings = MeaningSettings(files: files, choice: .defaults(ThrowawayDefaults(), files: files),
                                       isSupported: false)

        await settings.startAndWait()

        #expect(settings.status == .unavailable)
        #expect(settings.suggested == .off)
        #expect(downloader.requested.withLock { $0 }.isEmpty)
    }

    /// Text: the text model alone, and the pass without pictures and sound.
    @Test func theTextChoiceDownloadsOnlyTheTextModel() async throws {
        let downloader = StubDownloader()
        let (settings, index, folder, saved) = try make(downloader: downloader)
        defer { folder.remove() }

        settings.setMode(.text)
        await settings.startAndWait()

        #expect(saved.value == .text)
        #expect(downloader.requested.withLock { $0 } == ["a.gguf"])
        #expect(index.applied == [.text])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["a.gguf"])
    }

    /// From Text to Text, images and audio in Settings: the encoders
    /// download while text keeps being searched by meaning, then the pass
    /// takes pictures and sound too.
    @Test func addingTheEncodersLaterDownloadsOnlyThem() async throws {
        let downloader = StubDownloader()
        let (settings, index, folder, _) = try make(mode: .text, downloader: downloader)
        defer { folder.remove() }
        await settings.startAndWait()
        #expect(index.applied == [.text])

        downloader.gate.withLock { $0 = true }
        settings.setMode(.full)
        let started = Task { await settings.startAndWait() }
        while downloader.requested.withLock({ $0 }).count < 2 { await Task.yield() }
        guard case .downloading = settings.status else {
            Issue.record("expected downloading, got \(settings.status)")
            return
        }
        #expect(index.applied == [.text], "text is still searched while the encoders come")

        downloader.gate.withLock { $0 = false }
        await started.value
        #expect(downloader.requested.withLock { $0 } == ["a.gguf", "b.gguf"])
        #expect(index.applied == [.text, .full])
    }

    /// Back from the full choice to Text: nothing to download, and the pass
    /// goes on without pictures and sound. The encoders stay on disk.
    @Test func goingBackToTextKeepsTheEncoders() async throws {
        let (settings, index, folder, _) = try make(mode: .full)
        defer { folder.remove() }
        await settings.startAndWait()

        settings.setMode(.text)
        await settings.startAndWait()

        #expect(index.applied == [.full, .text])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["a.gguf", "b.gguf"])
    }

    @Test func turnedOffItDownloadsNothing() throws {
        let downloader = StubDownloader()
        let (settings, index, folder, _) = try make(downloader: downloader)
        defer { folder.remove() }
        settings.start()
        #expect(settings.status == .off)
        #expect(index.applied.isEmpty)
        #expect(downloader.requested.withLock { $0 }.isEmpty)
    }

    @Test func turningItOnDownloadsThenReadsThenIsReady() async throws {
        let downloader = StubDownloader()
        downloader.gate.withLock { $0 = true }
        let (settings, index, folder, saved) = try make(downloader: downloader)
        defer { folder.remove() }

        settings.setMode(.full)
        #expect(saved.value == .full)
        let started = Task { await settings.startAndWait() }
        while downloader.requested.withLock({ $0 }).isEmpty { await Task.yield() }
        guard case .downloading = settings.status else {
            Issue.record("expected downloading, got \(settings.status)")
            return
        }
        #expect(index.applied.isEmpty, "nothing is embedded before the model is here")

        downloader.gate.withLock { $0 = false }
        await started.value
        #expect(index.applied == [.full])
        index.progress = .init(counts: MeaningCounts(files: 10, embedded: 4, vectors: 30))
        #expect(settings.status == .reading(MeaningCounts(files: 10, embedded: 4, vectors: 30)))
        #expect(settings.status.text == "Reading 4 of 10 files")
        index.progress.isLowPower = true
        #expect(settings.status.text == "Paused in Low Power Mode, 4 of 10 files read")
        index.progress = .init(counts: MeaningCounts(files: 10, embedded: 10, vectors: 70))
        #expect(settings.status == .ready(MeaningCounts(files: 10, embedded: 10, vectors: 70)))
        #expect(settings.status.text == "Ready, 10 files read")
    }

    @Test func turningItOffStopsThePassAndKeepsTheModel() async throws {
        let (settings, index, folder, saved) = try make(mode: .full)
        defer { folder.remove() }
        await settings.startAndWait()
        #expect(index.applied == [.full])

        settings.setMode(.off)
        #expect(index.applied == [.full, .off])
        #expect(saved.value == .off)
        #expect(settings.status == .off)
        #expect(settings.files.isReady, "kept for the next time")
        #expect(index.removed == 0)
    }

    @Test func removeDeletesTheModelAndTheVectors() async throws {
        let (settings, index, folder, _) = try make(mode: .full)
        defer { folder.remove() }
        await settings.startAndWait()

        settings.remove()

        #expect(index.applied == [.full, .off])
        #expect(index.removed == 1)
        #expect(settings.files.state == .notDownloaded)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(settings.status == .off)
    }

    @Test func aFailedDownloadSaysSoAndStartsNothing() async throws {
        let downloader = StubDownloader()
        downloader.fails.withLock { $0 = true }
        let (settings, index, folder, _) = try make(mode: .full, downloader: downloader)
        defer { folder.remove() }
        await settings.startAndWait()
        guard case .failed = settings.status else {
            Issue.record("expected failed, got \(settings.status)")
            return
        }
        #expect(settings.status.text.hasPrefix("The download failed: "))
        #expect(index.applied.isEmpty)
    }

    @Test func onIntelItIsUnavailableAndNothingDownloads() async throws {
        let downloader = StubDownloader()
        let (settings, index, folder, saved) = try make(mode: .full, isSupported: false, downloader: downloader)
        defer { folder.remove() }

        settings.setMode(.full)
        await settings.startAndWait()

        #expect(settings.status == .unavailable)
        #expect(settings.status.text == "Needs a Mac with Apple silicon")
        #expect(!settings.isEnabled)
        #expect(index.applied.isEmpty)
        #expect(downloader.requested.withLock { $0 }.isEmpty)
        #expect(saved.value == .full, "the choice is left as it was")
    }

    @Test func theSourcesPageShowsTheSectionAndRemoveOnlyWhenThereIsSomething() async throws {
        let (settings, index, folder, _) = try make()
        defer { folder.remove() }
        let page = SourcesPage(store: SourceStore(defaults: ThrowawayDefaults()), counts: { _ in nil },
                               isReading: { _ in false }, meaning: settings)

        var row = try #require(page.meaningRow)
        #expect(row.mode == .off && row.isAvailable && !row.canRemove)
        #expect(row.counts == nil)

        page.setMeaningMode(.text)
        await settings.startAndWait()
        index.progress = .init(counts: MeaningCounts(files: 8, embedded: 3, vectors: 12))
        row = try #require(page.meaningRow)
        #expect(row.mode == .text && row.canRemove && row.isWorking)
        #expect(row.counts == SourceCounts(indexed: 3, total: 8))
        #expect(row.vectors == 12)

        page.removeMeaning()
        #expect(index.removed == 1)
        #expect(page.meaningRow?.canRemove == false)
    }

    @Test func noLineOnThePageHasAnEmDash() {
        let statuses: [MeaningSettings.Status] = [
            .unavailable, .off, .downloading(progress: 0.42), .verifying, .failed("x"),
            .reading(MeaningCounts(files: 2, embedded: 1)), .paused(MeaningCounts(files: 2, embedded: 1)),
            .ready(MeaningCounts(files: 2, embedded: 2)),
        ]
        for status in statuses { #expect(!status.text.contains("\u{2014}")) }
        for mode in MeaningMode.allCases { #expect(!mode.title.contains("\u{2014}")) }
        #expect(MeaningSettings.caption == "Downloads from Hugging Face. Your files never leave this Mac.")
        #expect(MeaningMode.allCases.map(\.title) == ["Off", "Text (310 MB)", "Text, images and audio (865 MB)"])
        #expect(MeaningSettings.Status.downloading(progress: 0.427).text == "Downloading the model, 42%")
    }
}

/// Model files of a few bytes, "downloaded" from memory: held at a gate while
/// a test looks, or failing.
final class StubDownloader: ModelFileDownloader, @unchecked Sendable {
    static let contents: [String: Data] = ["a.gguf": Data("text model".utf8), "b.gguf": Data("encoders".utf8)]
    static let files: [ModelFile] = contents.keys.sorted().map { name in
        ModelFile(name: name, bytes: Int64(contents[name]!.count), sha256: SHA256.hash(data: contents[name]!).map { String(format: "%02x", $0) }.joined(),
                  url: URL(string: "https://example.invalid/\(name)")!)
    }

    let requested = Mutex<[String]>([])
    let gate = Mutex(false)
    let fails = Mutex(false)

    func download(
        from url: URL, to destination: URL, resumeData: Data?, progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        requested.withLock { $0.append(url.lastPathComponent) }
        while gate.withLock({ $0 }) { await Task.yield() }
        if fails.withLock({ $0 }) { throw ModelDownloadInterruption(reason: "offline", resumeData: nil) }
        let data = Self.contents[url.lastPathComponent]!
        progress(Int64(data.count))
        try data.write(to: destination)
    }
}
