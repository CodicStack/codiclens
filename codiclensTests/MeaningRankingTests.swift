import AVFoundation
import Foundation
import Testing
@testable import codiclens

/// The arithmetic of a settled search, apart from any database: the
/// per-modality scale, the gates, the weights, the Query's words, and where
/// a Passage found by meaning says it is.
struct MeaningRankingTests {

    // MARK: - The scale

    @Test func aScoreIsCentredOnItsModalityAndScaledByEveryRow() {
        // 20 text rows around 0.5 and 20 picture rows around 0.3: the same
        // standing within each modality is the same z.
        let text = (0..<20).map { 0.5 + Float($0 % 5) * 0.05 }
        let pictures = (0..<20).map { 0.3 + Float($0 % 5) * 0.05 }
        let scores = text + pictures
        let modality = [UInt8](repeating: 0, count: 20) + [UInt8](repeating: 1, count: 20)
        let z = MeaningRanking.zScores(scores, modality: modality, setsScale: .init(repeating: true, count: 40),
                                       alive: .init(repeating: true, count: 40))
        #expect(abs(z[4] - z[24]) < 1e-4, "the best text and the best picture stand out alike")
        #expect(z[4] > 1)
        #expect(abs(z[0] - z[20]) < 1e-4)
    }

    @Test func aModalityWithFewRowsTakesTheOverallAverage() {
        // Three pictures can't say where pictures sit: they are centred on
        // the average of all rows. On their own average (0.63) the one at
        // 0.9 would be ordinary and the two at 0.5 well above nothing.
        let scores = [Float](repeating: 0.5, count: 30) + [0.5, 0.5, 0.9]
        let modality = [UInt8](repeating: 0, count: 30) + [1, 1, 1]
        let z = MeaningRanking.zScores(scores, modality: modality, setsScale: .init(repeating: true, count: 33),
                                       alive: .init(repeating: true, count: 33))
        #expect(Double(z[32]) > MeaningRanking.zGate)
        #expect(z[30] < 0 && z[30] > -1)
        // Twenty of them are enough to have an average of their own.
        let many = [Float](repeating: 0.5, count: 30) + [Float](repeating: 0.3, count: 19) + [0.9]
        let own = MeaningRanking.zScores(many, modality: [UInt8](repeating: 0, count: 30) + .init(repeating: 1, count: 20),
                                         setsScale: .init(repeating: true, count: 50), alive: .init(repeating: true, count: 50))
        #expect(abs(own[30] - own[0]) < 0.6, "a picture at its modality's level is ordinary")
    }

    @Test func laterRowsAreScoredButDoNotMoveTheScale() {
        let base = (0..<25).map { 0.4 + Float($0 % 5) * 0.02 }
        let book = [Float](repeating: 0.1, count: 200)
        let modality = [UInt8](repeating: 0, count: 225)
        let without = MeaningRanking.zScores(base, modality: .init(repeating: 0, count: 25),
                                             setsScale: .init(repeating: true, count: 25), alive: .init(repeating: true, count: 25))
        let with = MeaningRanking.zScores(base + book, modality: modality,
                                          setsScale: .init(repeating: true, count: 25) + .init(repeating: false, count: 200),
                                          alive: .init(repeating: true, count: 225))
        #expect(zip(without, with).allSatisfy { abs($0 - $1) < 1e-4 }, "a book's later pages leave the scale alone")
        #expect(with[224] < 0)
    }

    @Test func theDeviationHasAFloorAndARemovedRowNeverScores() {
        let scores: [Float] = .init(repeating: 0.5, count: 30) + [0.51]
        let z = MeaningRanking.zScores(scores, modality: .init(repeating: 0, count: 31),
                                       setsScale: .init(repeating: true, count: 31),
                                       alive: .init(repeating: true, count: 30) + [false])
        #expect(z[30] == -.infinity)
        let flat = MeaningRanking.zScores(.init(repeating: 0.5, count: 30) + [0.51],
                                          modality: .init(repeating: 0, count: 31),
                                          setsScale: .init(repeating: true, count: 31), alive: .init(repeating: true, count: 31))
        #expect(flat[30] < 0.6, "0.01 over a flat field is half a floor-deviation, not a match")
    }

    // MARK: - Fusion

    @Test func aFileIsACandidateByMeaningOrByMostOfTheWords() {
        #expect(MeaningRanking.isCandidate(z: 2.0, coverage: 0))
        #expect(!MeaningRanking.isCandidate(z: 1.99, coverage: 0.49))
        #expect(MeaningRanking.isCandidate(z: nil, coverage: 0.5))
        #expect(!MeaningRanking.isCandidate(z: nil, coverage: 0))
    }

