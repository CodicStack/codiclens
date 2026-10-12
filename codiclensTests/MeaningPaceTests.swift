import Foundation
import Synchronization
import Testing
@testable import codiclens

/// How hard the meaning backfill works (`MeaningPace`), from made-up power
/// sources and idle times: what is decided, that the batch loop decides it
/// again for every batch, and that the helper hears it.
struct MeaningPaceTests {
    static func machine(onPower: Bool, idle: TimeInterval) -> MeaningPace.Machine {
        MeaningPace.Machine(isOnPower: { onPower }, idleSeconds: { idle })
    }

    static let away = machine(onPower: true, idle: MeaningPace.idleAfter)

    @Test func fullSpeedOnlyOnPowerWithTheUserAwayAndThePanelClosed() {
        #expect(MeaningPace(isLowPower: false, isPanelOpen: false, machine: Self.away) == .full)
        #expect(MeaningPace(isLowPower: false, isPanelOpen: false,
                            machine: Self.machine(onPower: true, idle: MeaningPace.idleAfter - 1)) == .gentle)
        #expect(MeaningPace(isLowPower: false, isPanelOpen: false,
                            machine: Self.machine(onPower: false, idle: 3600)) == .gentle, "on battery")
        #expect(MeaningPace(isLowPower: true, isPanelOpen: false, machine: Self.away) == .paused)
        #expect(MeaningPace(isLowPower: true, isPanelOpen: true, machine: Self.away) == .paused)
        #expect(MeaningPace(isLowPower: false, isPanelOpen: true, machine: Self.away) == .gentle,
                "the Panel's query encoder comes first")
    }

    @Test func lowPowerModeAndThePanelSettleItWithoutAskingTheMachine() {
        let asked = Mutex(0)
        let machine = MeaningPace.Machine(isOnPower: { asked.withLock { $0 += 1 }; return true },
                                          idleSeconds: { asked.withLock { $0 += 1 }; return 3600 })
        _ = MeaningPace(isLowPower: true, isPanelOpen: false, machine: machine)
        _ = MeaningPace(isLowPower: false, isPanelOpen: true, machine: machine)
        #expect(asked.withLock { $0 } == 0)
    }

    @Test func aFullBatchIsBiggerAndThePanelMakesTheNextOneGentle() async throws {
        let f = try MeaningFixture(machine: Self.away)
        for index in 0..<40 { try f.make("n\(index).md", contents: "note \(index) about the budget") }
        try f.crawl()
        try await f.readContents()

        #expect(f.meaning.pace == .full)
        #expect(try f.meaning.nextBatch().count == MeaningPace.fullBatchSize)
        f.meaning.setPanelOpen(true)
        #expect(f.meaning.pace == .gentle)
        #expect(try f.meaning.nextBatch().count == MeaningPace.gentleBatchSize)
        f.meaning.setLowPower(true)
        #expect(try f.meaning.nextBatch().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func theBatchLoopDecidesThePaceAgainForEveryBatch() async throws {
        let f = try MeaningFixture()
        for index in 0..<50 { try f.make("n\(index).md", contents: "note \(index) about the budget") }
        try f.crawl()
        try await f.readContents()
        f.meaning.disable()

        let idle = Mutex<TimeInterval>(0)
        let batches = Mutex<[(pace: MeaningPace, files: Int)]>([])
        let (stored, storedContinuation) = AsyncStream.makeStream(of: Void.self)
        let embed = MeaningScheduler.embedAll(with: f.embedder, cache: f.cache)
        let queue = DispatchQueue(label: "test.pace")
        let meaning = MeaningScheduler(
            writer: f.writer, vectors: f.vectors, cache: f.cache, queue: queue,
            embed: { jobs, pace in
                batches.withLock { $0.append((pace, jobs.count)) }
                // The user walks away during the first batch.
                idle.withLock { $0 = MeaningPace.idleAfter }
                return try await embed(jobs, pace)
            },
            machine: MeaningPace.Machine(isOnPower: { true }, idleSeconds: { idle.withLock { $0 } }),
            onProgress: { _ in storedContinuation.yield() }
        )
        meaning.setSources([f.root])
        try queue.sync { try meaning.enable() }
        queue.async { meaning.resume() }

        var iterator = stored.makeAsyncIterator()
        for _ in 0..<3 { await iterator.next() }
        // The third store's own `resume()`, which finds nothing, done too.
        queue.sync {}
        #expect(batches.withLock { $0.map(\.pace) } == [.gentle, .full, .full])
        #expect(batches.withLock { $0.map(\.files) } == [MeaningPace.gentleBatchSize, MeaningPace.fullBatchSize, 10])
        #expect(f.embedder.fullSpeeds.withLock { $0 } == [false, true, true], "the helper is told each batch's pace")
        #expect(try f.count("SELECT COUNT(*) FROM files WHERE vec_state != 'done'") == 0)
    }

    @Test func theClientMarksItsRequestsWhileAtFullSpeed() async throws {
        let launcher = InProcessLauncher()
        let client = EmbeddingClient(launcher: launcher)
        _ = try await client.embed(texts: ["gentle"])
        await client.setFullSpeed(true)
        _ = try await client.embed(texts: ["full"])
        _ = try await client.embedQuery("full too")
        await client.setFullSpeed(false)
        _ = try await client.embed(texts: ["gentle again"])

        let received = try #require(launcher.connections.first).received.withLock { $0 }
        #expect(received.map(\.fullSpeed) == [nil, true, true, nil])
    }
}
