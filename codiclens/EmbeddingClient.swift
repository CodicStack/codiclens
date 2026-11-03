// The query encoder's lifecycle follows DigUp's `Engine`
// (https://github.com/ARahim3/DigUp, MIT; see docs/licenses/digup/LICENSE).

import Foundation

/// The app's side of the embedding helper (`EmbeddingService`): starts it when
/// a vector is first asked for, keeps it while it is useful, starts another
/// when it has gone. Two of these are expected, one per kind of helper:
///
/// - **The query encoder** (`textOnly`): the text model alone, about 0.25 GB.
///   `hold()` when the Panel opens loads it before the first keystroke lands
///   and keeps it loaded however long the Panel stays open; `release()` when
///   it closes lets the helper's idle exit run again.
/// - **The indexer's** (full): the image and audio encoders too, about 1 GB,
///   asked for vectors in bursts and gone between them.
///
/// **A helper that dies is started again, but what it was answering is not
/// asked again.** A crash may have been the input's doing — a file that trips
/// the decoder — and asking again would crash it again, so every request in
/// flight fails with `crashed` and the caller decides. A *clean* exit with
/// requests in flight is the idle exit crossing a request on its way in; those
/// are sent again to a new helper, since nothing about them was at fault.
/// After `maxConsecutiveCrashes` crashes without one answer in between, the
/// client stops trying (`failed`) until the next `hold()`.
actor EmbeddingClient {
    enum State: Equatable, Sendable {
        case stopped
        case starting
        case ready
        /// The model would not load, or the helper kept crashing. Sticky until
        /// the next `hold()`.
        case failed(String)
    }

    static let maxConsecutiveCrashes = 3

    private(set) var state = State.stopped

    private let launcher: any EmbeddingServiceLauncher
    private var connection: (any EmbeddingServiceConnection)?
    /// Bumped per helper started, so events from one that is gone are ignored.
    private var generation = 0
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var pending: [Int: Pending] = [:]
    private var nextID = 1
    private var held = false
    /// The helper the hold was last sent to, so each one is told once.
    private var holdSentTo: Int?
    private var crashes = 0
    private var isFullSpeed = false

    private struct Pending {
        let request: EmbeddingRequest
        /// Nil for what the client sends on its own behalf (a hold re-sent to
        /// a new helper); its answer is dropped.
        let continuation: CheckedContinuation<EmbeddingResponse, Error>?
    }

    init(launcher: any EmbeddingServiceLauncher) {
        self.launcher = launcher
    }

    /// A client of this very binary, relaunched as the helper.
    static func helper(
        textOnly: Bool,
        models: URL = ModelFiles.defaultFolder,
        idleExit: TimeInterval
    ) -> EmbeddingClient {
        var options = EmbeddingService.Options()
        options.models = models
        options.textOnly = textOnly
        options.idleExit = idleExit
        return EmbeddingClient(launcher: HelperProcessLauncher(
            executable: Bundle.main.executableURL!,
            options: options,
            // App Nap and the efficiency cores can make a Query's vector
            // several times slower; indexing can wait.
            qualityOfService: textOnly ? .userInitiated : .utility
        ))
    }

    /// The helper's process, while there is one.
    var serviceProcessIdentifier: Int32? { connection?.processIdentifier }

    // MARK: - Holding

    /// Starts the helper if it is not running, returns once the model is
    /// loaded, and keeps it loaded until `release()`. A helper that crashes
    /// while held is started again straight away. Also the way out of
    /// `failed`: the model may have finished downloading since.
    func hold() async throws {
        held = true
        if case .failed = state {
            state = .stopped
            crashes = 0
        }
        while connection == nil || state != .ready {
            try await ready()
        }
        // A helper started for this hold was told at its hello.
        guard holdSentTo != generation else { return }
        holdSentTo = generation
        _ = try await request(EmbeddingRequest(id: 0, kind: .hold, on: true))
    }

    /// Lets the helper exit once it has been idle for its timeout. Starts
    /// nothing.
    func release() async {
        held = false
        guard connection != nil, state == .ready, holdSentTo == generation else { return }
        holdSentTo = nil
        _ = try? await request(EmbeddingRequest(id: 0, kind: .hold, on: false))
    }

    /// Asks the helper to exit now, and waits for its answer.
    func shutdown() async {
        held = false
        guard connection != nil, state == .ready else { return }
        _ = try? await request(EmbeddingRequest(id: 0, kind: .shutdown))
        // It exits after answering. Forgotten now, so the next request starts
        // another rather than writing to this one; its exit is ignored.
        generation += 1
        connection = nil
        state = .stopped
    }

    // MARK: - Vectors

    /// Whether the vectors asked for from now on are the meaning backfill's
    /// at full speed (`MeaningPace.full`): each request says so, and the
    /// helper keeps App Nap off while it answers one.
    func setFullSpeed(_ isFullSpeed: Bool) {
        self.isFullSpeed = isFullSpeed
    }

    /// `texts` already prompted (`EmbeddingPrompt`), one vector each.
    func embed(texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let vectors = try await vectors(EmbeddingRequest(id: 0, kind: .embedText, texts: texts))
        guard vectors.count == texts.count else { throw EmbeddingClientError.malformed }
        return vectors
    }

    /// What the user typed, as a search for files or, with `code`, for code.
    func embedQuery(_ text: String, code: Bool = false) async throws -> [Float] {
        try await one(EmbeddingRequest(
            id: 0, kind: .embedText, texts: [code ? EmbeddingPrompt.codeQuery(text) : EmbeddingPrompt.query(text)]
        ))
    }

    func embedImage(at url: URL, budget: ImageBudget) async throws -> [Float] {
        try await one(EmbeddingRequest(id: 0, kind: .embedImage, path: url.path, budget: budget))
    }

    /// An encoded image (PNG, JPEG, HEIC, …) rather than a file.
    func embedImage(data: Data, budget: ImageBudget) async throws -> [Float] {
        try await one(EmbeddingRequest(id: 0, kind: .embedImage, imageData: data, budget: budget))
    }

    /// Up to 30 seconds of the recording at `url`, from `start`.
    func embedAudio(
        at url: URL, from start: TimeInterval = 0, duration: TimeInterval = EmbeddingInput.audioWindow
    ) async throws -> [Float] {
        try await one(EmbeddingRequest(id: 0, kind: .embedAudio, path: url.path, start: start, duration: duration))
    }

    private func one(_ request: EmbeddingRequest) async throws -> [Float] {
        let vectors = try await vectors(request)
        guard vectors.count == 1 else { throw EmbeddingClientError.malformed }
        return vectors[0]
    }

    private func vectors(_ request: EmbeddingRequest) async throws -> [[Float]] {
        var request = request
        request.fullSpeed = isFullSpeed ? true : nil
        let response = try await self.request(request)
        if let error = response.error { throw EmbeddingClientError.failed(error) }
        guard let vectors = response.floatVectors else { throw EmbeddingClientError.malformed }
        return vectors
    }

    // MARK: - Requests

    /// Sends `request` under a fresh id once a helper is ready, and returns
    /// its answer.
    private func request(_ request: EmbeddingRequest) async throws -> EmbeddingResponse {
        var request = request
        // Waking from `ready` can find that helper already gone: wait for the
        // next one.
        while connection == nil || state != .ready {
            try await ready()
        }
        request.id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = Pending(request: request, continuation: continuation)
            send(request)
        }
    }

    /// Returns once a helper has said it is ready, starting one if need be.
    private func ready() async throws {
        if case .failed(let reason) = state { throw EmbeddingClientError.unavailable(reason) }
        if connection == nil { try launch() }
        if state == .ready { return }
        try await withCheckedThrowingContinuation { readyWaiters.append($0) }
    }

    private func send(_ request: EmbeddingRequest) {
        do {
            try connection?.send(EmbeddingServiceLine.encode(request))
        } catch {
            // The helper is going; its exit decides what happens to this.
        }
    }

    // MARK: - The helper's lifecycle

    private func launch() throws {
        generation += 1
        let generation = generation
        state = .starting
        let (events, continuation) = AsyncStream.makeStream(of: EmbeddingServiceEvent.self)
        do {
            connection = try launcher.launch(events: continuation)
        } catch {
            connection = nil
            state = .failed("Can't start the embedding helper: \(error.localizedDescription)")
            throw EmbeddingClientError.unavailable("\(error)")
        }
        Task { [weak self] in
            for await event in events {
                await self?.handle(event, from: generation)
            }
        }
    }

    private func handle(_ event: EmbeddingServiceEvent, from generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .line(let line):
            if state == .starting {
                hello(line)
            } else {
                answer(line)
            }
        case .exit(let exit):
            exited(exit)
        }
    }

    private func hello(_ line: Data) {
        let hello = try? EmbeddingServiceLine.decode(EmbeddingServiceHello.self, from: line)
        guard hello?.ready == true else {
            let reason = hello?.error ?? "the embedding helper did not start"
            state = .failed(reason)
            failAll(EmbeddingClientError.unavailable(reason))
            return
        }
        state = .ready
        let waiters = readyWaiters
        readyWaiters = []
        for waiter in waiters { waiter.resume() }
        if held {
            holdSentTo = generation
            let id = nextID
            nextID += 1
            pending[id] = Pending(request: EmbeddingRequest(id: id, kind: .hold, on: true), continuation: nil)
        }
        // Whatever else is pending was sent to a helper that exited cleanly
        // before answering it.
        for id in pending.keys.sorted() {
            send(pending[id]!.request)
        }
    }

    private func answer(_ line: Data) {
        guard let response = try? EmbeddingServiceLine.decode(EmbeddingResponse.self, from: line),
              let pending = pending.removeValue(forKey: response.id) else { return }
        crashes = 0
        pending.continuation?.resume(returning: response)
    }

    private func exited(_ exit: EmbeddingServiceExit) {
        connection = nil
        if case .failed = state {
            // It said why in its hello; the waiters already know.
            return
        }
        if exit.isClean && state == .ready {
            // The idle exit, or the app closed its stdin: start another only
            // if something is still waiting on it.
            state = .stopped
            if !pending.isEmpty || !readyWaiters.isEmpty || held { relaunch() }
            return
        }
        crashes += 1
        failAll(EmbeddingClientError.crashed)
        if crashes >= Self.maxConsecutiveCrashes {
            state = .failed("The embedding helper stopped \(crashes) times in a row")
        } else {
            state = .stopped
            if held { relaunch() }
        }
    }

    /// Starts the next helper for what is waiting; if none will start,
    /// nothing is left waiting for it.
    private func relaunch() {
        do {
            try launch()
        } catch {
            failAll(error)
        }
    }

    private func failAll(_ error: Error) {
        let waiters = readyWaiters
        readyWaiters = []
        for waiter in waiters { waiter.resume(throwing: error) }
        let requests = pending
        pending = [:]
        for request in requests.values { request.continuation?.resume(throwing: error) }
    }
}

