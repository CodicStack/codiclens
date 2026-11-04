import AppKit
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// Transcribe, entirely on this side of the Effect seam.
///
/// **Codictate never runs here.** The coordinator returns
/// `.transcribe(url, generation:)` and stops; a test plays the runner's part by
/// calling `receiveTranscription` with a canned answer. `TranscriptionTests`
/// runs the real command against a fake script.
@MainActor
struct TranscribeCommandTests {

    // MARK: - Fixtures

    private static let audioURL = URL(fileURLWithPath: "/tmp/codiclens-fixture/memo.m4a")

    private func file(_ name: String, _ contentType: UTType) -> Subject {
        let url = URL(fileURLWithPath: "/tmp/codiclens-fixture/\(name)")
        return Subject(displayName: name, path: url.path, url: url, icon: NSImage(), kind: .file(contentType: contentType))
    }

    private func actionNames(for subject: Subject) -> [String] {
        SubjectAction.actions(for: subject).map(\.name)
    }

    /// An audio file on the Action Phase with Transcribe selected.
    private func readyToTranscribe() throws -> (CommandCoordinator, RecordingEffectRunner, Subject) {
        let runner = RecordingEffectRunner()
        let coordinator = CommandCoordinator.isolated(runner: runner)
        let subject = file("memo.m4a", .mpeg4Audio)
        coordinator.subjectVM.results = [subject]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.advancePhase()
        coordinator.actionVM.selectedIndex = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == "Transcribe" },
            "no Transcribe Action"
        )
        return (coordinator, runner, subject)
    }

    /// The text Subject a transcript left: standing in Subject search, or
    /// chosen once the user has gone on with it.
    private func text(of coordinator: CommandCoordinator) -> String? {
        guard case .text(let text)? = (coordinator.standingSubject ?? coordinator.selectedSubject)?.kind else {
            return nil
        }
        return text
    }

    private func generation(of effects: [Effect]) throws -> Int {
        guard case .transcribe(_, let generation) = try #require(effects.first) else {
            Issue.record("expected a transcription, got \(effects)")
            return -1
        }
        return generation
    }

    // MARK: - Where it is offered

    @Test func audioAndVideoFilesOfferTranscribe() {
        for subject in [
            file("memo.m4a", .mpeg4Audio), file("song.mp3", .mp3), file("take.wav", .wav),
            file("clip.mov", .quickTimeMovie), file("call.mp4", .mpeg4Movie),
        ] {
            #expect(actionNames(for: subject).contains("Transcribe"), "\(subject.displayName)")
        }
    }

    @Test func nothingElseOffersTranscribe() {
        let folder = Subject(
            displayName: "Music", path: "/tmp/Music", url: URL(fileURLWithPath: "/tmp/Music"),
            icon: NSImage(), kind: .folder
        )
        for subject in [
            file("photo.png", .png), file("notes.txt", .plainText), file("paper.pdf", .pdf), folder,
            Subject(text: "hello"),
            Subject(clipboardItem: ClipboardItem(content: "hi"), imageURL: nil),
            Subject(clipboardItem: ClipboardItem(imageFileName: "i.png"), imageURL: nil),
        ] {
            #expect(!actionNames(for: subject).contains("Transcribe"), "\(subject.displayName)")
        }
    }

    /// `.ts` is declared an MPEG-2 transport stream, so a TypeScript file
    /// would otherwise offer it.
    @Test func aTypeScriptFileDoesNotOfferTranscribe() throws {
        let ts = try #require(UTType(filenameExtension: "ts"))
        #expect(ts.conforms(to: .movie))
        #expect(!actionNames(for: file("index.ts", ts)).contains("Transcribe"))
    }

    // MARK: - The Effect

    @Test func transcribeReturnsOneEffectAndNoHide() throws {
        let (coordinator, runner, _) = try readyToTranscribe()

        let effects = coordinator.submit()

        #expect(effects == [.transcribe(Self.audioURL, generation: try generation(of: effects))])
        #expect(runner.recorded == effects)
        #expect(coordinator.isTranscriptionInFlight)
        #expect(coordinator.transcriptionNote == "Transcribing…")
        #expect(coordinator.phase == .pickingAction)
    }

    @Test func aSecondEnterWhileTranscribingDoesNothing() throws {
        let (coordinator, runner, _) = try readyToTranscribe()
        coordinator.submit()
        runner.clear()

        #expect(coordinator.submit() == [])
        #expect(runner.recorded.isEmpty)
    }

    // MARK: - The answer

    @Test func theTranscriptBecomesATextSubjectInPlaceOfTheFile() throws {
        let (coordinator, _, _) = try readyToTranscribe()
        let generation = try generation(of: coordinator.submit())

        coordinator.receiveTranscription(.success(" The quick brown fox.\n"), generation: generation)

        // Done: back in Subject search with the transcript standing, the
        // Query empty, as OCR Text stands.
        let transcript = try #require(coordinator.standingSubject.flatMap {
            if case .text(let text) = $0.kind { text } else { nil }
        }, "expected a text Subject standing")
        #expect(transcript == "The quick brown fox.")
        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.cardCount == 1)
        #expect(coordinator.subjectVM.searchText.isEmpty)
        #expect(!coordinator.isTranscriptionInFlight)
        #expect(coordinator.transcriptionNote == nil)
        #expect(coordinator.submit() == [.paste(.text("The quick brown fox."))], "Enter pastes it")

        coordinator.reset()
        coordinator.advancePhase()
        let names = coordinator.actionVM.filteredActions.map(\.name)
        #expect(names.contains("Copy"))
        #expect(names.contains("Share…"))
        #expect(!names.contains("Transcribe"))
    }

    @Test func theTranscriptCanBeEdited() throws {
        let (coordinator, _, _) = try readyToTranscribe()
        let generation = try generation(of: coordinator.submit())
        coordinator.receiveTranscription(.success("hello"), generation: generation)

        coordinator.toggleTextSubjectEdit()

        #expect(coordinator.isEditingTextSubject)
        #expect(coordinator.textSubjectEditText == "hello")
    }

    @Test func silenceMakesNoTextSubjectAndSaysNoSpeechFound() throws {
        let (coordinator, _, subject) = try readyToTranscribe()
        let generation = try generation(of: coordinator.submit())

        coordinator.receiveTranscription(.success(" \n"), generation: generation)

        #expect(coordinator.selectedSubject?.id == subject.id)
        #expect(coordinator.transcriptionFailure == .noSpeech)
        #expect(coordinator.transcriptionNote == "No speech found")
    }

    @Test func eachFailureSaysItsOwnLine() throws {
        let lines: [(Transcription.Failure, String)] = [
            (.noSpeechModel, "Pick a speech model in Codictate"),
            (.noAudio, "No audio in this file"),
            (.unreadable, "Can't read this file"),
            (.codictateUnavailable, "Couldn't start Codictate"),
            (.failed, "Couldn't transcribe"),
            (.codictateMissing, "Get Codictate to transcribe"),
            (.codictateTooOld, "Update Codictate to transcribe"),
        ]
        for (failure, line) in lines {
            let (coordinator, _, subject) = try readyToTranscribe()
            let generation = try generation(of: coordinator.submit())

            coordinator.receiveTranscription(.failure(failure), generation: generation)

            #expect(coordinator.transcriptionFailure == failure)
            #expect(coordinator.transcriptionNote == line)
            #expect(coordinator.selectedSubject?.id == subject.id)
            #expect(coordinator.phase == .pickingAction)
        }
    }

    @Test func aCancelledRunSaysNothing() throws {
        let (coordinator, _, subject) = try readyToTranscribe()
        let generation = try generation(of: coordinator.submit())

        coordinator.receiveTranscription(.failure(.cancelled), generation: generation)

        #expect(!coordinator.isTranscriptionInFlight)
        #expect(coordinator.transcriptionFailure == nil)
        #expect(coordinator.transcriptionNote == nil)
        #expect(coordinator.selectedSubject?.id == subject.id)
    }

    @Test func theExitCodesMapToTheirFailures() {
        #expect(Transcription.failure(forExitStatus: 1) == .failed)
        #expect(Transcription.failure(forExitStatus: 2) == .failed)
        #expect(Transcription.failure(forExitStatus: 3) == .noAudio)
        #expect(Transcription.failure(forExitStatus: 4) == .noSpeechModel)
        #expect(Transcription.failure(forExitStatus: 5) == .failed)
        #expect(Transcription.failure(forExitStatus: 6) == .codictateUnavailable)
        #expect(Transcription.failure(forExitStatus: 11) == .codictateTooOld)
        #expect(Transcription.failure(forExitStatus: 130) == .cancelled)
        #expect(Transcription.failure(forExitStatus: 143) == .cancelled)
    }

    /// The `error` event's code is asked first: exit 3 is two things.
    @Test func theErrorCodeSaysMoreThanTheExitCode() {
        #expect(Transcription.result(exitStatus: 3, transcript: nil, errorCode: "input_unreadable") == .failure(.unreadable))
        #expect(Transcription.result(exitStatus: 3, transcript: nil, errorCode: "no_audio") == .failure(.noAudio))
        #expect(Transcription.result(exitStatus: 5, transcript: nil, errorCode: "engine_failed") == .failure(.failed))
        #expect(Transcription.result(exitStatus: 4, transcript: nil, errorCode: "something_new") == .failure(.noSpeechModel))
        #expect(Transcription.result(exitStatus: 0, transcript: "hi", errorCode: nil) == .success("hi"))
        #expect(Transcription.result(exitStatus: 0, transcript: nil, errorCode: nil) == .failure(.failed))
    }

    // MARK: - Progress

    @Test func progressSaysWhereTheRunIs() throws {
        let lines: [(Transcription.Progress, String)] = [
            (.queued(position: 3), "Waiting, 2 ahead"),
            (.queued(position: 2), "Waiting, 1 ahead"),
            (.queued(position: 1), "Next up"),
            (.running(.decoding, elapsedSeconds: 0.4, audioSeconds: nil), "Reading the file · 0:00"),
            (.running(.transcribing, elapsedSeconds: 42.9, audioSeconds: nil), "Transcribing · 0:42"),
            (.running(.transcribing, elapsedSeconds: 42, audioSeconds: 3121.5), "Transcribing · 0:42 · 52:01 of audio"),
            (.running(.transcribing, elapsedSeconds: 3723, audioSeconds: 7322), "Transcribing · 1:02:03 · 2:02:02 of audio"),
        ]
        let (coordinator, _, _) = try readyToTranscribe()
        let generation = try generation(of: coordinator.submit())
        #expect(coordinator.transcriptionNote == "Transcribing…")

        for (progress, line) in lines {
            coordinator.receiveTranscriptionProgress(progress, generation: generation)
            #expect(coordinator.transcriptionNote == line)
        }
    }

    @Test func progressGoesAwayWithTheAnswer() throws {
        let (coordinator, _, _) = try readyToTranscribe()
        let first = try generation(of: coordinator.submit())
        coordinator.receiveTranscriptionProgress(.queued(position: 1), generation: first)

        coordinator.receiveTranscription(.failure(.noAudio), generation: first)
        #expect(coordinator.transcriptionNote == "No audio in this file")

        // The next run starts without the last one's progress.
        let next = try generation(of: coordinator.submit())
        #expect(coordinator.transcriptionProgress == nil)
        #expect(coordinator.transcriptionNote == "Transcribing…")
        coordinator.receiveTranscription(.success("done"), generation: next)
        coordinator.receiveTranscriptionProgress(.queued(position: 1), generation: next)
        #expect(coordinator.transcriptionProgress == nil)
        #expect(coordinator.transcriptionNote == nil)
    }

    @Test func progressFromAnEarlierOrCancelledRunIsDropped() throws {
        let (coordinator, _, _) = try readyToTranscribe()
        let first = try generation(of: coordinator.submit())
        coordinator.handleEscape()

        coordinator.receiveTranscriptionProgress(.queued(position: 4), generation: first)
        #expect(coordinator.transcriptionNote == nil)

        let second = try generation(of: coordinator.submit())
        coordinator.receiveTranscriptionProgress(.queued(position: 4), generation: first)
        #expect(coordinator.transcriptionNote == "Transcribing…")
        coordinator.receiveTranscriptionProgress(.queued(position: 1), generation: second)
        #expect(coordinator.transcriptionNote == "Next up")
    }

    @Test func aFailureClearsAsTheNextRunStarts() throws {
        let (coordinator, _, _) = try readyToTranscribe()
        coordinator.receiveTranscription(.failure(.noAudio), generation: try generation(of: coordinator.submit()))

        coordinator.submit()

        #expect(coordinator.transcriptionFailure == nil)
        #expect(coordinator.transcriptionNote == "Transcribing…")
    }

    // MARK: - Without Codictate

    @Test func withoutCodictateTheNextEnterOpensItsWebsite() throws {
        for failure in [Transcription.Failure.codictateMissing, .codictateTooOld] {
            let (coordinator, _, _) = try readyToTranscribe()
            coordinator.receiveTranscription(.failure(failure), generation: try generation(of: coordinator.submit()))

            #expect(coordinator.submit() == [.hide, .open(Transcription.downloadURL)])
            #expect(!coordinator.isTranscriptionInFlight)
        }
    }

    @Test func otherFailuresTryAgainOnTheNextEnter() throws {
        let (coordinator, _, _) = try readyToTranscribe()
        coordinator.receiveTranscription(.failure(.noSpeechModel), generation: try generation(of: coordinator.submit()))

        let effects = coordinator.submit()

        #expect(effects == [.transcribe(Self.audioURL, generation: try generation(of: effects))])
    }

    // MARK: - Cancelling

    @Test func escapeStopsTheRunAndKeepsThePanel() throws {
        let (coordinator, runner, subject) = try readyToTranscribe()
        let generation = try generation(of: coordinator.submit())
        runner.clear()

        #expect(coordinator.handleEscape())

        #expect(runner.recorded == [.cancelTranscription])
        #expect(!coordinator.isTranscriptionInFlight)
        #expect(coordinator.transcriptionNote == nil)
        #expect(coordinator.phase == .pickingAction)
        // The cancelled run's answer, exit 143, changes nothing.
        coordinator.receiveTranscription(.failure(.cancelled), generation: generation)
        #expect(coordinator.transcriptionFailure == nil)
        #expect(coordinator.selectedSubject?.id == subject.id)
        // With nothing running, Escape dismisses as it always does.
        #expect(!coordinator.handleEscape())
    }

    @Test func resetStopsTheRunAndDropsItsAnswer() throws {
        let (coordinator, runner, _) = try readyToTranscribe()
        let generation = try generation(of: coordinator.submit())
        runner.clear()

        coordinator.reset()

        #expect(runner.recorded == [.cancelTranscription])
        #expect(!coordinator.isTranscriptionInFlight)
        coordinator.receiveTranscription(.success("too late"), generation: generation)
        #expect(coordinator.selectedSubject == nil)
    }

    @Test func leavingTheActionsStopsTheRun() throws {
        let (coordinator, runner, _) = try readyToTranscribe()
        coordinator.submit()
        runner.clear()

        coordinator.retreatPhase()

        #expect(runner.recorded == [.cancelTranscription])
        #expect(!coordinator.isTranscriptionInFlight)
    }

    @Test func cancellingWithNothingRunningSendsNothing() throws {
        let (coordinator, runner, _) = try readyToTranscribe()

        coordinator.cancelTranscription()
        coordinator.reset()

        #expect(runner.recorded.isEmpty)
    }

    @Test func anAnswerFromAnEarlierRunIsDropped() throws {
        let (coordinator, _, _) = try readyToTranscribe()
        let first = try generation(of: coordinator.submit())
        coordinator.handleEscape()
        let second = try generation(of: coordinator.submit())

        coordinator.receiveTranscription(.success("first"), generation: first)
        #expect(coordinator.isTranscriptionInFlight)

        coordinator.receiveTranscription(.success("second"), generation: second)
        #expect(text(of: coordinator) == "second")
    }
}
