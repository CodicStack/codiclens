import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import codiclens

/// The model download's state machine over a fake downloader and small files
/// of the test's own: nothing here touches the network or Application
/// Support.
@MainActor
struct ModelFilesTests {

    @Test func theRealFilesArePinnedToOneRevisionAndNeverF16() {
        for file in ModelFiles.all {
            #expect(file.url.absoluteString.contains("/resolve/\(ModelFiles.revision)/"))
            #expect(file.sha256.count == 64)
            #expect(!file.name.contains("F16"))
        }
        #expect(ModelFiles.all.map(\.name) == ["embeddinggemma-2-Q8_0.gguf", "mmproj-embeddinggemma-2-Q8_0.gguf"])
        #expect(ModelFiles.defaultFolder.path.hasSuffix("Application Support/codiclens/models"))
    }

    @Test func anEmptyFolderIsNotDownloaded() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fixture = Fixture()
        let files = ModelFiles(folder: folder.url, files: fixture.files, downloader: fixture.downloader)
        #expect(files.state == .notDownloaded)
        #expect(!files.isReady)
    }

    @Test func downloadingChecksAndKeepsEachFile() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fixture = Fixture()
        let files = ModelFiles(folder: folder.url, files: fixture.files, downloader: fixture.downloader)

        await files.download()

        #expect(files.state == .ready)
        for file in fixture.files {
            #expect(try Data(contentsOf: files.location(of: file)) == fixture.contents[file.name])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["a.gguf", "b.gguf"])
        // Being there is enough the next time.
        #expect(ModelFiles(folder: folder.url, files: fixture.files, downloader: fixture.downloader).isReady)
    }

    @Test func aFileThatFailsItsChecksumIsNotKept() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fixture = Fixture()
        fixture.downloader.corrupt.withLock { $0 = ["b.gguf"] }
        let files = ModelFiles(folder: folder.url, files: fixture.files, downloader: fixture.downloader)

        await files.download()

        guard case .failed(let reason) = files.state else {
            Issue.record("expected failed, got \(files.state)")
            return
        }
        #expect(reason.contains("b.gguf") && reason.contains("checksum"))
        // The good file stays; the bad one leaves nothing behind under any name.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["a.gguf"])

        // Fixed upstream: the next attempt fetches only what is missing.
        fixture.downloader.corrupt.withLock { $0 = [] }
        await files.download()
        #expect(files.state == .ready)
        #expect(fixture.downloader.requested.withLock { $0 } == ["a.gguf", "b.gguf", "b.gguf"])
    }

    @Test func anInterruptedDownloadResumesFromWhereItStopped() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fixture = Fixture()
        fixture.downloader.interrupt.withLock { $0 = ["a.gguf"] }
        let files = ModelFiles(folder: folder.url, files: fixture.files, downloader: fixture.downloader)

        await files.download()

        #expect(files.state == .failed("The network connection was lost."))
        let resume = folder.url.appendingPathComponent("a.gguf.resume")
        #expect(try Data(contentsOf: resume) == Data("a.gguf: 3 bytes in".utf8))

        await files.download()

        #expect(files.state == .ready)
        #expect(fixture.downloader.resumedWith.withLock { $0 } == [Data("a.gguf: 3 bytes in".utf8)])
        #expect(!FileManager.default.fileExists(atPath: resume.path))
    }

    @Test func progressCoversBothFilesAndOnlyMovesForward() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fixture = Fixture()
        let files = ModelFiles(folder: folder.url, files: fixture.files, downloader: fixture.downloader)
        let seen = Mutex<[Double]>([])
        fixture.downloader.onProgress = { @Sendable in
            await MainActor.run {
                if case .downloading(let progress) = files.state { seen.withLock { $0.append(progress) } }
            }
        }

        await files.download()

        let progress = seen.withLock { $0 }
        #expect(!progress.isEmpty)
        #expect(progress == progress.sorted())
        #expect(progress.allSatisfy { (0...1).contains($0) })
    }

    // MARK: - Fixture

    /// Two small files with their true sizes and SHA-256s, and a downloader
    /// that writes them.
    private final class Fixture {
        let contents: [String: Data] = [
            "a.gguf": Data((0..<1000).map { UInt8($0 % 251) }),
            "b.gguf": Data((0..<3000).map { UInt8($0 % 241) }),
        ]
        let downloader: FakeDownloader

        var files: [ModelFile] {
            contents.keys.sorted().map { name in
                let data = contents[name]!
                return ModelFile(
                    name: name, bytes: Int64(data.count),
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    url: URL(string: "https://example.invalid/\(name)")!
                )
            }
        }

        init() {
            downloader = FakeDownloader(contents: contents)
        }
    }
}

/// Writes known bytes, and can be told to corrupt or break off a file.
private final class FakeDownloader: ModelFileDownloader, @unchecked Sendable {
    let contents: [String: Data]
    let corrupt = Mutex<Set<String>>([])
    /// Broken off once each, with resume data.
    let interrupt = Mutex<Set<String>>([])
    let requested = Mutex<[String]>([])
    let resumedWith = Mutex<[Data]>([])
    var onProgress: (@Sendable () async -> Void)?

    init(contents: [String: Data]) {
        self.contents = contents
    }

    func download(
        from url: URL, to destination: URL, resumeData: Data?, progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let name = url.lastPathComponent
        requested.withLock { $0.append(name) }
        if let resumeData { resumedWith.withLock { $0.append(resumeData) } }
        if interrupt.withLock({ $0.remove(name) }) != nil {
            throw ModelDownloadInterruption(
                reason: "The network connection was lost.", resumeData: Data("\(name): 3 bytes in".utf8)
            )
        }
        var data = contents[name]!
        if corrupt.withLock({ $0.contains(name) }) { data[0] ^= 0xFF }
        progress(Int64(data.count / 2))
        await onProgress?()
        progress(Int64(data.count))
        await onProgress?()
        try data.write(to: destination)
    }
}
