// The pinned files and their checks are DigUp's (https://github.com/ARahim3/DigUp, MIT; see digup-license.txt).

import CryptoKit
import Foundation
import Synchronization

/// One of the GGUF files search by meaning runs, at the pinned revision.
nonisolated struct ModelFile: Hashable, Sendable {
    let name: String
    let bytes: Int64
    /// Lowercase hex.
    let sha256: String
    let url: URL
}

/// The EmbeddingGemma 2 files on this Mac: ggml-org's Q8_0 conversion at one
/// pinned revision, downloaded when the user chooses search by meaning and
/// checked against their size and SHA-256 before they get their real names.
/// A file under its real name in `folder` is therefore always whole, and the
/// wanted ones being there is all `isReady` asks.
///
/// - Every file is wanted unless told otherwise (`want`): the Text choice
///   wants the text model alone, and adding the encoders later wants both.
///
/// Never the F16 files: the model's activations overflow float16.
///
/// - Resumable: a download that fails or is cancelled leaves its URLSession
///   resume data beside the files (`<name>.resume`), and the next `download()`
///   carries on from there, after a relaunch too.
/// - The folder is excluded from Time Machine; the files can always be fetched
///   again.
///
/// It never starts by itself.
@Observable
final class ModelFiles {
    enum State: Equatable {
        case notDownloaded
        /// Over both files, 0...1, what earlier attempts left included.
        case downloading(progress: Double)
        case verifying
        case ready
        case failed(String)
    }

    nonisolated static let repository = "ggml-org/embeddinggemma-2-GGUF"
    /// The repository's only upload (2026-10-06), made from
    /// google/embeddinggemma-2 by llama.cpp's converter.
    nonisolated static let revision = "bfcd298762cc34d0357ece5ebdd31791a3a374d8"

    /// The text model (310 MB): all a Query needs.
    nonisolated static let text = file(
        "embeddinggemma-2-Q8_0.gguf", bytes: 309_855_456,
        sha256: "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135"
    )
    /// The image and audio encoders (555 MB).
    nonisolated static let media = file(
        "mmproj-embeddinggemma-2-Q8_0.gguf", bytes: 554_821_024,
        sha256: "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f"
    )
    /// In download order: the text model first, so a Query can be embedded
    /// while the encoders are still on their way.
    nonisolated static let all = [text, media]