nonisolated enum EmbeddingClientError: Error, Equatable, CustomStringConvertible {
    /// The helper could not load the model, or has stopped trying.
    case unavailable(String)
    /// The helper died before answering.
    case crashed
    /// The helper answered with why it could not.
    case failed(String)
    /// An answer that does not fit the request.
    case malformed

    var description: String {
        switch self {
        case .unavailable(let reason): "search by meaning is unavailable: \(reason)"
        case .crashed: "the embedding helper stopped before answering"
        case .failed(let reason): reason
        case .malformed: "the embedding helper's answer did not fit the request"
        }
    }
}

// MARK: - Starting a helper

/// What a running helper sends back, in order: its lines, then its exit.
nonisolated enum EmbeddingServiceEvent: Sendable {
    case line(Data)
    case exit(EmbeddingServiceExit)
}

nonisolated struct EmbeddingServiceExit: Equatable, Sendable {
    var status: Int32
    /// Killed by a signal: a crash, or the system reclaiming memory.
    var crashed: Bool

    var isClean: Bool { !crashed && status == 0 }
}

/// A running helper's stdin.
nonisolated protocol EmbeddingServiceConnection: AnyObject, Sendable {
    var processIdentifier: Int32? { get }
    func send(_ line: Data) throws
}

/// Starts a helper. The real one is a process (`HelperProcessLauncher`); tests
/// run the request loop in this process.
nonisolated protocol EmbeddingServiceLauncher: Sendable {
    /// Starts one. Every line it writes, and then its exit, go to `events`,
    /// which is finished after the exit.
    func launch(events: AsyncStream<EmbeddingServiceEvent>.Continuation) throws -> any EmbeddingServiceConnection
}

