import Darwin
import Foundation
import Synchronization
import Testing
@testable import codiclens

private let downloadRequested = ProcessInfo.processInfo.environment["CODICLENS_DOWNLOAD_MODEL_FILES"] != nil
private let integrationRuns = ProcessInfo.processInfo.environment["CODICLENS_EMBEDDING_INTEGRATION"].flatMap { Int($0) }

/// The real download, into the real models folder in Application Support,
/// broken off once on purpose after 50 MB and resumed, so the resume path is
/// checked against Hugging Face's CDN rather than a fake. ~865 MB; off unless
/// asked for. Does nothing when the files are already there.
///
/// ```
/// TEST_RUNNER_CODICLENS_DOWNLOAD_MODEL_FILES=1 xcodebuild test \
///   -project codiclens.xcodeproj -scheme codiclens -configuration Debug \
///   -parallel-testing-enabled NO \
///   -only-testing:codiclensTests/ModelFilesDownloadTests
/// ```
@MainActor
@Suite(.serialized, .enabled(if: downloadRequested), .timeLimit(.minutes(30)))
struct ModelFilesDownloadTests {
    @Test func downloadsBothFilesResumingOnce() async throws {
        let downloader = BreakOnceDownloader(after: 50 << 20)
        let files = ModelFiles(downloader: downloader)
        guard !files.isReady else {
            print("model files already in \(files.folder.path)")
            return
        }
        downloader.onBreak = { Task { @MainActor in files.cancel() } }

        let started = ContinuousClock.now
        await files.download()
        #expect(files.state == .notDownloaded)
        let resume = files.folder.appendingPathComponent(ModelFiles.text.name + ".resume")
        #expect(FileManager.default.fileExists(atPath: resume.path))

        await files.download()
        #expect(files.state == .ready)
        let resumedAt = downloader.firstProgress.withLock { $0 }
        print("downloaded in \(ContinuousClock.now - started); the second attempt's first progress was at",
              "\(resumedAt.dropFirst().first ?? -1) bytes (0 would mean it started over)")
        #expect((resumedAt.dropFirst().first ?? 0) >= 50 << 20)
    }
}

/// URLSession, told to break off the first download once `after` bytes are in.
private final class BreakOnceDownloader: ModelFileDownloader, @unchecked Sendable {
    let inner = URLSessionModelFileDownloader()
    let after: Int64
    var onBreak: (@Sendable () -> Void)?
    private let broken = Mutex(false)
    /// The first progress each call reported.
    let firstProgress = Mutex<[Int64]>([])

    init(after: Int64) {
        self.after = after
    }

    func download(
        from url: URL, to destination: URL, resumeData: Data?, progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let call = firstProgress.withLock { $0.count }
        firstProgress.withLock { $0.append(-1) }
        let onBreak = onBreak
        try await inner.download(from: url, to: destination, resumeData: resumeData) { [self] received in
            firstProgress.withLock { if $0[call] < 0 { $0[call] = received } }
            if received >= after, broken.withLock({ broken in defer { broken = true }; return !broken }) {
                onBreak?()
            }
            progress(received)
        }
    }
}

/// EmbeddingGemma 2 itself, through the real helper process and the model
/// files in Application Support: does it rank meaning, and how fast and how
/// big is it. Off unless asked for, and the files must be there (see
/// `ModelFilesDownloadTests`). The value is how many warm Queries to time.
///
/// ```
/// TEST_RUNNER_CODICLENS_EMBEDDING_INTEGRATION=30 xcodebuild test \
///   -project codiclens.xcodeproj -scheme codiclens -configuration Debug \
///   -parallel-testing-enabled NO \
///   -only-testing:codiclensTests/EmbeddingIntegrationTests
/// ```
@Suite(.serialized, .enabled(if: integrationRuns != nil), .timeLimit(.minutes(10)))
struct EmbeddingIntegrationTests {
    let runs = integrationRuns ?? 10