    /// `~/Library/Application Support/codiclens/models`.
    nonisolated static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("codiclens")
            .appendingPathComponent("models")
    }

    /// Hugging Face's address for `name` at the pinned revision. It redirects
    /// to a CDN that takes HTTP ranges, which is what makes resuming work.
    nonisolated private static func file(_ name: String, bytes: Int64, sha256: String) -> ModelFile {
        let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(name)")!
        return ModelFile(name: name, bytes: bytes, sha256: sha256, url: url)
    }

    let folder: URL
    /// Every file, the text model first.
    let files: [ModelFile]
    /// What `download()` fetches and `isReady` asks for: a prefix of `files`.
    private(set) var wanted: [ModelFile]
    private(set) var state: State

    @ObservationIgnored private let downloader: any ModelFileDownloader
    @ObservationIgnored private var running: Task<Void, Never>?
    /// Which download `running` is, so a cancelled one that ends late does
    /// not forget a newer one.
    @ObservationIgnored private var runs = 0

    init(
        folder: URL = ModelFiles.defaultFolder,
        files: [ModelFile] = ModelFiles.all,
        downloader: any ModelFileDownloader = URLSessionModelFileDownloader()
    ) {
        self.folder = folder
        self.files = files
        self.downloader = downloader
        wanted = files
        state = .notDownloaded
        state = settled
    }

    var isReady: Bool { state == .ready }

    /// The text model (310 MB): all a Query and the Text choice need.
    var textModel: ModelFile { files[0] }

    /// From now on `download()` fetches `files` and `isReady` asks for them.
    /// Call `cancel()` first to stop a download of what is no longer wanted.
    func want(_ files: [ModelFile]) {
        guard files != wanted else { return }
        wanted = files
        if running == nil { state = settled }
    }

    /// Something is on disk: a file, whole or partial, or its resume data.
    var hasAnything: Bool {
        files.contains { file in
            [file.name, file.name + ".download", file.name + ".resume"].contains {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
        }
    }

    /// Where `file` lives once it has been checked.
    func location(of file: ModelFile) -> URL {
        folder.appendingPathComponent(file.name)
    }

    private var missing: [ModelFile] {
        wanted.filter { !FileManager.default.fileExists(atPath: location(of: $0).path) }
    }

    /// The state with no download running.
    private var settled: State {
        missing.isEmpty ? .ready : .notDownloaded
    }

    /// Downloads and checks whatever wanted file is missing, and returns when
    /// that has settled: `ready`, `failed`, or as `cancel()` left it. A
    /// second call while one runs waits for the same download; one after a
    /// `cancel()` waits for the cancelled one to put its resume data down,
    /// then starts afresh.
    func download() async {
        if let running, !running.isCancelled { return await running.value }
        while let running { await running.value }
        runs += 1
        let run = runs
        let task = Task {
            await fetchMissing()
            if runs == run { running = nil }
        }
        running = task
        await task.value
    }

    /// Stops the download, keeping what arrived for the next `download()`.
    func cancel() {
        running?.cancel()
    }

    /// Stops any download and deletes the files, checked or partial, with
    /// their resume data: "Remove" in Settings. The folder stays.
    func remove() {
        cancel()
        for file in files {
            for name in [file.name, file.name + ".download", file.name + ".resume"] {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        state = .notDownloaded
    }

    private func fetchMissing() async {
        let missing = self.missing
        guard !missing.isEmpty else { return state = .ready }
        let wanted = self.wanted
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var folder = self.folder
            try? folder.setResourceValues(values)
        } catch {
            return state = .failed("Can't create \(folder.path): \(error.localizedDescription)")
        }
        let total = wanted.reduce(0) { $0 + $1.bytes }
        var done = wanted.filter { !missing.contains($0) }.reduce(0) { $0 + $1.bytes }
        for file in missing {
            let staging = folder.appendingPathComponent(file.name + ".download")
            let resume = folder.appendingPathComponent(file.name + ".resume")
            state = .downloading(progress: Double(done) / Double(total))
            do {
                try await downloader.download(
                    from: file.url, to: staging, resumeData: try? Data(contentsOf: resume),
                    progress: progressReporter(done: done, total: total)
                )
            } catch let interruption as ModelDownloadInterruption {
                if let data = interruption.resumeData { try? data.write(to: resume) }
                state = Task.isCancelled ? settled : .failed(interruption.reason)
                return
            } catch {
                state = Task.isCancelled ? settled : .failed(error.localizedDescription)
                return
            }
            try? FileManager.default.removeItem(at: resume)

            state = .verifying
            let checked = await Task.detached { Self.matches(staging, file) }.value
            guard checked else {
                try? FileManager.default.removeItem(at: staging)
                return state = .failed("\(file.name) did not match its checksum. Try again.")
            }
            do {
                try FileManager.default.moveItem(at: staging, to: location(of: file))
            } catch where FileManager.default.fileExists(atPath: location(of: file).path) {
                // Another copy of the app got there first, and only a checked
                // file gets that name.
                try? FileManager.default.removeItem(at: staging)
            } catch {
                return state = .failed("Can't keep \(file.name): \(error.localizedDescription)")
            }
            done += file.bytes
        }
        state = settled
    }

    /// A progress callback for the downloader's thread that comes to the main
    /// actor only when the fraction moves by a tenth of a percent, rather than
    /// for every packet.
    private func progressReporter(done: Int64, total: Int64) -> @Sendable (Int64) -> Void {
        let lastPermille = Mutex(-1)
        return { [weak self] received in
            let fraction = min(1, Double(done + received) / Double(total))
            let permille = Int(fraction * 1000)
            guard lastPermille.withLock({ last in
                defer { last = max(last, permille) }
                return permille > last
            }), let files = self else { return }
            Task { @MainActor in
                guard case .downloading(let shown) = files.state, fraction > shown else { return }
                files.state = .downloading(progress: fraction)
            }
        }
    }

    /// The exact size and SHA-256 `file` was pinned with.
    nonisolated static func matches(_ url: URL, _ file: ModelFile) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        guard size == file.bytes else { return false }
        return (try? sha256(of: url)) == file.sha256
    }

    /// Lowercase hex, read 8 MB at a time.
    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 8 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Fetches one URL into a file. URLSession in the app, a fake in tests.
nonisolated protocol ModelFileDownloader: Sendable {
    /// Downloads `url` to `destination`, replacing anything there, carrying on
    /// from `resumeData` when it is given. `progress` is called with the bytes
    /// received so far, from any thread. A download that stops short throws
    /// `ModelDownloadInterruption`, with resume data when the server allows.
    func download(
        from url: URL, to destination: URL, resumeData: Data?, progress: @escaping @Sendable (Int64) -> Void
    ) async throws
}

/// A download that stopped before the end: the network went, the server said
/// no, or it was cancelled.
nonisolated struct ModelDownloadInterruption: Error {
    let reason: String
    let resumeData: Data?
}

/// `ModelFileDownloader` over a URLSession download task, one session per
/// file.
nonisolated final class URLSessionModelFileDownloader: ModelFileDownloader {
    func download(
        from url: URL, to destination: URL, resumeData: Data?, progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.start(continuation)
                task.resume()
            }
        } onCancel: {
            delegate.cancel(task)
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destination: URL
        private let progress: @Sendable (Int64) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var pendingResult: Result<Void, Error>?
        private var cancelling = false
        /// What went wrong between the file landing and the task completing.
        private var failure: Error?

        init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func start(_ continuation: CheckedContinuation<Void, Error>) {
            let result: Result<Void, Error>? = lock.withLock {
                guard pendingResult == nil else { return pendingResult }
                self.continuation = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }

        /// Cancelled with resume data; the task's own completion, a cancel
        /// error, is ignored for this answer.
        func cancel(_ task: URLSessionDownloadTask) {
            lock.withLock { cancelling = true }
            task.cancel { [self] data in
                finish(.failure(ModelDownloadInterruption(reason: "Cancelled", resumeData: data)))
            }
        }

        /// The first result wins.
        private func finish(_ result: Result<Void, Error>) {
            let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
                guard pendingResult == nil else { return nil }
                pendingResult = result
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(with: result)
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            progress(totalBytesWritten)
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
        ) {
            // The file at `location` is deleted when this returns, so it is
            // moved now or never.
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let answer = ModelDownloadInterruption(reason: "The server answered \(status)", resumeData: nil)
                lock.withLock { failure = answer }
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                lock.withLock { failure = error }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (cancelling, failure) = lock.withLock { (self.cancelling, self.failure) }
            if let error {
                if cancelling { return }
                let urlError = error as? URLError
                finish(.failure(ModelDownloadInterruption(
                    reason: error.localizedDescription, resumeData: urlError?.downloadTaskResumeData
                )))
            } else if let failure {
                finish(.failure(failure))
            } else {
                finish(.success(()))
            }
        }
    }
}
