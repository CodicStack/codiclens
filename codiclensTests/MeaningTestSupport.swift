import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// An embedder with no model whose vectors a test can reason about: a few
/// concept words each own a dimension, and a text's vector is the concepts it
/// mentions. A picture or a recording means what its file name says; a
/// picture handed over as bytes (a PDF page, a video frame) means "picture".
/// Every vector also has a little of a shared dimension, so none is zero.
final class KeywordEmbedder: MeaningEmbedder, QueryEncoder, EmbeddingShutdown, @unchecked Sendable {
    /// Each concept is its dimension; the words after the first mean it too.
    static let concepts: [[String]] = [
        ["kontrakt", "contract"], ["smoothie"], ["zebra"], ["budget"], ["picture"], ["sound"], ["invoice"],
        ["beach", "seaside", "strand"], ["music"], ["lease"], ["recipe", "opskrift"], ["meeting", "standup"],
    ]
    static let shared = 700

    /// Every request, in order: "text …", "image <name>", "data", "audio <name> <start>".
    let requests = Mutex<[String]>([])
    /// How many texts each `embed(texts:)` was asked for, in order.
    let textCalls = Mutex<[Int]>([])
    /// Every `setFullSpeed`, in order.
    let fullSpeeds = Mutex<[Bool]>([])
    let holds = Mutex(0)
    let shutdowns = Mutex(0)

    static func vector(for text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: EmbeddingVector.dimension)
        vector[shared] = 0.2
        let lowered = text.lowercased()
        for (index, words) in concepts.enumerated() where words.contains(where: lowered.contains) { vector[index] = 1 }
        return EmbeddingVector.normalized(vector)
    }

    /// Text with this in it brings the helper down, as a file that trips
    /// the model would.
    static let crash = "crashme"

    func embed(texts: [String]) async throws -> [[Float]] {
        requests.withLock { $0 += texts.map { "text " + $0 } }
        textCalls.withLock { $0.append(texts.count) }
        if texts.contains(where: { $0.contains(Self.crash) }) { throw EmbeddingClientError.crashed }
        return texts.map(Self.vector(for:))
    }

    func embedImage(at url: URL, budget: ImageBudget) async throws -> [Float] {
        requests.withLock { $0.append("image \(url.lastPathComponent) \(budget.tokens)") }
        return Self.vector(for: url.lastPathComponent)
    }

    func embedImage(data: Data, budget: ImageBudget) async throws -> [Float] {
        requests.withLock { $0.append("data \(budget.tokens)") }
        return Self.vector(for: "picture")
    }

    func embedAudio(at url: URL, from start: TimeInterval, duration: TimeInterval) async throws -> [Float] {
        requests.withLock { $0.append("audio \(url.lastPathComponent) \(Int(start))+\(Int(duration))") }
        return Self.vector(for: url.lastPathComponent + " sound")
    }

    func setFullSpeed(_ isFullSpeed: Bool) async {
        fullSpeeds.withLock { $0.append(isFullSpeed) }
    }

    func embedQuery(_ text: String, code: Bool) async throws -> [Float] {
        Self.vector(for: text)
    }

    func hold() async throws { holds.withLock { $0 += 1 } }
    func release() async {}
    func shutdown() async { shutdowns.withLock { $0 += 1 } }
}

extension MeaningPace.Machine {
    /// On power with someone at the Mac: the gentle pace, whatever this Mac
    /// is doing.
    static let atDesk = MeaningPace.Machine(isOnPower: { true }, idleSeconds: { 0 })
}

/// The day as the vector cache sees it (`VectorCache.day(of:)`), moved on by
/// a test.
final class TestDay: Sendable {
    private let value: Mutex<Int64>

    init(_ day: Int64 = VectorCache.day(of: Date())) {
        value = Mutex(day)
    }

    var now: Int64 { value.withLock { $0 } }

    func advance(by days: Int64) {
        value.withLock { $0 += days }
    }

    var clock: @Sendable () -> Int64 {
        { [self] in now }
    }
}