    @Test func theQueryEncoderRanksMeaningAndAnswersQuickly() async throws {
        try await #require(MainActor.run { ModelFiles().isReady }, "download the model files first")
        let client = EmbeddingClient.helper(.queries, idleExit: 60)

        let cold = try await ContinuousClock().measure { try await client.hold() }
        let pid = try #require(await client.serviceProcessIdentifier)
        print("query encoder: cold start (spawn, load, warm-up) \(Self.ms(cold)), \(Self.footprint(pid))")

        let kontrakt = try await client.embedQuery("kontrakt med Nordlys")
        let employment = try await client.embedQuery("employment contract")
        let banana = try await client.embedQuery("banana")
        for vector in [kontrakt, employment, banana] {
            #expect(vector.count == EmbeddingVector.dimension)
            #expect(abs(vector.reduce(0) { $0 + $1 * $1 } - 1) < 1e-2)
        }
        let similar = EmbeddingVector.cosine(kontrakt, employment)
        print(String(format: "cosine: kontrakt/employment %.3f, kontrakt/banana %.3f, employment/banana %.3f",
                     similar, EmbeddingVector.cosine(kontrakt, banana), EmbeddingVector.cosine(employment, banana)))
        #expect(similar > EmbeddingVector.cosine(kontrakt, banana))
        #expect(similar > EmbeddingVector.cosine(employment, banana))

        // Documents are found by queries across languages.
        let documents = try await client.embed(texts: [
            EmbeddingPrompt.document(title: "Ansættelseskontrakt.pdf", text: "Ansættelseskontrakt mellem Nordlys ApS og medarbejderen. Løn, arbejdstid og opsigelse."),
            EmbeddingPrompt.document(title: "Smoothie.txt", text: "Blend two bananas with yoghurt and a little honey."),
        ])
        #expect(EmbeddingVector.cosine(employment, documents[0]) > EmbeddingVector.cosine(employment, documents[1]))
        #expect(EmbeddingVector.cosine(banana, documents[1]) > EmbeddingVector.cosine(banana, documents[0]))

        // Warm: what a keystroke costs, every Query new.
        var times: [Duration] = []
        for run in 0..<runs {
            let query = "invoice from march \(run)"
            times.append(try await ContinuousClock().measure { _ = try await client.embedQuery(query) })
        }
        times.sort()
        print("query encoder: warm Query median \(Self.ms(times[times.count / 2])), p90",
              "\(Self.ms(times[times.count * 9 / 10])) over \(runs), \(Self.footprint(pid))")
        await client.shutdown()
    }

    @Test func theFullHelperEmbedsImagesAndAudio() async throws {
        try await #require(MainActor.run { ModelFiles().isReady }, "download the model files first")
        let client = EmbeddingClient.helper(.indexing, idleExit: 60)

        let cold = try await ContinuousClock().measure { try await client.hold() }
        let pid = try #require(await client.serviceProcessIdentifier)
        print("full helper: cold start \(Self.ms(cold)), \(Self.footprint(pid))")

        let zebra = URL(fileURLWithPath: "/Library/User Pictures/Animals/Zebra.heic")
        var image: [Float] = []
        let first = try await ContinuousClock().measure { image = try await client.embedImage(at: zebra, budget: .photo) }
        let warm = try await ContinuousClock().measure { _ = try await client.embedImage(at: zebra, budget: .photo) }
        let screenshotFirst = try await ContinuousClock().measure {
            _ = try await client.embedImage(at: zebra, budget: .screenshot)
        }
        let screenshot = try await ContinuousClock().measure {
            _ = try await client.embedImage(at: zebra, budget: .screenshot)
        }
        let aZebra = try await client.embedQuery("a zebra")
        let contract = try await client.embedQuery("employment contract")
        print(String(format: "image: at 140 first %@, warm %@; at 280 first %@, warm %@; cosine with 'a zebra' %.3f, 'employment contract' %.3f",
                     Self.ms(first), Self.ms(warm), Self.ms(screenshotFirst), Self.ms(screenshot),
                     EmbeddingVector.cosine(image, aZebra), EmbeddingVector.cosine(image, contract)))
        #expect(EmbeddingVector.cosine(image, aZebra) > EmbeddingVector.cosine(image, contract))

        // 30 seconds of speech about one thing.
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let speech = folder.url.appendingPathComponent("speech.aiff")
        try Self.say("""
            Before you sign the employment contract, read the clauses about salary, working hours and \
            notice periods. The contract between the company and the employee says the notice period is \
            three months, and that overtime is paid. Ask the employer about the pension and the holiday \
            allowance, and keep a signed copy of the employment contract for your records. \
            If anything in the contract is unclear, ask before you sign it.
            """, to: speech)
        var audio: [Float] = []
        let audioFirst = try await ContinuousClock().measure {
            audio = try await client.embedAudio(at: speech, duration: 30)
        }
        let audioTime = try await ContinuousClock().measure {
            audio = try await client.embedAudio(at: speech, duration: 30)
        }
        let banana = try await client.embedQuery("banana")
        print(String(format: "audio: 30 s window first %@, warm %@; cosine with 'employment contract' %.3f, 'banana' %.3f; %@",
                     Self.ms(audioFirst), Self.ms(audioTime), EmbeddingVector.cosine(audio, contract), EmbeddingVector.cosine(audio, banana),
                     Self.footprint(pid)))
        #expect(audio.count == EmbeddingVector.dimension)
        await client.shutdown()
    }

    /// `text` spoken by the system voice into an AIFF.
    private static func say(_ text: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private static func ms(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return String(format: "%.1f ms", Double(seconds) * 1000 + Double(attoseconds) / 1e15)
    }

    /// The helper's memory as Activity Monitor counts it, now and at its peak.
    private static func footprint(_ pid: Int32) -> String {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return "footprint unavailable" }
        return String(format: "footprint %.0f MB (peak %.0f MB)",
                      Double(info.ri_phys_footprint) / 1_048_576, Double(info.ri_lifetime_max_phys_footprint) / 1_048_576)
    }
}
