import AppKit
import Foundation
import Testing
@testable import codiclens

private let realCommand = ProcessInfo.processInfo.environment["CODICLENS_TRANSCRIBE"]

/// The other side of the seam: `SystemEffectRunner` running a `codictate`
/// client and answering with what it reported along the way and what it
/// amounted to.
///
/// **The real Codictate is not needed.** Each test writes a small shell script
/// that plays the client's part (prints the contract's NDJSON events, over
/// time when that matters, or exits with one of its codes) and hands it to the
/// runner as the client it found. `RealCodictateTranscriptionTests` below runs
/// a real one, when asked.
@MainActor
@Suite(.timeLimit(.minutes(1)))
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

    private struct Run {
        var generation: Int
        var result: Result<String, Transcription.Failure>
        /// Every progress, in the order it arrived, all before the answer.
        var progress: [Transcription.Progress]
    }

    /// Runs `.transcribe` through a runner whose client is at `location`, and
    /// waits for the answer.
    ///
    /// - Parameter onProgress: called on the main thread with each progress
    ///   as it arrives, while the client still runs.
    private func transcribe(
        with location: Transcription.Location,
        generation: Int = 7,
        onProgress: @escaping (Transcription.Progress) -> Void = { _ in }
    ) async -> Run {
        let (runner, pasteboard) = makeRunner(location)
        defer { pasteboard.releaseGlobally() }
        var progress: [Transcription.Progress] = []
        return await withCheckedContinuation { continuation in
            runner.onTranscriptionProgress = { progressGeneration, update in
                #expect(Thread.isMainThread)
                #expect(progressGeneration == generation)
                progress.append(update)
                onProgress(update)
            }
            runner.onTranscription = { generation, result in
                #expect(Thread.isMainThread)
                continuation.resume(returning: Run(generation: generation, result: result, progress: progress))
            }
            runner.run([.transcribe(Self.audio, generation: generation)])
        }
    }

    private func answer(_ body: String) async throws -> Result<String, Transcription.Failure> {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        return await transcribe(with: .found(try script(body, in: root))).result
    }

    // MARK: - Success

    @Test func theTranscriptComesBackWithItsGeneration() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try script("""
            printf '%s\\n' "$@" > "\(root.path)/arguments"
            env > "\(root.path)/environment"
            echo '{"type":"result","file":"\(Self.audio.path)","text":"The quick brown fox.","language":null,"speechModelId":"large-v3-turbo-q5_0","engine":"whisper","audioSeconds":1.4}'
            """, in: root)

        let run = await transcribe(with: .found(command), generation: 12)

        #expect(run.generation == 12)
        #expect(run.result == .success("The quick brown fox."))
        let arguments = try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8)
        #expect(arguments == "transcribe\n\(Self.audio.path)\n--json\n")
        // The basics, and none of the test host's injection.
        let environment = try String(contentsOf: root.appendingPathComponent("environment"), encoding: .utf8)
        #expect(environment.contains("HOME="))
        #expect(!environment.contains("XCTestConfigurationFilePath"))
        #expect(!environment.contains("DYLD_INSERT_LIBRARIES"))
    }

    @Test func queuedAndProgressComeBackInOrderBeforeTheAnswer() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try script("""
            echo '{"type":"queued","position":2}'
            echo '{"type":"queued","position":1}'
            echo '{"type":"progress","stage":"decoding","elapsedSeconds":0.4,"audioSeconds":null}'
            echo '{"type":"progress","stage":"transcribing","elapsedSeconds":12.0,"audioSeconds":3121.5}'
            echo '{"type":"result","text":"hello"}'
            """, in: root)

        let run = await transcribe(with: .found(command))

        #expect(run.result == .success("hello"))
        #expect(run.progress == [
            .queued(position: 2),
            .queued(position: 1),
            .running(.decoding, elapsedSeconds: 0.4, audioSeconds: nil),
            .running(.transcribing, elapsedSeconds: 12, audioSeconds: 3121.5),
        ])
    }

    /// The client prints `queued` and then waits, through a FIFO, until the
    /// test has seen it. A runner that read to the end before reporting would
    /// never get past the wait.
    @Test func eventsArriveWhileTheClientIsStillRunning() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let go = root.appendingPathComponent("go")
        #expect(mkfifo(go.path, 0o600) == 0)
        let command = try script("""
            echo '{"type":"queued","position":3}'
            read line < "\(go.path)"
            echo '{"type":"result","text":"after the wait"}'
            """, in: root)

        let run = await transcribe(with: .found(command)) { _ in
            Task.detached {
                // Opening a FIFO to write waits for its reader: the script.
                let handle = try? FileHandle(forWritingTo: go)
                try? handle?.write(contentsOf: Data("go\n".utf8))
                try? handle?.close()
            }
        }

        #expect(run.progress == [.queued(position: 3)])
        #expect(run.result == .success("after the wait"))
    }

    @Test func unknownEventsFieldsAndLinesAreIgnored() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try script("""
            echo '{"type":"heartbeat","n":1}'
            echo '{"type":"progress","stage":"warming-up","elapsedSeconds":1}'
            echo 'not json'
            echo ''
            echo '{"type":"progress","stage":"transcribing","elapsedSeconds":2,"audioSeconds":9,"fraction":0.5}'
            printf '{"type":"result","text":"fine","words":[],"newField":true}'
            """, in: root)

        let run = await transcribe(with: .found(command))

        #expect(run.progress == [.running(.transcribing, elapsedSeconds: 2, audioSeconds: 9)])
        #expect(run.result == .success("fine"))
    }

    @Test func silenceComesBackEmptyForTheCoordinatorToJudge() async throws {
        #expect(try await answer(#"echo '{"type":"result","text":""}'"#) == .success(""))
    }

    /// Longer than a pipe's buffer, on one line: the runner reads while the
    /// client writes, and puts the pieces of the line back together.
    @Test func aLongTranscriptIsReadWhole() async throws {
        let result = try await answer("""
            echo '{"type":"progress","stage":"transcribing","elapsedSeconds":1,"audioSeconds":null}'
            printf '{"type":"result","text":"'
            head -c 200000 /dev/zero | tr '\\0' a
            printf '"}\\n'
            """)
        #expect(result == .success(String(repeating: "a", count: 200_000)))
    }

    // MARK: - Failures

    @Test func eachErrorEventComesBackAsItsFailure() async throws {
        let cases: [(String, Int32, Transcription.Failure)] = [
            ("no_audio", 3, .noAudio),
            ("input_unreadable", 3, .unreadable),
            ("model_not_installed", 4, .noSpeechModel),
            ("engine_failed", 5, .failed),
            ("app_unavailable", 6, .codictateUnavailable),
            ("contract_mismatch", 11, .codictateTooOld),
            ("cancelled", 143, .cancelled),
            ("internal", 1, .failed),
            ("usage", 2, .failed),
        ]
        for (code, exit, failure) in cases {
            let result = try await answer("""
                echo '{"type":"queued","position":1}'
                echo '{"type":"error","code":"\(code)","message":"test failure"}'
                echo 'codictate: test failure \(code)' >&2
                exit \(exit)
                """)
            #expect(result == .failure(failure), "\(code)")
        }
    }

    @Test func eachExitCodeWithoutAnEventComesBackAsItsFailure() async throws {
        let codes: [(Int32, Transcription.Failure)] = [
            (1, .failed), (2, .failed), (3, .noAudio), (4, .noSpeechModel), (5, .failed),
            (6, .codictateUnavailable), (11, .codictateTooOld), (130, .cancelled), (143, .cancelled),
        ]
        for (code, failure) in codes {
            let result = try await answer("echo 'codictate: test failure \(code)' >&2; exit \(code)")
            #expect(result == .failure(failure), "exit \(code)")
        }
    }

    @Test func aResultWithAFailingExitIsNotTrusted() async throws {
        #expect(try await answer(#"echo '{"type":"result","text":"hi"}'; exit 5"#) == .failure(.failed))
    }

    @Test func outputThatIsNotTheContractIsAFailure() async throws {
        #expect(try await answer("echo 'hello, plain text'") == .failure(.failed))
        // The one-shot contract before this one: no `type`.
        #expect(try await answer(#"echo '{"contractVersion":1,"text":"old"}'"#) == .failure(.failed))
        #expect(try await answer("exit 0") == .failure(.failed))
    }

    @Test func aCommandThatCannotRunIsAFailure() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let notThere = root.appendingPathComponent("codictate")

        #expect(await transcribe(with: .found(notThere)).result == .failure(.failed))
    }

    @Test func noCodictateAnOldOneAndAnUnreachableOneComeBackAsSuch() async {
        #expect(await transcribe(with: .missing).result == .failure(.codictateMissing))
        #expect(await transcribe(with: .tooOld).result == .failure(.codictateTooOld))
        #expect(await transcribe(with: .unavailable).result == .failure(.codictateUnavailable))
    }

    // MARK: - Cancelling

    /// The client announces itself through a FIFO once it is running, so the
    /// cancel is known to land on a live process: SIGTERM, which it answers as
    /// the contract's client does, with a `cancelled` event and 143.
    @Test func cancellingStopsTheCommand() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = root.appendingPathComponent("started")
        #expect(mkfifo(started.path, 0o600) == 0)
        let terminated = root.appendingPathComponent("terminated")
        let command = try script("""
            trap 'touch "\(terminated.path)"; kill $! 2>/dev/null; echo "{\\"type\\":\\"error\\",\\"code\\":\\"cancelled\\",\\"message\\":\\"Cancelled\\"}"; exit 143' TERM
            echo '{"type":"progress","stage":"transcribing","elapsedSeconds":1,"audioSeconds":600}'
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

        #expect(result == .failure(.cancelled))
        #expect(FileManager.default.fileExists(atPath: terminated.path))
        #expect(clock.now - begun < .seconds(30))
    }

    @Test func aRunCancelledBeforeItStartsNeverStarts() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ran = root.appendingPathComponent("ran")
        let command = try script("touch \"\(ran.path)\"", in: root)
        let run = TranscriptionRun(file: Self.audio)

        run.cancel()

        #expect(run.perform(with: command) == .failure(.cancelled))
        #expect(!FileManager.default.fileExists(atPath: ran.path))
    }

    // MARK: - Finding the client

    /// An app bundle at `root/<name>`, with a client in it or not.
    private func app(_ name: String, in root: URL, withCommand: Bool) throws -> URL {
        let app = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        if withCommand {
            try script("exit 0", in: app.appendingPathComponent(Transcription.commandPath).deletingLastPathComponent())
        }
        return app
    }

    private func client(of app: URL) -> URL {
        app.appendingPathComponent(Transcription.commandPath)
    }

    @Test func noAppIsMissing() {
        #expect(Transcription.locate(application: { _ in nil }, compatibility: { _ in .compatible }) == .missing)
    }

    @Test func anAppWithoutTheClientIsTooOld() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stable = try app("Codictate.app", in: root, withCommand: false)

        #expect(Transcription.locate(
            application: { $0 == "app.codictate" ? stable : nil },
            compatibility: { _ in .compatible }
        ) == .tooOld)
    }

    @Test func aClientOfAnotherContractIsTooOld() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stable = try app("Codictate.app", in: root, withCommand: true)

        #expect(Transcription.locate(
            application: { $0 == "app.codictate" ? stable : nil },
            compatibility: { _ in .tooOld }
        ) == .tooOld)
    }

    @Test func stableIsPreferredAndCanaryStandsIn() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let canary = try app("Codictate-canary.app", in: root, withCommand: true)

        let oldStable = try app("Old.app", in: root, withCommand: false)
        #expect(Transcription.locate(
            application: { ["app.codictate": oldStable, "app.codictate.canary": canary][$0] },
            compatibility: { _ in .compatible }
        ) == .found(client(of: canary)))

        let scriptStable = try app("Script.app", in: root, withCommand: true)
        #expect(Transcription.locate(
            application: { ["app.codictate": scriptStable, "app.codictate.canary": canary][$0] },
            compatibility: { $0 == self.client(of: canary) ? .compatible : .tooOld }
        ) == .found(client(of: canary)))

        let stable = try app("Codictate.app", in: root, withCommand: true)
        #expect(Transcription.locate(
            application: { ["app.codictate": stable, "app.codictate.canary": canary][$0] },
            compatibility: { _ in .compatible }
        ) == .found(client(of: stable)))
    }

    @Test func aClientThatCannotReachItsAppIsUnavailable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stable = try app("Codictate.app", in: root, withCommand: true)

        #expect(Transcription.locate(
            application: { $0 == "app.codictate" ? stable : nil },
            compatibility: { _ in .unavailable }
        ) == .unavailable)
    }

    /// `status` failing some other way says nothing against the client; the
    /// transcribe call reports what is wrong itself.
    @Test func anInconclusiveStatusStillUsesTheClient() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stable = try app("Codictate.app", in: root, withCommand: true)

        #expect(Transcription.locate(
            application: { $0 == "app.codictate" ? stable : nil },
            compatibility: { _ in .unknown }
        ) == .found(client(of: stable)))
    }

    @Test func aDevelopmentBuildIsNotLookedFor() {
        #expect(!Transcription.bundleIdentifiers.contains("app.codictate.dev"))
    }

    // MARK: - Is it this contract?

    private func status(_ body: String) throws -> Transcription.Compatibility {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        return Transcription.status(of: try script(body, in: root))
    }

    @Test func statusAsksForJSON() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try script("""
            printf '%s\\n' "$@" > "\(root.path)/arguments"
            echo '{"type":"result","contractVersion":1}'
            """, in: root)

        #expect(Transcription.status(of: command) == .compatible)
        let arguments = try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8)
        #expect(arguments == "status\n--json\n")
    }

    @Test func statusWithContractVersionOneIsCompatible() throws {
        #expect(try status("""
            echo '{"type":"result","contractVersion":1,"app":{"version":"0.0.62","channel":"stable","identifier":"app.codictate"},"onboardingCompleted":true,"microphone":"granted","commandLineControl":false,"dictation":{"active":false,"startedBy":null},"speechModel":{"id":"large-v3-turbo-q5_0","label":"Large V3 Turbo","engine":"whisper","installed":true},"transcriptionLanguage":{"id":"auto","label":"Auto-detect"},"fileTranscriptions":{"running":0,"queued":0}}'
            """) == .compatible)
    }

    @Test func statusWithAnotherOrNoContractVersionIsTooOld() throws {
        #expect(try status(#"echo '{"type":"result","contractVersion":0}'"#) == .tooOld)
        #expect(try status(#"echo '{"type":"result","contractVersion":2}'"#) == .tooOld)
        #expect(try status(#"echo '{"type":"result","app":{}}'"#) == .tooOld)
        #expect(try status("echo 'app: 0.0.55'") == .tooOld)
        #expect(try status("exit 0") == .tooOld)
    }

    @Test func statusExitCodesSayWhatTheyCan() throws {
        // Does not know `status`: a client before this contract.
        #expect(try status("echo 'codictate: unknown command' >&2; exit 2") == .tooOld)
        #expect(try status(#"echo '{"type":"error","code":"contract_mismatch","message":"x"}'; exit 11"#) == .tooOld)
        #expect(try status(#"echo '{"type":"error","code":"app_unavailable","message":"x"}'; exit 6"#) == .unavailable)
        #expect(try status("exit 1") == .unknown)
    }

    /// The client before this one was a script; it is not asked anything.
    @Test func aClientThatIsNotAMachOIsTooOldWithoutBeingRun() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ran = root.appendingPathComponent("ran")
        let command = try script("""
            touch "\(ran.path)"
            echo '{"type":"result","contractVersion":1}'
            """, in: root)

        #expect(Transcription.compatibility(of: command) == .tooOld)
        #expect(!FileManager.default.fileExists(atPath: ran.path))
    }

    @Test func machOIsRecognised() throws {
        #expect(Transcription.isMachO(URL(fileURLWithPath: "/bin/ls")))
        #expect(Transcription.isMachO(URL(fileURLWithPath: "/usr/bin/true")))
        #expect(!Transcription.isMachO(URL(fileURLWithPath: "/etc/hosts")))
        #expect(!Transcription.isMachO(URL(fileURLWithPath: "/no/such/file")))
    }

    /// A real Mach-O that answers `status` with nothing (`true`, exit 0) is
    /// not this contract.
    @Test func aMachOThatDoesNotAnswerStatusIsTooOld() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("codictate")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: client)

        #expect(Transcription.compatibility(of: client) == .tooOld)
    }
}

/// A real Codictate client on a spoken sentence. Off unless asked for,
/// because it needs Codictate (one with the contract-1 client, and a Speech
/// Model installed), may start it hidden, and takes seconds:
///
/// ```
/// TEST_RUNNER_CODICLENS_TRANSCRIBE=1 xcodebuild test -project codiclens.xcodeproj \
///   -scheme codiclens -only-testing:codiclensTests/RealCodictateTranscriptionTests
/// ```
///
/// `1` looks Codictate up as the app does (its `status` check included), plus
/// the local development build; a path to a client (`<App>.app/Contents/
/// Resources/app/bin/codictate`) runs that one.
@Suite(.enabled(if: realCommand != nil), .timeLimit(.minutes(5)))
struct RealCodictateTranscriptionTests {

    @Test func aRealCodictateTranscribesASpokenSentence() async throws {
        let command: URL
        if let realCommand, realCommand != "1" {
            command = URL(fileURLWithPath: realCommand)
            let compatibility = await Task.detached { Transcription.compatibility(of: command) }.value
            try #require(compatibility == .compatible, "\(command.path) is \(compatibility)")
        } else {
            let location = await Task.detached {
                Transcription.locate(bundleIdentifiers: Transcription.bundleIdentifiers + ["app.codictate.dev"])
            }.value
            guard case .found(let found) = location else {
                Issue.record("no Codictate with a contract-1 client: \(location)")
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
        let (result, progress) = await Task.detached {
            var progress: [Transcription.Progress] = []
            let result = TranscriptionRun(file: audio).perform(with: command) { progress.append($0) }
            return (result, progress)
        }.value
        print("[codiclens] \(command.path) answered in \(clock.now - begun): \(result)")
        print("[codiclens] progress: \(progress.map(\.note))")

        let text = try result.get()
        #expect(text.lowercased().contains("fox"))
        #expect(!progress.isEmpty, "a File Transcription reports at least its stage")
    }
}