/// This app's binary, relaunched with `EmbeddingService.flag`.
nonisolated struct HelperProcessLauncher: EmbeddingServiceLauncher {
    let executable: URL
    let options: EmbeddingService.Options
    let qualityOfService: QualityOfService

    /// What the helper inherits of the app's environment: the basics and
    /// nothing else. In the unit-test host the environment carries XCTest's
    /// `DYLD_INSERT_LIBRARIES` and `XCTestConfigurationFilePath`, and a helper
    /// that inherited them would load the test bundle and run every test a
    /// second time inside itself.
    static let inherited: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "SHELL"]

    static func environment(from environment: [String: String]) -> [String: String] {
        environment.filter { inherited.contains($0.key) }
    }

    func launch(events: AsyncStream<EmbeddingServiceEvent>.Continuation) throws -> any EmbeddingServiceConnection {
        let process = Process()
        process.executableURL = executable
        process.arguments = options.arguments
        process.environment = Self.environment(from: ProcessInfo.processInfo.environment)
        process.qualityOfService = qualityOfService
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // stderr is the app's: llama.cpp's warnings land in its log.
        // A helper that has exited makes a write fail with EPIPE instead of
        // raising SIGPIPE, whose default action would kill the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()

        let reader = output.fileHandleForReading
        Thread.detachNewThread {
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                for line in EmbeddingServiceLine.takeLines(from: &buffer) {
                    events.yield(.line(line))
                }
            }
            // stdout closes as the helper exits; every line is in by now.
            process.waitUntilExit()
            events.yield(.exit(EmbeddingServiceExit(
                status: process.terminationStatus, crashed: process.terminationReason == .uncaughtSignal
            )))
            events.finish()
        }
        return HelperProcess(process: process, input: input.fileHandleForWriting)
    }

    private final class HelperProcess: EmbeddingServiceConnection, @unchecked Sendable {
        let process: Process
        let input: FileHandle

        init(process: Process, input: FileHandle) {
            self.process = process
            self.input = input
        }

        var processIdentifier: Int32? { process.processIdentifier }

        func send(_ line: Data) throws {
            try input.write(contentsOf: line)
        }

        /// Closing stdin is how the helper learns the app has gone.
        deinit {
            try? input.close()
        }
    }
}
