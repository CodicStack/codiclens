// The helper's shape follows DigUp's `digup worker` (https://github.com/ARahim3/DigUp, MIT; see docs/licenses/digup/LICENSE).

import CoreGraphics
import Foundation

/// The embedding helper: this same app binary, relaunched by
/// `EmbeddingClient` as `codiclens --embedding-service`, with no UI, no Panel
/// and no File Index (`AppDelegate` short-circuits into `start()`). It loads
/// EmbeddingGemma 2, says so in one line, then answers JSON-lines requests on
/// stdin until it is told to stop, the app goes away, or it has been idle for
/// its timeout (`EmbeddingServiceProtocol.swift`).
///
/// A process of its own so the model's memory (about 1 GB with the image and
/// audio encoders, 0.25 GB text-only) goes back to the system when it exits,
/// and a crash in llama.cpp or Metal takes down the helper rather than the
/// Panel.
///
/// Arguments after the flag:
///   `--models <folder>`  where the GGUF files are (default `ModelFiles.defaultFolder`)
///   `--text-only`        the text model alone: the query encoder, or the Text choice's indexer
///   `--max-tokens <n>`   the longest input, in tokens (default 2048; the query encoder's 512)
///   `--idle-exit <s>`    seconds without a request, outside a hold, before it exits
nonisolated enum EmbeddingService {
    static let flag = "--embedding-service"

    struct Options: Equatable {
        var models = ModelFiles.defaultFolder
        var textOnly = false
        /// One input has to fit: 2,048 tokens (the reference's cut) holds a
        /// 1,120-token image, the ~750 tokens of 30 seconds of audio and a
        /// Passage of 4,000 characters.
        var maxTokens = 2048
        var idleExit: TimeInterval = 60

        init() {}

        init(arguments: [String]) {
            var rest = arguments.drop { $0 != EmbeddingService.flag }.dropFirst()[...]
            while let argument = rest.popFirst() {
                switch argument {
                case "--models": if let path = rest.popFirst() { models = URL(fileURLWithPath: path) }
                case "--text-only": textOnly = true
                case "--max-tokens": if let tokens = rest.popFirst().flatMap(Int.init), tokens > 1 { maxTokens = tokens }
                case "--idle-exit": if let seconds = rest.popFirst().flatMap(TimeInterval.init) { idleExit = seconds }
                default: break
                }
            }
        }

        var arguments: [String] {
            [EmbeddingService.flag, "--models", models.path, "--idle-exit", String(idleExit),
             "--max-tokens", String(maxTokens)]
                + (textOnly ? ["--text-only"] : [])
        }
    }

    static func isRequested(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(flag)
    }

    /// Runs the helper on a thread of its own and returns. The process exits
    /// from there, so the main thread is left alone to the run loop AppKit is
    /// already in.
    static func start(arguments: [String] = CommandLine.arguments) {
        let options = Options(arguments: arguments)
        // The protocol gets the real stdout to itself, and anything else that
        // prints — llama.cpp, Metal, a stray `print` — lands in stderr instead
        // of in the middle of a line the app is reading. A closed pipe (the
        // app quit) is an error on write, not a signal that kills us.
        signal(SIGPIPE, SIG_IGN)
        let output = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        let write: @Sendable (Data) -> Void = { line in try? output.write(contentsOf: line) }

        Thread.detachNewThread {
            let started = ContinuousClock.now
            let backend: any EmbeddingBackend
            do {
                backend = try makeBackend(options)
            } catch {
                write(EmbeddingServiceLine.encode(EmbeddingServiceHello(ready: false, error: "\(error)")))
                exit(1)
            }
            let elapsed = (ContinuousClock.now - started).components
            write(EmbeddingServiceLine.encode(EmbeddingServiceHello(
                ready: true, textOnly: backend.isTextOnly,
                loadSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18, llama: llamaBuild
            )))
            let loop = EmbeddingServiceLoop(
                backend: backend, idleExit: options.idleExit, write: write, finish: { exit($0) }
            )
            loop.start()
            while let line = readLine(strippingNewline: true) {
                loop.receive(Data(line.utf8))
            }
            loop.inputEnded()
        }
    }

    private static func makeBackend(_ options: Options) throws -> any EmbeddingBackend {
        #if arch(arm64)
        guard MeaningSearch.isSupported else { throw EmbeddingError.unsupported }
        let text = options.models.appendingPathComponent(ModelFiles.text.name)
        guard FileManager.default.fileExists(atPath: text.path) else {
            throw EmbeddingError.modelMissing(ModelFiles.text.name)
        }
        var media: URL?
        if !options.textOnly {
            let file = options.models.appendingPathComponent(ModelFiles.media.name)
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw EmbeddingError.modelMissing(ModelFiles.media.name)
            }
            media = file
        }
        return try Embedder(text: text, media: media, maxTokens: options.maxTokens)
        #else
        throw EmbeddingError.unsupported
        #endif
    }

    private static var llamaBuild: String {
        #if arch(arm64)
        Embedder.buildTag
        #else
        "none"
        #endif
    }
}

