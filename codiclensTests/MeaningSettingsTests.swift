import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import codiclens

/// Search by meaning's switch: on until turned off, so a fresh install
/// downloads the model at launch; on downloads the model,
/// then starts the pass, then says ready; off stops it; Remove deletes the
/// model and the vectors; nothing at all on Intel. Over a fake download into
/// a temporary folder and closures standing in for the File Index.
@MainActor
struct MeaningSettingsTests {
    /// What the File Index was told.
    final class Index {
        var applied: [Bool] = []
        var removed = 0
        var progress = MeaningSettings.Progress()
    }

    private func make(
        isOn: Bool = false, isSupported: Bool = true, downloader: StubDownloader = StubDownloader()
    ) throws -> (MeaningSettings, Index, TemporaryFolder, Saved) {
        let folder = try TemporaryFolder()
        let files = ModelFiles(folder: folder.url, files: StubDownloader.files, downloader: downloader)
        let saved = Saved(isOn)
        let settings = MeaningSettings(
            files: files, switch: MeaningSettings.Switch(isOn: isOn, save: { saved.value = $0 }), isSupported: isSupported
        )
        let index = Index()
        settings.apply = { index.applied.append($0) }
        settings.removeVectors = { index.removed += 1 }
        settings.progress = { index.progress }
        return (settings, index, folder, saved)
    }

    final class Saved {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    /// Nothing kept is on: a fresh install's launch (`start()`) downloads the
    /// model and starts the pass with nobody touching Settings, and the
    /// user's own off is kept as off.
    @Test func aFreshInstallIsOnAndDownloadsAtLaunchThenReads() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let downloader = StubDownloader()
        let defaults = ThrowawayDefaults()
        let settings = MeaningSettings(
            files: ModelFiles(folder: folder.url, files: StubDownloader.files, downloader: downloader),
            switch: .defaults(defaults), isSupported: true
        )
        var applied: [Bool] = []
        settings.apply = { applied.append($0) }
        #expect(settings.isEnabled)

        await settings.startAndWait()

        #expect(Set(downloader.requested.withLock { $0 }) == Set(StubDownloader.files.map(\.name)))
        #expect(applied == [true])
        settings.setEnabled(false)
        #expect(defaults.object(forKey: MeaningSettings.Switch.key) as? Bool == false)
        #expect(!MeaningSettings.Switch.defaults(defaults).isOn, "the next launch stays off")
    }

    @Test func onIntelAFreshInstallIsUnavailableAndDownloadsNothing() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let downloader = StubDownloader()
        let settings = MeaningSettings(
            files: ModelFiles(folder: folder.url, files: StubDownloader.files, downloader: downloader),
            switch: .defaults(ThrowawayDefaults()), isSupported: false
        )

        await settings.startAndWait()

        #expect(settings.status == .unavailable)
        #expect(downloader.requested.withLock { $0 }.isEmpty)
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

        settings.setEnabled(true)
        #expect(saved.value)
        let started = Task { await settings.startAndWait() }
        while downloader.requested.withLock({ $0 }).isEmpty { await Task.yield() }
        guard case .downloading = settings.status else {
            Issue.record("expected downloading, got \(settings.status)")
            return
        }
        #expect(index.applied.isEmpty, "nothing is embedded before the model is here")

        downloader.gate.withLock { $0 = false }
        await started.value
        #expect(index.applied == [true])
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
        let (settings, index, folder, saved) = try make(isOn: true)
        defer { folder.remove() }
        await settings.startAndWait()
        #expect(index.applied == [true])

        settings.setEnabled(false)
        #expect(index.applied == [true, false])
        #expect(!saved.value)
        #expect(settings.status == .off)
        #expect(settings.files.isReady, "kept for the next time")
        #expect(index.removed == 0)
    }

    @Test func removeDeletesTheModelAndTheVectors() async throws {
        let (settings, index, folder, _) = try make(isOn: true)
        defer { folder.remove() }
        await settings.startAndWait()

        settings.remove()

        #expect(index.applied == [true, false])
        #expect(index.removed == 1)
        #expect(settings.files.state == .notDownloaded)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(settings.status == .off)
    }

    @Test func aFailedDownloadSaysSoAndStartsNothing() async throws {
        let downloader = StubDownloader()
        downloader.fails.withLock { $0 = true }
        let (settings, index, folder, _) = try make(isOn: true, downloader: downloader)
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
        let (settings, index, folder, saved) = try make(isOn: true, isSupported: false, downloader: downloader)
        defer { folder.remove() }

        settings.setEnabled(true)
        await settings.startAndWait()

        #expect(settings.status == .unavailable)
        #expect(settings.status.text == "Needs a Mac with Apple silicon")
        #expect(!settings.isEnabled)
        #expect(index.applied.isEmpty)
        #expect(downloader.requested.withLock { $0 }.isEmpty)
        #expect(saved.value, "the switch is left as it was")
    }

    @Test func theSourcesPageShowsTheSectionAndRemoveOnlyWhenThereIsSomething() async throws {
        let (settings, index, folder, _) = try make()
        defer { folder.remove() }
        let page = SourcesPage(store: SourceStore(defaults: ThrowawayDefaults()), counts: { _ in nil },
                               isReading: { _ in false }, meaning: settings)

        var row = try #require(page.meaningRow)
        #expect(!row.isOn && row.isAvailable && !row.canRemove)
        #expect(row.counts == nil)

        page.setMeaningEnabled(true)
        await settings.startAndWait()
        index.progress = .init(counts: MeaningCounts(files: 8, embedded: 3, vectors: 12))
        row = try #require(page.meaningRow)
        #expect(row.isOn && row.canRemove && row.isWorking)
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
