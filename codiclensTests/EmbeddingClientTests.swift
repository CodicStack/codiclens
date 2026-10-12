import Foundation
import Synchronization
import Testing
@testable import codiclens

/// The app's side of the helper: starting it, holding it, and what happens
/// when it dies. In-process helpers over a fake backend, and one real helper
/// process that has no model to load.
struct EmbeddingClientTests {

    @Test func theFirstRequestStartsAHelperAndLaterOnesReuseIt() async throws {
        let launcher = InProcessLauncher()
        let client = EmbeddingClient(launcher: launcher)
        #expect(await client.state == .stopped)

        let first = try await client.embedQuery("banana")
        let second = try await client.embed(texts: ["title: none | text: a", "title: none | text: b"])

        #expect(first == FakeEmbeddingBackend.vector(for: "task: search result | query: banana"))
        #expect(second.count == 2)
        #expect(launcher.launches == 1)
        #expect(await client.state == .ready)
    }

    @Test func aCodeQueryTakesTheCodePrompt() async throws {
        let client = EmbeddingClient(launcher: InProcessLauncher())
        let vector = try await client.embedQuery("retry with backoff", code: true)
        #expect(vector == FakeEmbeddingBackend.vector(for: "task: code retrieval | query: retry with backoff"))
    }

    @Test func concurrentRequestsEachGetTheirOwnAnswer() async throws {
        let client = EmbeddingClient(launcher: InProcessLauncher())
        let texts = (0..<20).map { "text \($0)" }
        let vectors = try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask { (index, try await client.embed(texts: [text])[0]) }
            }
            var vectors = [[Float]](repeating: [], count: texts.count)
            for try await (index, vector) in group { vectors[index] = vector }
            return vectors
        }
        #expect(vectors == texts.map(FakeEmbeddingBackend.vector(for:)))
    }

    @Test func anErrorFromTheHelperIsThrownAndTheHelperStays() async throws {
        let launcher = InProcessLauncher(makeBackend: { _, _ in
            FakeEmbeddingBackend(onText: { if $0 == "bad" { throw EmbeddingError.failed("no") } })
        })
        let client = EmbeddingClient(launcher: launcher)
        await #expect(throws: EmbeddingClientError.failed("no")) {
            try await client.embed(texts: ["bad"])
        }
        #expect(try await client.embed(texts: ["good"]).count == 1)
        #expect(launcher.launches == 1)
    }

    /// The input that crashed the helper is not asked again; the next request
    /// starts a new one.
    @Test func aCrashFailsTheRequestAndTheNextRequestRestartsTheHelper() async throws {
        let launcher = InProcessLauncher(makeBackend: { _, connection in
            FakeEmbeddingBackend(onText: { if $0 == "poison" { connection.crash() } })
        })
        let client = EmbeddingClient(launcher: launcher)

        await #expect(throws: EmbeddingClientError.crashed) {
            try await client.embed(texts: ["poison"])
        }
        let vector = try await client.embed(texts: ["fine"])

        #expect(vector == [FakeEmbeddingBackend.vector(for: "fine")])
        #expect(launcher.launches == 2)
        let resent = launcher.connections[1].received.withLock { $0 }.compactMap(\.texts).flatMap { $0 }
        #expect(resent == ["fine"])
    }

    @Test func aHelperThatKeepsCrashingIsGivenUpOnUntilTheNextHold() async throws {
        let launcher = InProcessLauncher(makeBackend: { _, connection in
            FakeEmbeddingBackend(onText: { if $0 == "poison" { connection.crash() } })
        })
        let client = EmbeddingClient(launcher: launcher)

        for _ in 0..<EmbeddingClient.maxConsecutiveCrashes {
            await #expect(throws: EmbeddingClientError.crashed) {
                try await client.embed(texts: ["poison"])
            }
        }
        guard case .failed = await client.state else {
            Issue.record("expected failed, got \(await client.state)")
            return
        }
        await #expect(throws: EmbeddingClientError.self) {
            try await client.embed(texts: ["fine"])
        }
        #expect(launcher.launches == EmbeddingClient.maxConsecutiveCrashes)

        try await client.hold()
        #expect(try await client.embed(texts: ["fine"]).count == 1)
        #expect(launcher.launches == EmbeddingClient.maxConsecutiveCrashes + 1)
    }

    /// A helper that exits cleanly with a request on its way in — the idle
    /// exit crossing it — has the request sent again to the next one.
    @Test func aRequestCrossingTheIdleExitIsSentAgain() async throws {
        let launcher = InProcessLauncher(makeBackend: { launch, connection in
            FakeEmbeddingBackend(onText: { _ in
                if launch == 1 { connection.exit(status: 0, crashed: false) }
            })
        })
        let client = EmbeddingClient(launcher: launcher)

        let vector = try await client.embed(texts: ["crossing"])

        #expect(vector == [FakeEmbeddingBackend.vector(for: "crossing")])
        #expect(launcher.launches == 2)
    }

    /// While the Panel holds it, a helper that dies is replaced at once, and
    /// the new one is told it is held.
    @Test func aHeldHelperThatCrashesIsStartedAgainAndHeld() async throws {
        let launcher = InProcessLauncher()
        var launches = launcher.launched.makeAsyncIterator()
        let client = EmbeddingClient(launcher: launcher)

        try await client.hold()
        #expect(await launches.next() == 1)
        launcher.connections[0].crash()
        #expect(await launches.next() == 2)

        // The replacement answers, and it was told about the hold first.
        #expect(try await client.embed(texts: ["after"]).count == 1)
        let kinds = launcher.connections[1].received.withLock { $0 }.map(\.kind)
        #expect(kinds == [.hold, .embedText])
        #expect(launcher.connections[1].received.withLock { $0 }.first?.on == true)
    }

    @Test func holdingTellsTheHelperOnceAndReleasingLetsItGo() async throws {
        let launcher = InProcessLauncher()
        let client = EmbeddingClient(launcher: launcher)

        try await client.hold()
        try await client.hold()
        await client.release()
        await client.release()

        let holds = launcher.connections[0].received.withLock { $0 }.filter { $0.kind == .hold }.map(\.on)
        #expect(holds == [true, false])
    }

    @Test func aModelThatWillNotLoadMakesTheClientUnavailable() async throws {
        let launcher = InProcessLauncher(failure: "embeddinggemma-2-Q8_0.gguf is not downloaded")
        let client = EmbeddingClient(launcher: launcher)

        await #expect(throws: EmbeddingClientError.unavailable("embeddinggemma-2-Q8_0.gguf is not downloaded")) {
            try await client.embedQuery("x")
        }
        // Sticky: no helper started per keystroke while there is no model.
        await #expect(throws: EmbeddingClientError.self) {
            try await client.embedQuery("y")
        }
        #expect(launcher.launches == 1)
    }

    @Test func shutdownStopsTheHelper() async throws {
        let launcher = InProcessLauncher()
        let client = EmbeddingClient(launcher: launcher)
        _ = try await client.embedQuery("x")

        await client.shutdown()

        #expect(launcher.connections[0].received.withLock { $0 }.last?.kind == .shutdown)
        _ = try await client.embedQuery("y")
        #expect(launcher.launches == 2)
    }

    // MARK: - A real helper process

    /// This binary, relaunched as the helper over a models folder with nothing
    /// in it: it starts with none of the app (no Panel, no tests run inside
    /// it), says why it cannot load, and exits.
    @Test(.timeLimit(.minutes(1)))
    func theRealHelperSaysWhenTheModelIsMissing() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        var options = EmbeddingService.Options()
        options.models = folder.url
        options.textOnly = true
        options.idleExit = 30
        let client = EmbeddingClient(launcher: HelperProcessLauncher(
            executable: try #require(Bundle.main.executableURL), options: options, qualityOfService: .userInitiated
        ))

        await #expect(throws: EmbeddingClientError.unavailable("embeddinggemma-2-Q8_0.gguf is not downloaded")) {
            try await client.embedQuery("kontrakt med Repodo")
        }
        guard case .failed = await client.state else {
            Issue.record("expected failed, got \(await client.state)")
            return
        }
    }
}