    @Test func theScoreWeighsMeaningWordsAndTheKindAsked() {
        #expect(MeaningRanking.score(z: 3, coverage: 0, isKindAskedFor: false, isLookup: false) == 3)
        #expect(MeaningRanking.score(z: -1, coverage: 1, isKindAskedFor: false, isLookup: false) == 2,
                "a negative z adds nothing; all the words add the words' weight")
        #expect(abs(MeaningRanking.score(z: 0, coverage: 0.5, isKindAskedFor: false, isLookup: false)
                    - 2 * pow(0.5, 1.5)) < 1e-12)
        #expect(MeaningRanking.score(z: 3, coverage: 0, isKindAskedFor: true, isLookup: false) == 4)
    }

    @Test func aLookupWeighsWordsDoubleAndMeaningHalf() {
        #expect(MeaningRanking.isLookup(MeaningRanking.terms("K7Q2LM")))
        #expect(MeaningRanking.isLookup(MeaningRanking.terms("#1234")))
        #expect(MeaningRanking.isLookup(MeaningRanking.terms("order 4815162342")) == false, "\"order\" is a word")
        #expect(!MeaningRanking.isLookup(MeaningRanking.terms("123")), "three digits are too few")
        #expect(!MeaningRanking.isLookup(MeaningRanking.terms("smoothie opskrift")))
        #expect(MeaningRanking.score(z: 4, coverage: 1, isKindAskedFor: false, isLookup: true) == 2 + 4)
        // A strong meaning match beats the lone word in an ordinary search,
        // and loses to it in a lookup.
        let meaning = (z: 3.5, coverage: 0.0), word = (z: 0.5, coverage: 1.0)
        #expect(MeaningRanking.score(z: meaning.z, coverage: meaning.coverage, isKindAskedFor: false, isLookup: false)
                > MeaningRanking.score(z: word.z, coverage: word.coverage, isKindAskedFor: false, isLookup: false))
        #expect(MeaningRanking.score(z: meaning.z, coverage: meaning.coverage, isKindAskedFor: false, isLookup: true)
                < MeaningRanking.score(z: word.z, coverage: word.coverage, isKindAskedFor: false, isLookup: true))
    }

    @Test func theQuerysWordsLeaveOutStopwordsAndKindWords() {
        #expect(MeaningRanking.terms("the screenshot of my invoice") == ["invoice"])
        #expect(MeaningRanking.terms("skærmbillede af min faktura fra marts") == ["faktura", "marts"])
        #expect(MeaningRanking.terms("a b cd cd") == ["cd"])
    }

    @Test func kindWordsAskForTheirKind() {
        #expect(MeaningRanking.kindHints("video from the beach") == [.video])
        #expect(MeaningRanking.kindHints("skærmbillede af fejlen") == [.screenshot])
        #expect(MeaningRanking.kindHints("billede af hunden") == [.image])
        #expect(MeaningRanking.kindHints("lyd fra mødet") == [.audio])
        #expect(MeaningRanking.kindHints("pdf med kontrakten") == [.pdf])
        #expect(MeaningRanking.kindHints("noter om budget") == [.document, .text])
        #expect(MeaningRanking.kindHints("budget 2024").isEmpty)
    }

    // MARK: - Recordings and videos

    @Test func windowsAreThirtySecondsEveryTwentyFiveAndTheTailMustAddSomething() {
        #expect(MeaningReader.windowStarts(in: 0..<60, duration: 60) == [0, 25, 50])
        #expect(MeaningReader.windowStarts(in: 0..<54, duration: 54) == [0, 25], "the third would add 1 s")
        #expect(MeaningReader.windowStarts(in: 0..<1.5, duration: 1.5).isEmpty)
        #expect(MeaningReader.windowStarts(in: 600..<1200, duration: 3600).first == 600)
        #expect(MeaningReader.windowStarts(in: 0..<600, duration: 3600).last == 575, "a step ends where the next starts")
    }

    @Test func aStepIsTenMinutesFirstThenHalfAnHour() {
        let first = MeaningJob(id: 1, path: "/x.m4a", content: .audio, size: 1, mtime: 0, isFirstStep: true, vecTo: 0)
        let later = MeaningJob(id: 1, path: "/x.m4a", content: .audio, size: 1, mtime: 0, isFirstStep: false, vecTo: 600)
        #expect(MeaningReader.step(first, duration: 7200) == 0..<600)
        #expect(MeaningReader.step(later, duration: 7200) == 600..<2400)
        #expect(MeaningReader.step(later, duration: 900) == 600..<900)
    }

    @Test func framesAreEveryThreeSecondsAndAtMostTwelveHundred() {
        #expect(MeaningReader.frameTimes(in: 0..<10, duration: 10) == [0.5, 3.5, 6.5, 9.5])
        #expect(MeaningReader.frameTimes(in: 600..<610, duration: 3600).first == 600.5)
        let long = MeaningReader.frameTimes(in: 0..<36_000, duration: 36_000)
        #expect(long.count == 1200, "ten hours at one frame every 30 s")
    }

    @Test func aPassageInARecordingSaysWhenAndAPageWhere() {
        let moment = FileHit.Passage(excerpt: "", matches: [], page: nil, start: 842, end: 872, modality: .audio)
        #expect(moment.subtitle == "at 14:02")
        let long = FileHit.Passage(excerpt: "", matches: [], page: nil, start: 3723, end: 3753, modality: .image)
        #expect(long.subtitle == "at 1:02:03")
        let page = FileHit.Passage(excerpt: "", matches: [], page: 4, modality: .image)
        #expect(page.subtitle == "page 4")
        let words = FileHit.Passage(excerpt: "…the words…", matches: [], page: 4)
        #expect(words.subtitle == "page 4 · …the words…")
        #expect(FileIndexReader.opening(of: "  A long\n\nline  " + String(repeating: "word ", count: 40)).hasSuffix("…"))
    }

    /// The helper reads a video's soundtrack, a `.mov` or an `.mp4`, through
    /// the asset reader where `AVAudioFile` will not open the container.
    @Test(arguments: ["clip.mov", "clip.mp4"])
    func aVideosSoundtrackIsReadForTheAudioEncoder(_ name: String) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let tone = folder.path("tone.wav")
        try TestMedia.wav(at: tone, seconds: 12)
        let movie = URL(fileURLWithPath: folder.path(name))
        try await TestMedia.movie(at: movie.path, seconds: 12, audio: URL(fileURLWithPath: tone))

        for samples in [try EmbeddingInput.soundtrack(at: movie, from: 2, duration: 5, sampleRate: 16_000),
                        try EmbeddingInput.audio(at: movie, from: 2, duration: 5, sampleRate: 16_000)] {
            #expect(abs(samples.count - 5 * 16_000) < 1600)
            #expect(!EmbeddingInput.isSilent(samples))
        }
        #expect(throws: EmbeddingError.unreadable(tone + ".none")) {
            try EmbeddingInput.soundtrack(at: URL(fileURLWithPath: tone + ".none"), from: 0, duration: 5, sampleRate: 16_000)
        }

        let silent = folder.path("silent.wav")
        try TestMedia.wav(at: silent, seconds: 3, silent: true)
        #expect(EmbeddingInput.isSilent(try EmbeddingInput.audio(at: URL(fileURLWithPath: silent), sampleRate: 16_000)))
    }

    /// The real request path: `EmbeddingClient` to the helper's loop over a
    /// fake backend, which decodes the files as the helper does.
    @Test func theHelperPathEmbedsEveryKindAndSkipsSilence() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try TestMedia.picture(at: folder.path("p.png"))
        try TestMedia.wav(at: folder.path("tone.wav"), seconds: 40)
        try TestMedia.wav(at: folder.path("quiet.wav"), seconds: 40, silent: true)
        let client = EmbeddingClient(launcher: InProcessLauncher(makeBackend: { _, _ in
            FakeEmbeddingBackend(textOnly: false)
        }))
        let cache = try VectorCache(url: folder.url.appendingPathComponent("VectorCache.sqlite"))
        func job(_ name: String, _ content: FileContent) -> MeaningJob {
            MeaningJob(id: 1, path: folder.path(name), content: content, size: 1, mtime: 0, isFirstStep: true, vecTo: 0)
        }

        let picture = try await MeaningReader.read(job("p.png", .image), with: client, cache: cache)
        #expect(picture.vectors.map(\.kind) == [.image])
        let sound = try await MeaningReader.read(job("tone.wav", .audio), with: client, cache: cache)
        #expect(sound.vectors.map(\.location) == [0, 25])
        #expect(sound.isComplete)
        let quiet = try await MeaningReader.read(job("quiet.wav", .audio), with: client, cache: cache)
        #expect(quiet.vectors.isEmpty, "the helper refuses silence")
        #expect(quiet.detail == "silent or too short")
    }
}
