// Audio windows, video keyframes with their average hash, and the PDF page rendering follow DigUp's
// MediaExtractors.swift and Indexer.swift (https://github.com/ARahim3/DigUp), MIT licence — see docs/licenses/digup/LICENSE.
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// What the meaning pass asks for vectors. `EmbeddingClient` in the app; the
/// same client over an in-process fake helper in tests.
nonisolated protocol MeaningEmbedder: Sendable {
    /// Already prompted (`EmbeddingPrompt`), one vector each.
    func embed(texts: [String]) async throws -> [[Float]]
    func embedImage(at url: URL, budget: ImageBudget) async throws -> [Float]
    func embedImage(data: Data, budget: ImageBudget) async throws -> [Float]
    func embedAudio(at url: URL, from start: TimeInterval, duration: TimeInterval) async throws -> [Float]
    /// Whether what is asked from now on is the backfill at full speed
    /// (`MeaningPace.full`).
    func setFullSpeed(_ isFullSpeed: Bool) async
}

nonisolated extension EmbeddingClient: MeaningEmbedder {}

/// Embeds one step of a file: a `MeaningJob` in, a `MeaningResult` out, and
/// no database. The file is read here, in the app — pages rendered, frames
/// picked, windows of sound timed — and only the vectors come from the
/// helper, and only those `VectorCache` does not already have: every input
/// is keyed first (`VectorCache.Key`), and what the helper answers is kept
/// there once the step is done.
///
/// - **Text** (the contents pass's Passages): each with the card's document
///   prompt, the file's name as its title. Text that is mostly digits gets
///   no vector, keyword search finds it.
/// - **A screenshot** is embedded as a picture at 280 soft tokens; its OCR
///   text stays keyword-only, as DigUp found a vector of the words made
///   screenshots outrank better matches. **A photo** at 140, if it is at
///   least `minimumImageSide` on its shorter side.
/// - **A PDF page with too little text to be a Passage** (a scan, a slide) is
///   rendered and embedded as a picture at 280.
/// - **A recording** is 30 s windows every 25 s; silent ones get nothing.
///   **A video** is a frame every 3 s at 70 tokens, near-duplicates folded
///   into the frame before, and its soundtrack the same way as a recording.
///   Each carries its span in seconds.
///
/// A file that cannot be read gets nothing and a `detail`; an input the
/// helper refuses (`EmbeddingClientError.failed`) is skipped. A crash of the
/// helper on a file gives that file up rather than crash it again; a helper
/// that cannot start at all throws, and the pass stops.
nonisolated enum MeaningReader {
    /// A batch's jobs, in order. Their texts go to the helper together first
    /// and into the cache, where each job then finds them: most files have a
    /// chunk or three (on the dev machine 5,659 of the 11,723 waiting had
    /// one), and a request a file left each model call a third full: texts of
    /// 700 characters went 22–26 a second asked one at a time, 38–51 four to
    /// 64 at a time (`MeaningThroughputTests`).
    /// If the helper crashes on them together, each file asks again alone,
    /// so only the one at fault gives up.
    static func read(
        _ jobs: [MeaningJob], with embedder: some MeaningEmbedder, cache: VectorCache
    ) async throws -> [MeaningResult] {
        let prompts = jobs.flatMap(Self.prompts)
        if jobs.count > 1, !prompts.isEmpty {
            let together = JobVectors(path: "", embedder: embedder, cache: cache)
            do {
                _ = try await together.texts(prompts.map(\.prompt))
            } catch EmbeddingClientError.crashed {}
            try together.keep()
        }
        var results: [MeaningResult] = []
        for job in jobs { results.append(try await read(job, with: embedder, cache: cache)) }
        return results
    }

    static func read(
        _ job: MeaningJob, with embedder: some MeaningEmbedder, cache: VectorCache
    ) async throws -> MeaningResult {
        let vectors = JobVectors(path: job.path, embedder: embedder, cache: cache)
        let result: MeaningResult
        do {
            result = try await readFile(job, with: vectors)
        } catch EmbeddingClientError.crashed {
            result = MeaningResult(job: job, vecTo: job.vecTo, isComplete: true, givesUp: true,
                                   detail: "stopped the embedding helper")
        }
        // What the helper answered before a crash is as good as any.
        try vectors.keep()
        return result
    }

    private static func readFile(_ job: MeaningJob, with vectors: JobVectors) async throws -> MeaningResult {
        let url = URL(fileURLWithPath: job.path)
        switch job.content {
        case .document, .text, .code:
            var result = MeaningResult(job: job, vecTo: job.texts.last.map { Double($0.segment) } ?? job.vecTo)
            result.vectors = try await texts(job, with: vectors)
            return result
        case .pdf:
            var result = MeaningResult(job: job, vecTo: Double(job.pages.upperBound))
            result.vectors = try await texts(job, with: vectors)
            result.vectors += try await pageImages(job, url: url, with: vectors)
            return result
        case .screenshot, .image:
            var result = MeaningResult(job: job, vecTo: 0)
            if job.content == .image, let side = shorterSide(of: url), side < MeaningPass.minimumImageSide {
                result.detail = "too small to embed"
                return result
            }
            let budget = job.content == .screenshot ? ImageBudget.screenshot : .photo
            if let file = vectors.file {
                let key = VectorCache.Key.picture(file, budget: budget)
                if let vector = try await vectors.media(key, embed: { try await $0.embedImage(at: url, budget: budget) }) {
                    result.vectors = [MeaningResult.Vector(kind: .image, key: key, vector: vector)]
                    return result
                }
            }
            result.detail = "unreadable picture"
            return result
        case .audio:
            return try await recording(job, url: url, with: vectors)
        case .video:
            return try await video(job, url: url, with: vectors)
        }
    }

    /// A text's title in its prompt: the file's name without its extension.
    static func title(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // MARK: - Text

    private static func texts(_ job: MeaningJob, with vectors: JobVectors) async throws -> [MeaningResult.Vector] {
        let prompts = prompts(job)
        guard !prompts.isEmpty else { return [] }
        return zip(prompts, try await vectors.texts(prompts.map(\.prompt))).compactMap { item, answer in
            answer.map {
                MeaningResult.Vector(segment: item.text.segment, kind: item.text.kind, location: item.text.location,
                                     key: $0.key, vector: $0.vector)
            }
        }
    }

    /// The job's texts that get a vector, each with the card's document
    /// prompt.
    private static func prompts(_ job: MeaningJob) -> [(text: MeaningJob.Text, prompt: String)] {
        let title = title(of: job.path)
        return job.texts.filter { hasWords($0.text) }.map {
            ($0, EmbeddingPrompt.document(title: title, text: String($0.text.prefix(MeaningPass.maxTextCharacters))))
        }
    }

    /// Text that is mostly digits and symbols — a table of numbers, a data
    /// listing — gets keyword search only.
    static func hasWords(_ text: String) -> Bool {
        var letters = 0, digits = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) { letters += 1 } else if CharacterSet.decimalDigits.contains(scalar) { digits += 1 }
        }
        return letters >= 3 && letters > digits
    }

    // MARK: - Pictures

    private static func shorterSide(of url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return min(width, height)
    }

    /// The pages of this step that had too little text for a Passage, each
    /// drawn and embedded as a picture. The PDF is opened only for a page the
    /// cache does not have.
    private static func pageImages(
        _ job: MeaningJob, url: URL, with vectors: JobVectors
    ) async throws -> [MeaningResult.Vector] {
        let sparse = job.pages.filter { !job.pagesWithText.contains($0 + 1) }
        guard !sparse.isEmpty, let file = vectors.file else { return [] }
        let keys = sparse.map { VectorCache.Key.page(file, number: $0 + 1) }
        let document = try vectors.hasAll(keys) ? nil : PDFDocument(url: url).flatMap { $0.isLocked ? nil : $0 }
        var found: [MeaningResult.Vector] = []
        for (index, key) in zip(sparse, keys) {
            guard let vector = try await vectors.media(key, embed: { embedder in
                guard let png = autoreleasepool(invoking: { document?.page(at: index).flatMap(pagePicture) }) else {
                    return nil
                }
                return try await embedder.embedImage(data: png, budget: .pdfPage)
            }) else { continue }
            found.append(MeaningResult.Vector(kind: .pageImage, location: Double(index + 1), key: key, vector: vector))
        }
        return found
    }

    /// The longest side of a rendered page, as DigUp renders them.
    static let pagePixels: CGFloat = 1400
    /// The longest side of a video frame, and how it is compressed for the
    /// helper.
    static let frameSide = 768
    static let jpegQuality = 0.85

    /// `page` drawn on white at `pagePixels` on its longer side, as PNG.
    static func pagePicture(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = pagePixels / max(bounds.width, bounds.height)
        let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage().flatMap { encoded($0, as: .png) }
    }

    static func encoded(_ image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: - Recordings and videos

    /// The stretch of seconds this step covers, from `vecTo`.
    static func step(_ job: MeaningJob, duration: Double) -> Range<Double> {
        let length = job.isFirstStep ? MeaningPass.firstSeconds : MeaningPass.laterSeconds
        return job.vecTo..<min(job.vecTo + length, duration)
    }

    /// Where the windows of sound start in `step`: every `audioHop` seconds,
    /// each `audioWindow` long or to the end. The last is left out when it
    /// adds less than `audioMinimum` past the one before; the first, when the
    /// whole recording is shorter than that.
    static func windowStarts(in step: Range<Double>, duration: Double) -> [Double] {
        var starts: [Double] = []
        var start = (step.lowerBound / MeaningPass.audioHop).rounded(.up) * MeaningPass.audioHop
        while start < step.upperBound {
            let isWorthIt = start == 0
                ? duration >= MeaningPass.audioMinimum
                : duration - start >= MeaningPass.audioWindow - MeaningPass.audioHop + MeaningPass.audioMinimum
            if isWorthIt { starts.append(start) }
            start += MeaningPass.audioHop
        }
        return starts
    }

    private static func sound(
        _ url: URL, step: Range<Double>, duration: Double, with vectors: JobVectors
    ) async throws -> [MeaningResult.Vector] {
        let starts = windowStarts(in: step, duration: duration)
        guard !starts.isEmpty, let file = vectors.file else { return [] }
        var found: [MeaningResult.Vector] = []
        for start in starts {
            let length = min(MeaningPass.audioWindow, duration - start)
            let key = VectorCache.Key.sound(file, from: start, to: start + length)
            guard let vector = try await vectors.media(key, embed: {
                try await $0.embedAudio(at: url, from: start, duration: length)
            }) else { continue }
            found.append(MeaningResult.Vector(kind: .audio, location: start, end: start + length, key: key, vector: vector))
        }
        return found
    }

    private static func recording(_ job: MeaningJob, url: URL, with vectors: JobVectors) async throws -> MeaningResult {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else {
            return MeaningResult(job: job, vecTo: job.vecTo, detail: "unreadable recording")
        }
        let step = step(job, duration: duration)
        var result = MeaningResult(job: job, vecTo: step.upperBound, isComplete: step.upperBound >= duration)
        result.vectors = try await sound(url, step: step, duration: duration, with: vectors)
        if result.isComplete, result.vectors.isEmpty, job.isFirstStep { result.detail = "silent or too short" }
        return result
    }

    private static func video(_ job: MeaningJob, url: URL, with vectors: JobVectors) async throws -> MeaningResult {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0,
              let visual = try? await asset.loadTracks(withMediaType: .video)
        else {
            return MeaningResult(job: job, vecTo: job.vecTo, detail: "unreadable video")
        }
        let hasSound = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
        let step = step(job, duration: duration)
        var result = MeaningResult(job: job, vecTo: step.upperBound, isComplete: step.upperBound >= duration)
        if !visual.isEmpty {
            result.vectors += try await frames(asset, step: step, duration: duration, with: vectors)
        }
        if hasSound {
            result.vectors += try await sound(url, step: step, duration: duration, with: vectors)
        }
        return result
    }

    /// When the frames of `step` are taken: every `frameInterval` seconds,
    /// or further apart in a video long enough to pass `maxFrames`, from half
    /// a second in.
    static func frameTimes(in step: Range<Double>, duration: Double) -> [Double] {
        let interval = max(MeaningPass.frameInterval, duration / Double(MeaningPass.maxFrames))
        let first = min(0.5, duration / 2)
        var index = max(0, ((step.lowerBound - first) / interval).rounded(.up))
        var times: [Double] = []
        while first + index * interval < step.upperBound {
            times.append(first + index * interval)
            index += 1
        }
        return times
    }

    /// The frames of `step`, one per shot: a frame that looks like the one
    /// kept before it (an 8×8 average hash within 4 bits) only stretches that
    /// one. Each kept frame stands for the time until the next.
    private static func frames(
        _ asset: AVURLAsset, step: Range<Double>, duration: Double, with vectors: JobVectors
    ) async throws -> [MeaningResult.Vector] {
        let times = frameTimes(in: step, duration: duration)
        guard !times.isEmpty, let file = vectors.file else { return [] }
        let interval = max(MeaningPass.frameInterval, duration / Double(MeaningPass.maxFrames))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: frameSide, height: frameSide)
        let tolerance = CMTime(seconds: interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var kept: [(start: Double, jpeg: Data)] = []
        var lastHash: UInt64?
        for await result in generator.images(for: times.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
            guard case .success(_, let image, let actual) = result else { continue }
            let hash = averageHash(image)
            if let lastHash, (hash ^ lastHash).nonzeroBitCount <= 4 { continue }
            lastHash = hash
            guard let jpeg = encoded(image, as: .jpeg) else { continue }
            kept.append((max(step.lowerBound, actual.seconds), jpeg))
        }
        var found: [MeaningResult.Vector] = []
        for (index, frame) in kept.enumerated() {
            let end = index + 1 < kept.count ? kept[index + 1].start : step.upperBound
            let key = VectorCache.Key.frame(file, at: frame.start)
            guard let vector = try await vectors.media(key, embed: {
                try await $0.embedImage(data: frame.jpeg, budget: .videoFrame)
            }) else { continue }
            found.append(MeaningResult.Vector(kind: .frame, location: frame.start, end: end, key: key, vector: vector))
        }
        return found
    }

    /// 64 bits, one per pixel of the picture shrunk to 8×8 grey: whether it
    /// is brighter than the average.
    static func averageHash(_ image: CGImage) -> UInt64 {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return 0 }
        let mean = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        var hash: UInt64 = 0
        for (index, pixel) in pixels.enumerated() where Int(pixel) > mean { hash |= 1 << UInt64(index) }
        return hash
    }
}

