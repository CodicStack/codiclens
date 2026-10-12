import AppKit
import Foundation
import Testing
@testable import codiclens

private let realCommand = ProcessInfo.processInfo.environment["CODICLENS_TRANSCRIBE"]

/// The other side of the seam: `SystemEffectRunner` running a `codictate`
/// command and answering with what it amounted to.
///
/// **The real Codictate is not needed.** Each test writes a small shell script
/// that plays the command's part (prints the contract's JSON, or exits with one
/// of its codes) and hands it to the runner as the command it found.
/// `RealCodictateTranscriptionTests` below runs the installed one, when asked.
@MainActor
struct TranscriptionTests {

    // MARK: - Fixtures

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-transcription-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// An executable `/bin/sh` script named `codictate` in `folder`.
    @discardableResult
    private func script(_ body: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("codictate")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private static let audio = URL(fileURLWithPath: "/tmp/codiclens-fixture/memo.m4a")

    private func makeRunner(_ location: Transcription.Location) -> (SystemEffectRunner, NSPasteboard) {
        let pasteboard = NSPasteboard(name: .init("codiclens-tests-\(UUID().uuidString)"))
        return (SystemEffectRunner(pasteboard: pasteboard, codictate: { location }), pasteboard)
    }

    /// Runs `.transcribe` through a runner whose command is at `location`, and
    /// waits for the answer.
    private func transcribe(
        with location: Transcription.Location,
        generation: Int = 7
    ) async -> (Int, Result<String, Transcription.Failure>) {
        let (runner, pasteboard) = makeRunner(location)
        defer { pasteboard.releaseGlobally() }
        return await withCheckedContinuation { continuation in
            runner.onTranscription = { generation, result in
                #expect(Thread.isMainThread)
                continuation.resume(returning: (generation, result))
            }
            runner.run([.transcribe(Self.audio, generation: generation)])
        }
    }

    private func answer(_ body: String) async throws -> Result<String, Transcription.Failure> {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        return await transcribe(with: .found(try script(body, in: root))).1
    }

    // MARK: - Success

    @Test func theTranscriptComesBackWithItsGeneration() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try script("""
            printf '%s\\n' "$@" > "\(root.path)/arguments"
            env > "\(root.path)/environment"
            echo '{"contractVersion":1,"text":"The quick brown fox.","language":null,"speechModelId":"large-v3-turbo-q5_0","engine":"whisper","durationSeconds":1.439,"segments":[]}'
            """, in: root)

        let (generation, result) = await transcribe(with: .found(command), generation: 12)

        #expect(generation == 12)
        #expect(result == .success("The quick brown fox."))
        let arguments = try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8)
        #expect(arguments == "transcribe\n\(Self.audio.path)\n--json\n")
        // The basics, and none of the test host's injection.
        let environment = try String(contentsOf: root.appendingPathComponent("environment"), encoding: .utf8)
        #expect(environment.contains("HOME="))
        #expect(!environment.contains("XCTestConfigurationFilePath"))
        #expect(!environment.contains("DYLD_INSERT_LIBRARIES"))
    }

    @Test func silenceComesBackEmptyForTheCoordinatorToJudge() async throws {
        #expect(try await answer(#"echo '{"contractVersion":1,"text":""}'"#) == .success(""))
    }

    /// Longer than a pipe's buffer: the runner reads while the command writes.
    @Test func aLongTranscriptIsReadWhole() async throws {
        let result = try await answer("""
            printf '{"contractVersion":1,"text":"'
            head -c 200000 /dev/zero | tr '\\0' a
            printf '"}\\n'
            """)
        #expect(result == .success(String(repeating: "a", count: 200_000)))
    }

    // MARK: - Failures

    @Test func eachExitCodeComesBackAsItsFailure() async throws {
        let codes: [(Int32, Transcription.Failure)] = [
            (1, .failed), (2, .failed), (3, .noAudio), (4, .noSpeechModel), (5, .failed), (143, .failed),
        ]
        for (code, failure) in codes {
            let result = try await answer("echo 'codictate: test failure \(code)' >&2; exit \(code)")
            #expect(result == .failure(failure), "exit \(code)")
        }
    }

    @Test func aContractThisSideDoesNotKnowIsAFailure() async throws {
        #expect(try await answer(#"echo '{"contractVersion":2,"text":"hi"}'"#) == .failure(.failed))
    }

    @Test func outputThatIsNotTheContractIsAFailure() async throws {
        #expect(try await answer("echo 'hello, plain text'") == .failure(.failed))
        #expect(try await answer(#"echo '{"text":"no version"}'"#) == .failure(.failed))
    }

    @Test func aCommandThatCannotRunIsAFailure() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let notThere = root.appendingPathComponent("codictate")

        #expect(await transcribe(with: .found(notThere)).1 == .failure(.failed))
    }

    @Test func noCodictateAndAnOldOneComeBackAsSuch() async {
        #expect(await transcribe(with: .missing).1 == .failure(.codictateMissing))
        #expect(await transcribe(with: .tooOld).1 == .failure(.codictateTooOld))
    }

    // MARK: - Cancelling

    /// The command announces itself through a FIFO once it is running, so the
    /// cancel is known to land on a live process: SIGTERM, which it answers
    /// with the contract's 143.
    @Test func cancellingStopsTheCommand() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = root.appendingPathComponent("started")
        #expect(mkfifo(started.path, 0o600) == 0)
        let terminated = root.appendingPathComponent("terminated")
        let command = try script("""
            trap 'touch "\(terminated.path)"; kill $! 2>/dev/null; exit 143' TERM
            sleep 60 &
            echo running > "\(started.path)"
            wait $!
            """, in: root)
        let (runner, pasteboard) = makeRunner(.found(command))
        defer { pasteboard.releaseGlobally() }
        let clock = ContinuousClock()
        let begun = clock.now

        let result: Result<String, Transcription.Failure> = await withCheckedContinuation { continuation in
            runner.onTranscription = { _, result in continuation.resume(returning: result) }
            runner.run([.transcribe(Self.audio, generation: 1)])
            Task {
                // Opening a FIFO to read waits for its writer: the script.
                _ = await Task.detached { try? FileHandle(forReadingFrom: started).readDataToEndOfFile() }.value
                runner.run([.cancelTranscription])
            }
        }

        #expect(result == .failure(.failed))
        #expect(FileManager.default.fileExists(atPath: terminated.path))
        #expect(clock.now - begun < .seconds(30))
    }

    // MARK: - Finding the command

    /// An app bundle at `root/<name>`, with the command in it or not.
    private func app(_ name: String, in root: URL, withCommand: Bool) throws -> URL {
        let app = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        if withCommand {
            try script("exit 0", in: app.appendingPathComponent(Transcription.commandPath).deletingLastPathComponent())
        }
        return app
    }

    @Test func noAppIsMissing() {
        #expect(Transcription.locate(application: { _ in nil }) == .missing)
    }

    @Test func anAppWithoutTheCommandIsTooOld() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stable = try app("Codictate.app", in: root, withCommand: false)

        #expect(Transcription.locate(application: { $0 == "app.codictate" ? stable : nil }) == .tooOld)
    }

    @Test func stableIsPreferredAndCanaryStandsIn() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let canary = try app("Codictate-canary.app", in: root, withCommand: true)
        let canaryCommand = canary.appendingPathComponent(Transcription.commandPath)

        let oldStable = try app("Old.app", in: root, withCommand: false)
        #expect(Transcription.locate(application: {
            ["app.codictate": oldStable, "app.codictate.canary": canary][$0]
        }) == .found(canaryCommand))

        let stable = try app("Codictate.app", in: root, withCommand: true)
        #expect(Transcription.locate(application: {
            ["app.codictate": stable, "app.codictate.canary": canary][$0]
        }) == .found(stable.appendingPathComponent(Transcription.commandPath)))
    }

    @Test func aDevelopmentBuildIsNotLookedFor() {
        #expect(!Transcription.bundleIdentifiers.contains("app.codictate.dev"))
    }
}

