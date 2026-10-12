import AppKit

/// Turning an audio or video file into text, by asking Codictate.
///
/// Codiclens has no Speech Model of its own. Codictate ships a small command
/// line, `codictate transcribe <file> --json`, that runs whichever Speech Model
/// the user picked in Codictate's Settings, and this is its one caller here.
/// The contract is Codictate's `docs/TRANSCRIBE_CLI.md`: where the command
/// lives, what it prints and what its exit codes mean. Nothing here goes
/// beyond what that page promises.
///
/// `CommandCoordinator` returns `.transcribe(URL, generation:)` and knows
/// nothing about this file; `SystemEffectRunner` runs the command off the main
/// thread and answers through `onTranscription`, as OCR answers through
/// `onOCRText`. See `docs/adr/0007-async-action-behind-the-effect-seam.md`.
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
        /// A Codictate older than the command: the app is there, its
        /// `bin/codictate` is not.
        case codictateTooOld
        /// Exit 4: the Speech Model selected in Codictate is not installed.
        case noSpeechModel
        /// Exit 3: unreadable, not audio or video, or no audio track.
        case noAudio
        /// The command ran and heard nothing. Decided by the coordinator from
        /// an empty transcript, as OCR decides "no text".
        case noSpeech
        /// Everything else: an internal error (1), a usage error (2), the
        /// Speech Engine failing (5), a signal, output that is not the
        /// contract this side knows.
        case failed

        var note: String {
            switch self {
            case .codictateMissing: "Get Codictate to transcribe"
            case .codictateTooOld: "Update Codictate to transcribe"
            case .noSpeechModel: "Pick a speech model in Codictate"
            case .noAudio: "No audio in this file"
            case .noSpeech: "No speech found"
            case .failed: "Couldn't transcribe"
            }
        }

        /// Whether the way forward is Codictate's website, which the next
        /// Enter on Transcribe opens.
        var offersDownload: Bool {
            self == .codictateMissing || self == .codictateTooOld
        }
    }

    // MARK: - Finding the command

    /// Stable first, then canary, as the contract asks. `app.codictate.dev`
    /// is a local development build and is deliberately not looked for.
    static let bundleIdentifiers = ["app.codictate", "app.codictate.canary"]

    /// Where the command sits inside the app bundle. Part of the contract.
    static let commandPath = "Contents/Resources/app/bin/codictate"

    enum Location: Equatable, Sendable {
        case found(URL)
        case missing
        case tooOld
    }

    /// The installed command, looked up by bundle identifier.
    ///
    /// The first app that carries an executable command wins; an app found
    /// without one means that Codictate predates it.
    ///
    /// - Parameter application: the lookup by bundle identifier. Launch
    ///   Services in the app; a test hands in its own folders.
    static func locate(
        bundleIdentifiers: [String] = bundleIdentifiers,
        application: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    ) -> Location {
        let apps = bundleIdentifiers.compactMap(application)
        let command = apps
            .map { $0.appendingPathComponent(commandPath) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        if let command { return .found(command) }
        return apps.isEmpty ? .missing : .tooOld
    }

    // MARK: - Reading the answer

    /// The contract version this side understands. A higher one changed or
    /// removed something existing (the versioning promise), so it is not read
    /// as this one.
    static let contractVersion = 1

    /// The fields of `--json` this side reads. Anything else in the object is
    /// ignored, as the contract asks: new fields arrive without a version bump.
    private struct Output: Decodable {
        let contractVersion: Int
        let text: String
    }

    /// What one run of the command amounts to.
    ///
    /// The transcript as printed, empty when there was silence; whether that
    /// is "No speech found" is the coordinator's call.
    static func result(exitStatus: Int32, stdout: Data) -> Result<String, Failure> {
        guard exitStatus == 0 else { return .failure(failure(forExitStatus: exitStatus)) }
        guard let output = try? JSONDecoder().decode(Output.self, from: stdout),
              output.contractVersion == contractVersion else { return .failure(.failed) }
        return .success(output.text)
    }

    /// The contract's exit codes, as the user is told them.
    static func failure(forExitStatus status: Int32) -> Failure {
        switch status {
        case 3: .noAudio
        case 4: .noSpeechModel
        default: .failed
        }
    }

    /// What the command inherits of the app's environment: the basics and
    /// nothing else. In the unit-test host the environment carries XCTest's
    /// `DYLD_INSERT_LIBRARIES` and `XCTestConfigurationFilePath`, which have no
    /// business in Codictate's runtime. `HOME` is how it finds Codictate's
    /// config, and `TMPDIR` where it decodes.
    static let inherited: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "SHELL"]
}

/// One run of `codictate transcribe`, which can be cancelled from another
/// thread.
///
/// `perform(with:)` blocks until the command exits, so the runner calls it off
/// the main thread; `cancel()` comes from the main thread when the Panel
/// session moves on. Cancelling is SIGTERM, which the contract says stops the
/// Speech Engine too and removes its temp folder; the command then exits 143,
/// an answer nobody is waiting for any more.
///
/// Made before the command is looked up, so a cancel that arrives while it is
/// being looked up still stops the run from starting.
nonisolated final class TranscriptionRun: @unchecked Sendable {
    private let file: URL

    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    init(file: URL) {
        self.file = file
    }

    func perform(with command: URL) -> Result<String, Transcription.Failure> {
        let process = Process()
        process.executableURL = command
        // An absolute path never starts with `-`, so it needs no `--`.
        process.arguments = ["transcribe", file.path, "--json"]
        process.environment = ProcessInfo.processInfo.environment.filter {
            Transcription.inherited.contains($0.key)
        }
        process.qualityOfService = .userInitiated
        let output = Pipe()
        process.standardOutput = output
        // stderr is the app's: the one `codictate: ` line a failure prints
        // lands in its log.

        // Started under the lock, so a `cancel()` either comes first and the
        // run never starts, or comes after and finds a process to stop.
        let started: Bool = lock.withLock {
            guard !isCancelled, (try? process.run()) != nil else { return false }
            self.process = process
            return true
        }
        guard started else { return .failure(.failed) }

        // Read to the end before waiting: a transcript longer than the pipe's
        // buffer would otherwise hold the command up writing it.
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        lock.withLock { self.process = nil }

        guard process.terminationReason == .exit else { return .failure(.failed) }
        return Transcription.result(exitStatus: process.terminationStatus, stdout: stdout)
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }
}