/// The helper's request loop, apart from the process around it: requests in
/// as lines, answers out as lines, one at a time on one queue. Tests drive it
/// over a fake backend; `EmbeddingService.start` drives it over stdin.
///
/// **The idle exit is a lifecycle deadline, not a timing hack.** After each
/// answer, unless the app holds the helper, a one-shot timer on the request
/// queue is armed for `idleExit` seconds and the next request cancels it. If
/// it fires, nothing has been asked for that long, so the helper exits and its
/// memory goes back to the system; the app starts another on the next request.
/// Nothing waits on it and nothing is papered over by it.
nonisolated final class EmbeddingServiceLoop: @unchecked Sendable {
    private let backend: any EmbeddingBackend
    private let idleExit: TimeInterval
    private let write: @Sendable (Data) -> Void
    private let finish: @Sendable (Int32) -> Void
    private let queue = DispatchQueue(label: "codiclens.embedding-service")

    // On `queue`.
    private var held = false
    private var idleTimer: DispatchSourceTimer?
    private var finished = false
    /// Keeps App Nap off the helper while it is held: a napping process
    /// answers a Query several times slower.
    private var activity: NSObjectProtocol?

    /// `finish` is called once, with the exit status, after the backend is
    /// closed. In the helper it exits the process.
    init(
        backend: any EmbeddingBackend,
        idleExit: TimeInterval,
        write: @escaping @Sendable (Data) -> Void,
        finish: @escaping @Sendable (Int32) -> Void
    ) {
        self.backend = backend
        self.idleExit = idleExit
        self.write = write
        self.finish = finish
    }

    /// Arms the first idle deadline: a helper nobody asks anything of exits.
    func start() {
        queue.async { [self] in armIdleExit() }
    }

    func receive(_ line: Data) {
        queue.async { [self] in
            guard !finished else { return }
            idleTimer?.cancel()
            idleTimer = nil
            handle(line)
            armIdleExit()
        }
    }

    /// The app closed our stdin: it quit or crashed, so there is nobody left
    /// to answer.
    func inputEnded() {
        queue.async { [self] in end(0) }
    }

    private func handle(_ line: Data) {
        let request: EmbeddingRequest
        do {
            request = try EmbeddingServiceLine.decode(EmbeddingRequest.self, from: line)
        } catch {
            // No id to answer to; the app only ever writes requests.
            FileHandle.standardError.write(Data("[embedding-service] unreadable request: \(error)\n".utf8))
            return
        }
        var response = EmbeddingResponse(id: request.id)
        // The backfill at full speed: App Nap off for this request.
        let activity = request.fullSpeed == true ? ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Search by meaning is catching up while the Mac is idle"
        ) : nil
        defer { if let activity { ProcessInfo.processInfo.endActivity(activity) } }
        do {
            switch request.kind {
            case .embedText:
                response.vectors = try backend.embed(texts: request.texts ?? []).map(EmbeddingVector.float16Data)
            case .embedImage:
                let image: CGImage
                if let data = request.imageData {
                    image = try EmbeddingInput.image(data: data)
                } else if let path = request.path {
                    image = try EmbeddingInput.image(at: URL(fileURLWithPath: path))
                } else {
                    throw EmbeddingError.failed("embedImage needs a path or imageData")
                }
                let vector = try backend.embed(image: image, budget: request.budget ?? .photo)
                response.vectors = [EmbeddingVector.float16Data(vector)]
            case .embedAudio:
                guard let path = request.path else { throw EmbeddingError.failed("embedAudio needs a path") }
                guard !backend.isTextOnly else { throw EmbeddingError.textOnly }
                let samples = try EmbeddingInput.audio(
                    at: URL(fileURLWithPath: path),
                    from: request.start ?? 0,
                    duration: min(request.duration ?? EmbeddingInput.audioWindow, EmbeddingInput.audioWindow),
                    sampleRate: backend.audioSampleRate
                )
                guard !EmbeddingInput.isSilent(samples) else { throw EmbeddingError.silent }
                response.vectors = [EmbeddingVector.float16Data(try backend.embed(audio: samples))]
            case .hold:
                setHeld(request.on ?? true)
            case .shutdown:
                write(EmbeddingServiceLine.encode(response))
                end(0)
                return
            }
        } catch {
            response.vectors = nil
            response.error = "\(error)"
        }
        write(EmbeddingServiceLine.encode(response))
    }

    private func setHeld(_ on: Bool) {
        held = on
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "The Panel is open and a Query may need a vector"
            )
        } else if !on, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func armIdleExit() {
        guard !finished, !held else { return }
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + idleExit)
        timer.setEventHandler { [weak self] in self?.end(0) }
        timer.resume()
        idleTimer = timer
    }

    private func end(_ status: Int32) {
        guard !finished else { return }
        finished = true
        idleTimer?.cancel()
        idleTimer = nil
        setHeld(false)
        backend.close()
        finish(status)
    }
}