/// The File Index's writing half and a reader on a real folder and database
/// in a temporary folder, with both passes stepped by hand: a crawl, the
/// contents pass, the meaning pass, and the settled search. The vector cache
/// is beside the database, as in the app, and outlives `close()`. Its day is
/// `day`, and its pace is decided from `machine`.
final class MeaningFixture {
    let folder: TemporaryFolder
    let url: URL
    let embedder: KeywordEmbedder
    let machine: MeaningPace.Machine
    let day = TestDay()
    var cache: VectorCache!
    var writer: FileIndexWriter!
    var reader: FileIndexReader!
    var indexer: FileIndexer!
    var contents: FileContentScheduler!
    var vectors: MeaningVectors!
    var meaning: MeaningScheduler!

    init(embedder: KeywordEmbedder = KeywordEmbedder(), machine: MeaningPace.Machine = .atDesk) throws {
        self.embedder = embedder
        self.machine = machine
        folder = try TemporaryFolder()
        try folder.makeFolder("Source")
        url = folder.url.appendingPathComponent("FileIndex.sqlite")
        try open()
    }

    var cacheURL: URL { VectorCache.url(besideDatabase: url) }

    /// As a launch makes them, with the meaning pass enabled.
    func open() throws {
        cache = try VectorCache(url: cacheURL, today: day.clock)
        writer = try FileIndexWriter(url: url, cache: cache)
        reader = FileIndexReader(url: url)
        indexer = FileIndexer(writer: writer)
        contents = FileContentScheduler(writer: writer, queue: DispatchQueue(label: "test.contents"))
        contents.setSources([root])
        vectors = MeaningVectors(databaseURL: url)
        meaning = MeaningScheduler(writer: writer, vectors: vectors, cache: cache, queue: DispatchQueue(label: "test.meaning"),
                                   embed: MeaningScheduler.embedAll(with: embedder, cache: cache), machine: machine)
        meaning.setSources([root])
        writer.onVectorsRemoved = { [vectors] files in vectors?.remove(files: files) }
        try meaning.enable()
    }

    func close() {
        (writer, reader, indexer, contents, vectors, meaning, cache) = (nil, nil, nil, nil, nil, nil, nil)
    }

    deinit {
        close()
        folder.remove()
    }

    var root: String { folder.path("Source") }
    func path(_ relative: String) -> String { root + "/" + relative }

    func make(_ relative: String, contents: String) throws {
        try folder.makeFile("Source/" + relative, contents: contents)
    }

    func setDate(_ relative: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(relative))
    }

    func crawl() throws {
        for root in try indexer.setSources([(path: root, isEnabled: true)]) { try indexer.crawl(root) }
    }

    @discardableResult
    func events(_ relatives: [String]) throws -> [Int64] {
        try indexer.handle(relatives.map { FileIndexWatcher.Event(path: path($0)) })
    }

    func readContents() async throws {
        while true {
            let jobs = try contents.nextBatch()
            guard !jobs.isEmpty else { return }
            try contents.store(await FileContentScheduler.readAll(jobs))
        }
    }

    /// Steps the meaning pass until it has nothing to do now; returns the
    /// batches it embedded, by file name.
    @discardableResult
    func embedAll() async throws -> [[String]] {
        var batches: [[String]] = []
        while true {
            let jobs = try meaning.nextBatch()
            guard !jobs.isEmpty else { return batches }
            batches.append(jobs.map { ($0.path as NSString).lastPathComponent })
            try meaning.store(await MeaningScheduler.embedAll(with: embedder, cache: cache)(jobs, meaning.pace))
        }
    }

    /// Crawl, contents, vectors.
    func index() async throws {
        try crawl()
        try await readContents()
        try await embedAll()
    }

    /// The settled search, as `FileIndex.searchSettled` runs it.
    func search(_ query: String) -> [FileHit] {
        let scores = vectors.snapshot().map { MeaningScores($0, query: KeywordEmbedder.vector(for: query)) } ?? .none
        return reader.fusedSearch(query, limit: 50, sources: [root], meaning: scores)
    }

    func count(_ sql: String) throws -> Int {
        var count = 0
        try writer.db.query(sql) { count = Int($0.int(0)) }
        return count
    }

    /// Notes that mean nothing in particular, so a Query's scale has
    /// something to stand out from: with three vectors, nothing can be two
    /// deviations above the rest.
    func makeFillers(_ count: Int = 24) throws {
        for index in 0..<count { try make("Misc/n\(index).md", contents: "ordinary text number \(index)") }
    }

    func id(_ relative: String) throws -> Int64 {
        try #require(writer.row(atPath: path(relative))?.id)
    }
}

