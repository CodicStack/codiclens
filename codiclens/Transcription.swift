import AppKit
import Synchronization

/// Turning an audio or video file into text, by asking Codictate.
///
/// Codiclens has no Speech Model of its own. Codictate ships a command line,
/// `codictate`, a thin client of the running Codictate: `transcribe <file>
/// --json` hands the file to the app, which runs it through the Speech Model
/// the user picked, one File Transcription at a time, and streams what is
/// happening back as NDJSON. The client starts Codictate hidden when it is not
/// running. The contract is Codictate's `docs/CLI.md` (contract version 1):
/// where the client lives, what it prints and what its exit codes mean.
/// Nothing here goes beyond what that page promises.
///
/// `CommandCoordinator` returns `.transcribe(URL, generation:)` and knows
/// nothing about this file; `SystemEffectRunner` runs the client off the main
/// thread and answers through `onTranscriptionProgress` while it runs and
/// `onTranscription` at the end, as OCR answers through `onOCRText`. See
/// `docs/adr/0007-async-action-behind-the-effect-seam.md`.
nonisolated enum Transcription {

    /// Where to get Codictate: its website, whose front page carries the
    /// download (the "Website" line of Codictate's README). `/download` is a
    /// 404 there.
    static let downloadURL = URL(string: "https://codictate.app")!

    /// Why a Transcribe produced no text Subject. Each is a short line for the
    /// Subject Card's corner chip.
    enum Failure: Error, Equatable, Sendable {
        /// No Codictate on this Mac.
        case codictateMissing
        /// A Codictate that does not speak this contract: no client in the
        /// bundle, the old script client, a `status` that answers with another
        /// contract version, or `contract_mismatch` (exit 11).
        case codictateTooOld
        /// `app_unavailable` (exit 6): the client could not start Codictate, or
        /// it did not answer.
        case codictateUnavailable
        /// `model_not_installed` (exit 4): the Speech Model is not installed.
        case noSpeechModel
        /// `no_audio` (exit 3): no audio track.
        case noAudio
        /// `input_unreadable` (also exit 3): Codictate cannot read the file.
        case unreadable
        /// The command ran and heard nothing. Decided by the coordinator from
        /// an empty transcript, as OCR decides "no text".
        case noSpeech
        /// `cancelled` (exit 130 or 143), or the client stopped by a signal.
        /// Codiclens only ever cancels a run nobody waits for any more, so this
        /// is never said to the user.
        case cancelled
        /// Everything else: `internal`, `usage`, `engine_failed`, output that
        /// is not the contract this side knows.
        case failed

        var note: String {
            switch self {
            case .codictateMissing: "Get Codictate to transcribe"
            case .codictateTooOld: "Update Codictate to transcribe"
            case .codictateUnavailable: "Couldn't start Codictate"
            case .noSpeechModel: "Pick a speech model in Codictate"
            case .noAudio: "No audio in this file"
            case .unreadable: "Can't read this file"
            case .noSpeech: "No speech found"
            case .cancelled: "Cancelled"
            case .failed: "Couldn't transcribe"
            }
        }

        /// Whether the way forward is Codictate's website, which the next
        /// Enter on Transcribe opens.
        var offersDownload: Bool {
            self == .codictateMissing || self == .codictateTooOld
        }
    }

    // MARK: - Finding the client

    /// Stable first, then canary, as the contract asks. `app.codictate.dev`
    /// is a local development build and is deliberately not looked for.
    static let bundleIdentifiers = ["app.codictate", "app.codictate.canary"]

    /// Where the client sits inside the app bundle. Part of the contract.
    static let commandPath = "Contents/Resources/app/bin/codictate"

    enum Location: Equatable, Sendable {
        case found(URL)
        case missing
        case tooOld
        /// A client of this contract whose app could not be started.
        case unavailable
    }

    /// What a client's `status --json` says about it.
    enum Compatibility: Equatable, Sendable {
        /// Contract version 1.
        case compatible
        /// Not a Mach-O, does not know `status`, or another contract version.
        case tooOld
        /// Exit 6: the client could not reach its app. Says nothing about the
        /// contract, so it is asked again next time.
        case unavailable
        /// Any other failure of `status` (an internal error, a signal). Not
        /// held against the client: the transcribe call that follows reports
        /// what is wrong with its own exit code.
        case unknown
    }

    /// The installed client, looked up by bundle identifier.
    ///
    /// The first app whose client speaks this contract wins; an app found
    /// without one means that Codictate predates it.
    ///
    /// - Parameters:
    ///   - application: the lookup by bundle identifier. Launch Services in
    ///     the app; a test hands in its own folders.
    ///   - compatibility: whether a client speaks this contract. Asks the
    ///     client itself, once per client binary; a test answers for it.
    static func locate(
        bundleIdentifiers: [String] = bundleIdentifiers,
        application: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        compatibility: (URL) -> Compatibility = { Transcription.compatibility(of: $0) }
    ) -> Location {
        let apps = bundleIdentifiers.compactMap(application)
        guard !apps.isEmpty else { return .missing }
        var unavailable = false
        for app in apps {
            let client = app.appendingPathComponent(commandPath)
            guard FileManager.default.isExecutableFile(atPath: client.path) else { continue }
            switch compatibility(client) {
            case .compatible, .unknown: return .found(client)
            case .unavailable: unavailable = true
            case .tooOld: continue
            }
        }
        return unavailable ? .unavailable : .tooOld
    }

    // MARK: - Is it this contract?

    /// The contract version this side understands. Another one changed or
    /// removed something existing (the versioning promise), so it is not read
    /// as this one.
    static let contractVersion = 1

    /// What each client binary said, by path and modification date: asked
    /// once, and again after Codictate updates. `status` may start Codictate,
    /// which is fine once and wasteful on every Transcribe.
    private static let compatibilityCache = Mutex<[String: Compatibility]>([:])

    /// Whether `client` speaks this contract: a Mach-O (the Rust client; the
    /// one before it was a script) whose `status --json` reports contract
    /// version 1. A definite answer is kept for this binary.
    ///
    /// Blocks on `status`, which can start Codictate hidden and wait up to
    /// 30 s for it, so it is never called on the main thread.
    static func compatibility(of client: URL) -> Compatibility {
        guard isMachO(client) else { return .tooOld }
        let modified = (try? client.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(client.path)|\(modified?.timeIntervalSinceReferenceDate ?? 0)"
        if let known = compatibilityCache.withLock({ $0[key] }) { return known }
        let answer = status(of: client)
        if answer == .compatible || answer == .tooOld {
            compatibilityCache.withLock { $0[key] = answer }
        }
        return answer
    }

    /// Whether the file starts with a Mach-O or universal binary's magic.
    static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 4), bytes.count == 4 else { return false }
        let magic = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return [0xFEED_FACE, 0xFEED_FACF, 0xCEFA_EDFE, 0xCFFA_EDFE, 0xCAFE_BABE, 0xCAFE_BABF].contains(magic)
    }

    /// Runs `client status --json` and reads its contract version.
    static func status(of client: URL) -> Compatibility {
        let process = process(client, ["status", "--json"])
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .unknown }
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit else { return .unknown }
        return compatibility(statusExit: process.terminationStatus, stdout: stdout)
    }

    /// What one `status --json` amounts to.
    static func compatibility(statusExit: Int32, stdout: Data) -> Compatibility {
        switch statusExit {
        case 0:
            let version = lines(of: stdout)
                .compactMap { try? JSONDecoder().decode(StatusResult.self, from: $0) }
                .last { $0.type == "result" }?.contractVersion
            return version == contractVersion ? .compatible : .tooOld
        // A usage error: a client that does not know `status`.
        case 2, 11: return .tooOld
        case 6: return .unavailable
        default: return .unknown
        }
    }

    private struct StatusResult: Decodable {
        let type: String
        let contractVersion: Int?
    }

    // MARK: - Reading the events

    /// Where a running File Transcription is, for the Subject Card's corner.
    enum Progress: Equatable, Sendable {
        /// Waiting behind other File Transcriptions; `1` is next.
        case queued(position: Int)
        case running(Stage, elapsedSeconds: Double, audioSeconds: Double?)

        enum Stage: String, Sendable {
            case decoding, transcribing
        }

        /// Codictate's own words for the same states in its window, so the
        /// two never describe one job differently.
        var note: String {
            switch self {
            case .queued(let position):
                let ahead = position - 1
                return ahead <= 0 ? "Next up" : "Waiting, \(ahead) ahead"
            case .running(let stage, let elapsed, let audio):
                var parts = [stage == .decoding ? "Reading the file" : "Transcribing", Transcription.clock(elapsed)]
                if let audio { parts.append("\(Transcription.clock(audio)) of audio") }
                return parts.joined(separator: " · ")
            }
        }
    }

    /// `0:42`, `52:01`, `1:02:03`.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// One line of `--json` output, as far as Transcribe cares.
    enum Event: Equatable, Sendable {
        case progress(Progress)
        case result(text: String)
        case error(code: String)
    }

    /// The fields this side reads. Anything else is ignored, as the contract
    /// asks: new fields and event types arrive without a version bump.
    private struct WireEvent: Decodable {
        let type: String
        let position: Int?
        let stage: String?
        let elapsedSeconds: Double?
        let audioSeconds: Double?
        let text: String?
        let code: String?
    }

    /// The event on one line, or `nil` for a type, stage or line this side
    /// does not know.
    static func event(from line: Data) -> Event? {
        guard let wire = try? JSONDecoder().decode(WireEvent.self, from: line) else { return nil }
        switch wire.type {
        case "queued":
            guard let position = wire.position else { return nil }
            return .progress(.queued(position: position))
        case "progress":
            guard let stage = wire.stage.flatMap(Progress.Stage.init(rawValue:)) else { return nil }
            return .progress(.running(stage, elapsedSeconds: wire.elapsedSeconds ?? 0, audioSeconds: wire.audioSeconds))
        case "result":
            guard let text = wire.text else { return nil }
            return .result(text: text)
        case "error":
            return .error(code: wire.code ?? "")
        default:
            return nil
        }
    }

    /// The non-empty lines of a whole output.
    static func lines(of data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
    }

    // MARK: - What a run amounts to

    /// The run's end: the transcript as printed, empty when there was silence
    /// (whether that is "No speech found" is the coordinator's call), or why
    /// there is none. The `error` event's code says more than the exit code
    /// (3 is two different things), so it is asked first.
    static func result(exitStatus: Int32, transcript: String?, errorCode: String?) -> Result<String, Failure> {
        if exitStatus == 0, let transcript { return .success(transcript) }
        if let errorCode, let failure = failure(forErrorCode: errorCode) { return .failure(failure) }
        return .failure(failure(forExitStatus: exitStatus))
    }

    /// The contract's error codes, as the user is told them. `nil` for one
    /// that the exit code says as much about.
    static func failure(forErrorCode code: String) -> Failure? {
        switch code {
        case "no_audio": .noAudio
        case "input_unreadable": .unreadable
        case "model_not_installed": .noSpeechModel
        case "app_unavailable": .codictateUnavailable
        case "contract_mismatch": .codictateTooOld
        case "cancelled": .cancelled
        default: nil
        }
    }

    /// The contract's exit codes, as the user is told them.
    static func failure(forExitStatus status: Int32) -> Failure {
        switch status {
        case 3: .noAudio
        case 4: .noSpeechModel
        case 6: .codictateUnavailable
        case 11: .codictateTooOld
        case 130, 143: .cancelled
        default: .failed
        }
    }

    // MARK: - Running the client

    /// What the client inherits of the app's environment: the basics and
    /// nothing else. In the unit-test host the environment carries XCTest's
    /// `DYLD_INSERT_LIBRARIES` and `XCTestConfigurationFilePath`, which have no
    /// business in Codictate. `HOME` is how the client finds its app's socket.
    static let inherited: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "SHELL"]

    static func process(_ client: URL, _ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = client
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.filter { inherited.contains($0.key) }
        process.qualityOfService = .userInitiated
        return process
    }
}

