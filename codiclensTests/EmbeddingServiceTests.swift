import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
@testable import codiclens

/// The helper's JSON-lines protocol and its request loop, over a fake backend
/// and in this process.
struct EmbeddingServiceTests {

    // MARK: - Protocol

    @Test func requestsRoundTripAsOneLineEach() throws {
        let requests = [
            EmbeddingRequest(id: 1, kind: .embedText, texts: ["task: search result | query: a\nb"]),
            EmbeddingRequest(id: 2, kind: .embedImage, path: "/tmp/x.heic", budget: .screenshot),
            EmbeddingRequest(id: 3, kind: .embedImage, imageData: Data([1, 2, 3]), budget: .photo),
            EmbeddingRequest(id: 4, kind: .embedAudio, path: "/tmp/x.m4a", start: 25, duration: 30),
            EmbeddingRequest(id: 5, kind: .hold, on: true),
            EmbeddingRequest(id: 6, kind: .shutdown),
        ]
        for request in requests {
            let line = EmbeddingServiceLine.encode(request)
            #expect(line.last == 0x0A)
            #expect(line.dropLast().firstIndex(of: 0x0A) == nil)
            #expect(try EmbeddingServiceLine.decode(EmbeddingRequest.self, from: line.dropLast()) == request)
        }
    }

    @Test func theWireFormatIsWhatTheDocCommentSays() throws {
        let line = EmbeddingServiceLine.encode(EmbeddingRequest(id: 2, kind: .embedImage, path: "/x", budget: .photo))
        let object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["id"] as? Int == 2)
        #expect(object["kind"] as? String == "embedImage")
        #expect(object["budget"] as? Int == 140)
        #expect(object["texts"] == nil)
    }

    @Test func responsesCarryFloat16VectorsAsBase64() throws {
        let vector = EmbeddingVector.normalized([1, 2, 3, 4])
        let response = EmbeddingResponse(id: 9, vectors: [EmbeddingVector.float16Data(vector)])
        let line = EmbeddingServiceLine.encode(response)
        let object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        let base64 = try #require((object["vectors"] as? [String])?.first)
        #expect(Data(base64Encoded: base64)?.count == 8)

        let decoded = try EmbeddingServiceLine.decode(EmbeddingResponse.self, from: line)
        let floats = try #require(decoded.floatVectors?.first)
        #expect(EmbeddingVector.cosine(floats, vector) > 0.9999)
    }

    @Test func aResponseWithAMalformedVectorHasNone() {
        #expect(EmbeddingResponse(id: 1, vectors: [Data([0, 0]), Data([1])]).floatVectors == nil)
        #expect(EmbeddingResponse(id: 1, error: "no").floatVectors == nil)
    }

    @Test func linesAreSplitOnlyWhenComplete() {
        var buffer = Data("{\"a\":1}\n\n{\"b\":2}\n{\"c\"".utf8)
        let lines = EmbeddingServiceLine.takeLines(from: &buffer)
        #expect(lines == [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)])
        #expect(buffer == Data("{\"c\"".utf8))
    }

    // MARK: - Arguments

    @Test func optionsRoundTripThroughTheCommandLine() {
        var options = EmbeddingService.Options()
        options.models = URL(fileURLWithPath: "/tmp/models dir")
        options.textOnly = true
        options.idleExit = 12.5
        let arguments = ["/Applications/codiclens.app/Contents/MacOS/codiclens"] + options.arguments
        #expect(EmbeddingService.isRequested(arguments))
        #expect(EmbeddingService.Options(arguments: arguments) == options)
        #expect(!EmbeddingService.isRequested(["codiclens", "-NSDocumentRevisionsDebugMode", "YES"]))
    }

    /// The helper must not inherit XCTest's injection, or it would run the
    /// tests again inside itself.
    @Test func theHelperInheritsNoTestInjection() {
        let environment = HelperProcessLauncher.environment(from: [
            "HOME": "/Users/x", "PATH": "/usr/bin", "TMPDIR": "/tmp/",
            "DYLD_INSERT_LIBRARIES": "/x/libXCTestBundleInject.dylib",
            "XCTestConfigurationFilePath": "/x.xctestconfiguration",
            "XCInjectBundleInto": "/x",
        ])
        #expect(environment == ["HOME": "/Users/x", "PATH": "/usr/bin", "TMPDIR": "/tmp/"])
    }

    // MARK: - The request loop

    @Test func textComesBackAsOneVectorPerInputInOrder() async throws {
        let harness = LoopHarness()
        let responses = try await harness.send([
            EmbeddingRequest(id: 1, kind: .embedText, texts: ["alpha", "beta"]),
            EmbeddingRequest(id: 2, kind: .embedText, texts: ["gamma"]),
        ])
        #expect(responses.map(\.id) == [1, 2])
        #expect(responses[0].floatVectors == [FakeEmbeddingBackend.vector(for: "alpha"), FakeEmbeddingBackend.vector(for: "beta")])
        #expect(responses[1].floatVectors == [FakeEmbeddingBackend.vector(for: "gamma")])
    }

    @Test func aFailedInputIsAnsweredWithWhyAndTheLoopGoesOn() async throws {
        let harness = LoopHarness(backend: FakeEmbeddingBackend(onText: { text in
            if text == "bad" { throw EmbeddingError.unreadable("bad") }
        }))
        let responses = try await harness.send([
            EmbeddingRequest(id: 1, kind: .embedText, texts: ["bad"]),
            EmbeddingRequest(id: 2, kind: .embedImage, path: "/nonexistent/picture.png", budget: .photo),
            EmbeddingRequest(id: 3, kind: .embedAudio, path: "/nonexistent/clip.m4a"),
            EmbeddingRequest(id: 4, kind: .embedText, texts: ["good"]),
        ])
        #expect(responses[0].error == "can't read bad")
        #expect(responses[0].vectors == nil)
        #expect(responses[1].error == "can't read /nonexistent/picture.png")
        #expect(responses[2].error == "this embedder was started text-only")
        #expect(responses[3].floatVectors == [FakeEmbeddingBackend.vector(for: "good")])
    }

    @Test func anImageIsDecodedAndHandedOverAtItsBudget() async throws {
        let harness = LoopHarness(backend: FakeEmbeddingBackend(textOnly: false))
        let png = try Self.png(width: 64, height: 32)
        let responses = try await harness.send([
            EmbeddingRequest(id: 1, kind: .embedImage, imageData: png, budget: .screenshot),
        ])
        #expect(responses[0].floatVectors == [FakeEmbeddingBackend.vector(for: "image 64×32 at 280")])
    }

    @Test func shutdownIsAnsweredThenTheLoopFinishesAndClosesTheModel() async throws {
        let backend = FakeEmbeddingBackend()
        let harness = LoopHarness(backend: backend)
        let responses = try await harness.send([EmbeddingRequest(id: 7, kind: .shutdown)])
        #expect(responses.map(\.id) == [7])
        #expect(await harness.finished() == 0)
        #expect(backend.closed.withLock { $0 })
    }

    @Test func theAppGoingAwayFinishesTheLoop() async {
        let harness = LoopHarness()
        harness.loop.inputEnded()
        #expect(await harness.finished() == 0)
    }

    /// The idle exit fires on its own: nothing is sent, and the loop
    /// finishes.
    @Test func anIdleHelperExits() async {
        let harness = LoopHarness(idleExit: 0.05)
        harness.loop.start()
        #expect(await harness.finished() == 0)
    }

    /// Held, the helper outlives its idle timeout; released, the deadline is
    /// armed again.
    @Test func aHeldHelperDoesNotExitUntilReleased() async throws {
        let harness = LoopHarness(idleExit: 0.05)
        harness.loop.start()
        _ = try await harness.send([EmbeddingRequest(id: 1, kind: .hold, on: true)])
        // Well past the timeout, the loop still answers.
        try await Task.sleep(for: .milliseconds(300))
        let responses = try await harness.send([EmbeddingRequest(id: 2, kind: .embedText, texts: ["still here"])])
        #expect(responses[0].floatVectors?.count == 1)
        #expect(harness.finishedStatus == nil)
        _ = try await harness.send([EmbeddingRequest(id: 3, kind: .hold, on: false)])
        #expect(await harness.finished() == 0)
    }

    private static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

