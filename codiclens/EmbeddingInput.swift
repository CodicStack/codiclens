import Accelerate
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Synchronization

/// Turning a file into what the embedder takes: an image into upright RGB
/// pixels, a stretch of a recording into mono samples at the audio encoder's
/// rate. Apple's decoders, so anything Quick Look can show (HEIC included)
/// and anything Core Audio can read is fair game.
nonisolated enum EmbeddingInput {
    /// The longest side an image is decoded at. The vision encoder never
    /// sees more than ~1,600px a side (1,120 soft tokens of 48px squares), so a
    /// 48-megapixel photo is decoded at this size rather than in full, and
    /// `ImageSizing` resizes it the rest of the way as the reference does.
    static let maxImageSide = 3072

    /// The model ignores audio past 30 seconds of one input, so a recording
    /// goes in as windows of at most this long.
    static let audioWindow: TimeInterval = 30

    static func image(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw EmbeddingError.unreadable(url.path)
        }
        return try image(from: source, named: url.path)
    }

    /// An encoded image (PNG, JPEG, HEIC, …) handed over as bytes.
    static func image(data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw EmbeddingError.unreadable("image data")
        }
        return try image(from: source, named: "image data")
    }

    /// The first frame, turned upright by its orientation tag, at most
    /// `maxImageSide` on its longest side.
    private static func image(from source: CGImageSource, named name: String) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImageSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw EmbeddingError.unreadable(name)
        }
        return image
    }

    /// Packed 8-bit RGB, what the vision encoder takes. Transparency is laid
    /// over white, the way a transparent picture is seen.
    static func rgb(_ image: CGImage) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw EmbeddingError.unreadable("a \(width)×\(height) image") }
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            pixels[pixel * 3] = rgba[pixel * 4]
            pixels[pixel * 3 + 1] = rgba[pixel * 4 + 1]
            pixels[pixel * 3 + 2] = rgba[pixel * 4 + 2]
        }
        return (pixels, width, height)
    }

    /// Up to `duration` seconds of the recording at `url` from `start`, mixed
    /// down to mono and resampled to `sampleRate`. Empty when `start` is past
    /// the end. A file `AVAudioFile` will not open — a video container it
    /// does not take — is read through AVFoundation's asset reader instead
    /// (`soundtrack`); one neither can is `unreadable`.
    static func audio(
        at url: URL,
        from start: TimeInterval = 0,
        duration: TimeInterval = audioWindow,
        sampleRate: Int
    ) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            return try soundtrack(at: url, from: start, duration: duration, sampleRate: sampleRate)
        }
        let input = file.processingFormat
        let first = AVAudioFramePosition((max(start, 0) * input.sampleRate).rounded(.down))
        guard first < file.length else { return [] }
        let count = AVAudioFrameCount(min(Double(file.length - first), max(duration, 0) * input.sampleRate))
        guard count > 0, let read = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: count) else { return [] }
        file.framePosition = first
        do {
            try file.read(into: read, frameCount: count)
        } catch {
            throw EmbeddingError.unreadable(url.path)
        }
        return try resample(read, to: sampleRate)
    }

    /// The first sound track of the asset at `url` — a video's soundtrack —
    /// from `start` for `duration` seconds, as mono floats at `sampleRate`,
    /// which the asset reader converts to itself. Synchronous: the helper
    /// answers one request at a time on a queue of its own, which this blocks.
    static func soundtrack(
        at url: URL, from start: TimeInterval, duration: TimeInterval, sampleRate: Int
    ) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try? blocking({ try await asset.loadTracks(withMediaType: .audio).first }),
              let reader = try? AVAssetReader(asset: asset)
        else { throw EmbeddingError.unreadable(url.path) }
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(start, 0), preferredTimescale: 48_000),
            duration: CMTime(seconds: max(duration, 0), preferredTimescale: 48_000)
        )
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw EmbeddingError.unreadable(url.path) }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            _ = chunk.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            samples += chunk
        }
        guard reader.status != .failed else { throw EmbeddingError.unreadable(url.path) }
        return samples
    }

    /// Runs async AVFoundation work from synchronous code, on a thread that
    /// is not the concurrency pool's: the helper's request queue.
    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let result = Mutex<Result<T, Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let outcome: Result<T, Error>
            do { outcome = .success(try await work()) } catch { outcome = .failure(error) }
            result.withLock { $0 = outcome }
            done.signal()
        }
        done.wait()
        return try result.withLock { $0! }.get()
    }

    /// Below this root-mean-square level (about −50 dBFS) a window is
    /// silence, and not worth a vector.
    static let silence: Float = 0.003

    static func isSilent(_ samples: [Float]) -> Bool {
        samples.isEmpty || vDSP.rootMeanSquare(samples) < silence
    }

    /// `buffer` as mono float samples at `sampleRate`.
    static func resample(_ buffer: AVAudioPCMBuffer, to sampleRate: Int) throws -> [Float] {
        guard let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: buffer.format, to: output) else {
            throw EmbeddingError.failed("can't convert \(buffer.format) to \(sampleRate) Hz mono")
        }
        converter.downmix = true
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * Double(sampleRate) / buffer.format.sampleRate).rounded(.up)
        ) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
            throw EmbeddingError.failed("can't allocate \(capacity) frames")
        }
        var handedOver = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if handedOver {
                inputStatus.pointee = .endOfStream
                return nil
            }
            handedOver = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = converted.floatChannelData?[0] else {
            throw EmbeddingError.failed("resampling failed: \(error?.localizedDescription ?? "\(status)")")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }
}

/// Why an input got no vector, or the embedder could not start.
nonisolated enum EmbeddingError: Error, Equatable, CustomStringConvertible {
    /// Not Apple silicon, or no Metal device (`MeaningSearch.isSupported`).
    case unsupported
    /// A model file is not in the models folder.
    case modelMissing(String)
    case cannotLoad(String)
    /// An image or audio clip handed to an embedder started text-only.
    case textOnly
    /// An input file that cannot be decoded. Its neighbours still get theirs.
    case unreadable(String)
    /// A window of sound with nothing in it (`EmbeddingInput.isSilent`).
    case silent
    case failed(String)

    var description: String {
        switch self {
        case .unsupported: "search by meaning needs Apple silicon"
        case .modelMissing(let name): "\(name) is not downloaded"
        case .cannotLoad(let what): "can't load \(what)"
        case .textOnly: "this embedder was started text-only"
        case .unreadable(let what): "can't read \(what)"
        case .silent: "nothing but silence"
        case .failed(let why): why
        }
    }
}