/// One step's way to its vectors: `VectorCache` first, the helper only for
/// what the cache lacks, and the helper's answers kept in the cache when the
/// step is done (`keep`). An input that appears twice in a step is asked for
/// once.
nonisolated final class JobVectors {
    private let path: String
    private let embedder: any MeaningEmbedder
    private let cache: VectorCache
    private var digest: FileDigest??
    private var fromPrompts: [VectorCache.Key: Data] = [:]
    private var fromFile: [VectorCache.Key: Data] = [:]

    init(path: String, embedder: any MeaningEmbedder, cache: VectorCache) {
        self.path = path
        self.embedder = embedder
        self.cache = cache
    }

    /// The file's SHA-256, taken the first time a picture, a page, a frame or
    /// a window asks for it; nil when it cannot be read.
    var file: FileDigest? {
        if let digest { return digest }
        let digest = FileDigest(path: path)
        self.digest = .some(digest)
        return digest
    }

    /// Whether the cache has every one of `keys`.
    func hasAll(_ keys: [VectorCache.Key]) throws -> Bool {
        let wanted = Set(keys).subtracting(fromFile.keys)
        return try cache.vectors(for: Array(wanted)).count == wanted.count
    }

    /// Texts, already prompted: each one's key and vector, or nil where the
    /// helper refused it.
    func texts(_ prompts: [String]) async throws -> [(key: VectorCache.Key, vector: Data)?] {
        let keys = prompts.map(VectorCache.Key.text)
        var found = try cache.vectors(for: keys)
        var seen = Set(found.keys)
        let missing = zip(keys, prompts).filter { seen.insert($0.0).inserted }
        // A request at a time of up to 64, so one answer line stays small.
        for start in stride(from: 0, to: missing.count, by: 64) {
            let batch = Array(missing[start..<min(start + 64, missing.count)])
            var answers: [[Float]]
            if let answered = try await skippingRefusal({ try await embedder.embed(texts: batch.map(\.1)) }) {
                answers = answered
            } else {
                // One of them was refused: ask for each on its own.
                answers = []
                for (_, prompt) in batch {
                    answers.append(try await skippingRefusal({ try await embedder.embed(texts: [prompt]) })?.first ?? [])
                }
            }
            for ((key, _), answer) in zip(batch, answers) where answer.count == EmbeddingVector.dimension {
                let vector = EmbeddingVector.float16Data(answer)
                fromPrompts[key] = vector
                found[key] = vector
            }
        }
        return keys.map { key in found[key].map { (key, $0) } }
    }

    /// One input read from the file: `key`'s vector from the cache, or else
    /// what `embed` gets from the helper. Nil when `embed` had nothing to
    /// send or the helper refused it.
    func media(
        _ key: VectorCache.Key, embed: (any MeaningEmbedder) async throws -> [Float]?
    ) async throws -> Data? {
        if let vector = try fromFile[key] ?? cache.vectors(for: [key])[key] { return vector }
        let embedder = self.embedder
        guard let answer = try await skippingRefusal({ try await embed(embedder) }) ?? nil,
              answer.count == EmbeddingVector.dimension
        else { return nil }
        let vector = EmbeddingVector.float16Data(answer)
        fromFile[key] = vector
        return vector
    }

    /// Puts what the helper answered into the cache. What came from the file
    /// only if the file still has the size and date it was hashed at: one that
    /// changed meanwhile may have been read by the helper as something else.
    func keep() throws {
        var entries = fromPrompts.map { (key: $0.key, vector: $0.value) }
        if !fromFile.isEmpty, let file = digest ?? nil, file.isCurrent(at: path) {
            entries += fromFile.map { (key: $0.key, vector: $0.value) }
        }
        try cache.store(entries)
    }

    /// `body`, or nil when the helper answered that it could not.
    private func skippingRefusal<T: Sendable>(_ body: () async throws -> T) async throws -> T? {
        do {
            return try await body()
        } catch EmbeddingClientError.failed {
            return nil
        }
    }
}

/// The query encoder as the File Index uses it: `EmbeddingClient` started
/// text-only.
nonisolated protocol QueryEncoder: Sendable {
    func embedQuery(_ text: String, code: Bool) async throws -> [Float]
    func hold() async throws
    func release() async
    func shutdown() async
}

/// A helper that can be told to go.
nonisolated protocol EmbeddingShutdown: Sendable {
    func shutdown() async
}

nonisolated extension EmbeddingClient: QueryEncoder, EmbeddingShutdown {}