/// One `EmbeddingServiceLoop` with its output collected: send requests, await
/// their answers, await its finish.
private final class LoopHarness: @unchecked Sendable {
    let loop: EmbeddingServiceLoop
    private let output: AsyncStream<Data>
    private let finish: AsyncStream<Int32>
    private let status = FinishStatus()
    private var lines: AsyncStream<Data>.Iterator

    init(backend: FakeEmbeddingBackend = FakeEmbeddingBackend(), idleExit: TimeInterval = 600) {
        let (output, outputContinuation) = AsyncStream.makeStream(of: Data.self)
        let (finish, finishContinuation) = AsyncStream.makeStream(of: Int32.self)
        self.output = output
        self.finish = finish
        lines = output.makeAsyncIterator()
        let status = status
        loop = EmbeddingServiceLoop(
            backend: backend, idleExit: idleExit,
            write: { data in
                var data = data
                for line in EmbeddingServiceLine.takeLines(from: &data) { outputContinuation.yield(line) }
            },
            finish: { code in
                status.code.withLock { $0 = code }
                finishContinuation.yield(code)
                finishContinuation.finish()
            }
        )
    }

    var finishedStatus: Int32? { status.code.withLock { $0 } }

    /// Sends each request and returns the answers, one per request.
    func send(_ requests: [EmbeddingRequest]) async throws -> [EmbeddingResponse] {
        for request in requests {
            loop.receive(EmbeddingServiceLine.encode(request).dropLast())
        }
        var responses: [EmbeddingResponse] = []
        for _ in requests {
            let line = try #require(await lines.next())
            responses.append(try EmbeddingServiceLine.decode(EmbeddingResponse.self, from: line))
        }
        return responses
    }

    func finished() async -> Int32? {
        var iterator = finish.makeAsyncIterator()
        return await iterator.next()
    }
}

private final class FinishStatus: Sendable {
    let code = Mutex<Int32?>(nil)
}