/// The installed Codictate's command on a spoken sentence. Off unless asked
/// for, because it needs Codictate (one with the command, and a Speech Model
/// installed) and takes seconds:
///
/// ```
/// TEST_RUNNER_CODICLENS_TRANSCRIBE=1 xcodebuild test -project codiclens.xcodeproj \
///   -scheme codiclens -only-testing:codiclensTests/RealCodictateTranscriptionTests
/// ```
///
/// `1` looks Codictate up as the app does, plus the local development build;
/// a path runs that command instead.
@Suite(.enabled(if: realCommand != nil), .timeLimit(.minutes(5)))
struct RealCodictateTranscriptionTests {

    @Test func theInstalledCodictateTranscribesASpokenSentence() async throws {
        let command: URL
        if let realCommand, realCommand != "1" {
            command = URL(fileURLWithPath: realCommand)
        } else {
            let location = Transcription.locate(bundleIdentifiers: Transcription.bundleIdentifiers + ["app.codictate.dev"])
            guard case .found(let found) = location else {
                Issue.record("no Codictate with the transcribe command: \(location)")
                return
            }
            command = found
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-transcription-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("fox.m4a")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["--data-format=aac", "-o", audio.path, "The quick brown fox jumps over the lazy dog."]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0)

        let clock = ContinuousClock()
        let begun = clock.now
        let result = await Task.detached { TranscriptionRun(file: audio).perform(with: command) }.value
        print("[codiclens] \(command.path) answered in \(clock.now - begun): \(result)")

        let text = try result.get()
        #expect(text.lowercased().contains("fox"))
    }
}
