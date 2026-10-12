import CoreGraphics
import Foundation
import Synchronization
@testable import codiclens

/// A backend with no model: each text's vector is a fixed function of the
/// text, so a test can tell answers apart. `onText` sees every text first and
/// may throw, or crash the helper it runs in.
final class FakeEmbeddingBackend: EmbeddingBackend, @unchecked Sendable {
    let isTextOnly: Bool
    let audioSampleRate = 16_000
    let closed = Mutex(false)
    private let onText: @Sendable (String) throws -> Void

    init(textOnly: Bool = true, onText: @escaping @Sendable (String) throws -> Void = { _ in }) {
        isTextOnly = textOnly
        self.onText = onText
    }

    /// The vector `embed(texts:)` gives `text`: one-hot at a place of its
    /// own (byte sum mod `dimension`), so two texts compare as 1 or 0.
    static func vector(for text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: EmbeddingVector.dimension)
        vector[text.utf8.reduce(0) { ($0 + Int($1)) % EmbeddingVector.dimension }] = 1
        return vector
    }

    func embed(texts: [String]) throws -> [[Float]] {
        try texts.map { text in
            try onText(text)
            return Self.vector(for: text)
        }
    }

    func embed(image: CGImage, budget: ImageBudget) throws -> [Float] {
        guard !isTextOnly else { throw EmbeddingError.textOnly }
        return Self.vector(for: "image \(image.width)×\(image.height) at \(budget.tokens)")
    }

    func embed(audio samples: [Float]) throws -> [Float] {
        guard !isTextOnly else { throw EmbeddingError.textOnly }
        return Self.vector(for: "audio \(samples.count)")
    }

    func close() {
        closed.withLock { $0 = true }
    }
}

/// Starts "helpers" in this process: the real `EmbeddingServiceLoop` over a
/// fake backend, behind a connection that can die the way a process does.
final class InProcessLauncher: EmbeddingServiceLauncher, @unchecked Sendable {
    /// The hello each helper gives; nil makes it fail to load.
    let failure: String?
    let idleExit: TimeInterval
    /// Builds each helper's backend; told which launch it is (1, 2, …) and
    /// the connection, so a backend can crash or exit its own helper.
    private let makeBackend: @Sendable (Int, InProcessConnection) -> FakeEmbeddingBackend
    private let state = Mutex<(launches: Int, connections: [InProcessConnection])>((0, []))
    let launched: AsyncStream<Int>
    private let launchedContinuation: AsyncStream<Int>.Continuation

    init(
        failure: String? = nil,
        idleExit: TimeInterval = 600,
        makeBackend: @escaping @Sendable (Int, InProcessConnection) -> FakeEmbeddingBackend = { _, _ in
            FakeEmbeddingBackend()
        }
    ) {
        self.failure = failure
        self.idleExit = idleExit
        self.makeBackend = makeBackend
        (launched, launchedContinuation) = AsyncStream.makeStream(of: Int.self)
    }

    var launches: Int { state.withLock { $0.launches } }
    var connections: [InProcessConnection] { state.withLock { $0.connections } }

    func launch(events: AsyncStream<EmbeddingServiceEvent>.Continuation) throws -> any EmbeddingServiceConnection {
        let connection = InProcessConnection(events: events)
        let launch = state.withLock { state -> Int in
            state.launches += 1
            state.connections.append(connection)
            return state.launches
        }
        if let failure {
            connection.deliver(EmbeddingServiceLine.encode(EmbeddingServiceHello(ready: false, error: failure)))
            connection.exit(status: 1, crashed: false)
        } else {
            let backend = makeBackend(launch, connection)
            connection.deliver(EmbeddingServiceLine.encode(EmbeddingServiceHello(ready: true, textOnly: true)))
            let loop = EmbeddingServiceLoop(
                backend: backend, idleExit: idleExit,
                write: { [weak connection] line in connection?.deliver(line) },
                finish: { [weak connection] status in connection?.exit(status: status, crashed: false) }
            )
            connection.loop = loop
            loop.start()
        }
        launchedContinuation.yield(launch)
        return connection
    }
}

final class InProcessConnection: EmbeddingServiceConnection, @unchecked Sendable {
    private let events: AsyncStream<EmbeddingServiceEvent>.Continuation
    private let alive = Mutex(true)
    private let buffer = Mutex(Data())
    /// Every request line it was sent.
    let received = Mutex<[EmbeddingRequest]>([])
    var loop: EmbeddingServiceLoop?

    init(events: AsyncStream<EmbeddingServiceEvent>.Continuation) {
        self.events = events
    }

    var processIdentifier: Int32? { nil }

    func send(_ line: Data) throws {
        guard alive.withLock({ $0 }) else { throw CocoaError(.fileWriteUnknown) }
        let lines = buffer.withLock { buffer in
            buffer.append(line)
            return EmbeddingServiceLine.takeLines(from: &buffer)
        }
        for line in lines {
            if let request = try? EmbeddingServiceLine.decode(EmbeddingRequest.self, from: line) {
                received.withLock { $0.append(request) }
            }
            loop?.receive(line)
        }
    }

    /// What the helper writes; dropped once it is dead.
    func deliver(_ data: Data) {
        guard alive.withLock({ $0 }) else { return }
        var data = data
        for line in EmbeddingServiceLine.takeLines(from: &data) {
            events.yield(.line(line))
        }
    }

    /// Killed by a signal, from any thread, mid-request included.
    func crash() {
        exit(status: 11, crashed: true)
    }

    func exit(status: Int32, crashed: Bool) {
        guard alive.withLock({ alive in defer { alive = false }; return alive }) else { return }
        events.yield(.exit(EmbeddingServiceExit(status: status, crashed: crashed)))
        events.finish()
    }
}