/// One run of `codictate transcribe --json`, which can be cancelled from
/// another thread.
///
/// `perform(with:progress:)` blocks until the client exits, so the runner calls
/// it off the main thread; `cancel()` comes from the main thread when the Panel
/// session moves on. Cancelling is SIGTERM: the client forwards the cancel to
/// Codictate, which drops the job (queued or running), and exits 143, an
/// answer nobody is waiting for any more.
///
/// Made before the client is looked up, so a cancel that arrives while it is
/// being looked up still stops the run from starting.
nonisolated final class TranscriptionRun: @unchecked Sendable {
    private let file: URL

    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    init(file: URL) {
        self.file = file
    }

    /// - Parameter progress: each `queued` and `progress` event as it arrives,
    ///   on this thread, in order.
    func perform(
        with command: URL,
        progress: (Transcription.Progress) -> Void = { _ in }
    ) -> Result<String, Transcription.Failure> {
        // An absolute path never starts with `-`, so it needs no `--`.
        let process = Transcription.process(command, ["transcribe", file.path, "--json"])
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        // Started under the lock, so a `cancel()` either comes first and the
        // run never starts, or comes after and finds a process to stop.
        let started: Bool = lock.withLock {
            guard !isCancelled, (try? process.run()) != nil else { return false }
            self.process = process
            return true
        }
        guard started else { return .failure(lock.withLock { isCancelled } ? .cancelled : .failed) }

        // stderr is one `codictate: ` line on failure: for the log, never for
        // the user. Drained beside stdout so neither pipe can fill and stall
        // the client.
        let stderr = Diagnostics()
        let stderrDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            stderr.data = errors.fileHandleForReading.readDataToEndOfFile()
            stderrDone.signal()
        }

        // Line by line as it arrives: a queued job can wait minutes, and a
        // long recording reports progress about once a second.
        var transcript: String?
        var errorCode: String?
        var pending = Data()
        func handle(_ line: Data) {
            switch Transcription.event(from: line) {
            case .progress(let update): progress(update)
            case .result(let text): transcript = text
            case .error(let code): errorCode = code
            case nil: break
            }
        }
        let reader = output.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: UInt8(ascii: "\n")) {
                handle(Data(pending[start..<newline]))
                start = pending.index(after: newline)
            }
            pending = Data(pending[start...])
        }
        if !pending.isEmpty { handle(pending) }

        process.waitUntilExit()
        stderrDone.wait()
        lock.withLock { self.process = nil }

        let diagnostics = String(decoding: stderr.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !diagnostics.isEmpty { NSLog("Transcribe: %@", diagnostics) }

        guard process.terminationReason == .exit else { return .failure(.cancelled) }
        return Transcription.result(exitStatus: process.terminationStatus, transcript: transcript, errorCode: errorCode)
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }
}

/// The client's stderr, written by the thread that drains it and read after
/// that thread signals it is done.
private nonisolated final class Diagnostics: @unchecked Sendable {
    var data = Data()
}