/// Media files made on the spot, so no test depends on what is on this Mac.
enum TestMedia {
    /// A PNG or JPEG of `width` × `height` in one colour with a square of
    /// another, so two of them differ.
    static func picture(at path: String, width: Int = 320, height: Int = 320, hue: CGFloat = 0.3) throws {
        let image = try #require(drawing(width: width, height: height, hue: hue))
        let type: UTType = path.hasSuffix(".jpg") ? .jpeg : .png
        let destination = try #require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                                        type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// A dark picture with a light square in one of four places, by `hue`:
    /// pictures of different hues are different shots to an average hash.
    static func drawing(width: Int, height: Int, hue: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: hue * 0.3, green: 0.1, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0.9, blue: hue, alpha: 1))
        let quadrant = Int((hue * 5).rounded()) % 4
        context.fill(CGRect(x: quadrant % 2 * width / 2, y: quadrant / 2 * height / 2, width: width / 2, height: height / 2))
        return context.makeImage()
    }

    /// A 16-bit mono WAV of `seconds`: a tone, or silence.
    static func wav(at path: String, seconds: Double, silent: Bool = false, rate: Int = 16_000) throws {
        let count = Int(seconds * Double(rate))
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append32(UInt32(36 + count * 2)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append32(16); append16(1); append16(1)
        append32(UInt32(rate)); append32(UInt32(rate * 2)); append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append32(UInt32(count * 2))
        for index in 0..<count {
            let sample = silent ? 0 : Int16(sin(Double(index) * 2 * .pi * 440 / Double(rate)) * 8000)
            append16(UInt16(bitPattern: sample))
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// A QuickTime movie (an MPEG-4 one for `.mp4`) of `seconds` at 2 frames a second, its picture
    /// changing colour every `shot` seconds, with the sound of `audio` (any
    /// file AVFoundation reads) as its soundtrack, or none.
    static func movie(at path: String, seconds: Double, shot: Double = 6, audio: URL? = nil) async throws {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mp4" ? .mp4 : .mov)
        let size = 320
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size, kCVPixelBufferHeightKey as String: size,
        ])
        writer.add(video)
        var sound: (input: AVAssetWriterInput, reader: AVAssetReader, output: AVAssetReaderTrackOutput)?
        if let audio {
            let asset = AVURLAsset(url: audio)
            let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ])
            writer.add(input)
            sound = (input, reader, output)
        }
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        // Both inputs fed as the writer asks: it interleaves them, and one
        // fed to the end first would wait for the other for ever.
        let frames = Int(seconds * 2)
        let next = Mutex(0)
        let pool = adaptor.pixelBufferPool
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            video.requestMediaDataWhenReady(on: DispatchQueue(label: "test.movie.video")) {
                while video.isReadyForMoreMediaData {
                    let frame = next.withLock { frame in defer { frame += 1 }; return frame }
                    guard frame < frames else {
                        video.markAsFinished()
                        group.leave()
                        return
                    }
                    let hue = CGFloat(Int(Double(frame) / 2 / shot) % 5) / 5
                    if let buffer = pixelBuffer(size: size, hue: hue, pool: pool) {
                        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 2))
                    }
                }
            }
            if let sound {
                #expect(sound.reader.startReading())
                group.enter()
                sound.input.requestMediaDataWhenReady(on: DispatchQueue(label: "test.movie.audio")) {
                    while sound.input.isReadyForMoreMediaData {
                        guard let sample = sound.output.copyNextSampleBuffer() else {
                            sound.input.markAsFinished()
                            group.leave()
                            return
                        }
                        sound.input.append(sample)
                    }
                }
            }
            group.notify(queue: .global()) { done.resume() }
        }
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
    }

    private static func pixelBuffer(size: Int, hue: CGFloat, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        guard let buffer, let image = drawing(width: size, height: size, hue: hue) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return buffer
    }
}
