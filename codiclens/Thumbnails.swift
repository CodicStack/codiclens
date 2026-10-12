import AppKit
import AVFoundation
import ImageIO
import PDFKit
import QuickLookThumbnailing
import SwiftUI

/// Every picture of what a file *contains* — an image, a PDF's first page, a
/// video frame, a Keynote slide — and the one place one is made.
///
/// Quick Look makes them (`QLThumbnailGenerator`), out of process and
/// asynchronously, so nothing ever waits for one: a row or a Card draws its icon
/// at once, and `ThumbnailImage` swaps the thumbnail in when it lands. A file
/// Quick Look cannot draw keeps its icon. Only regular files are asked about —
/// a folder or an app is its icon, and a bundle is a directory on disk.
///
/// Cached per file *as it is*: an entry carries the file's modification date and
/// size, because Rotate and an edit saved in Preview both write in place, and the
/// URL alone cannot say whether a thumbnail is still true.
///
/// A picture of one place in a file — the PDF page a Passage is on, the video
/// frame at its second (`Moment`) — is made here too, by PDFKit and
/// AVFoundation, since Quick Look only ever draws the start.
final class Thumbnails {
    static let shared = Thumbnails()

    /// A file, at a side in points, for a screen of a backing scale.
    ///
    /// The scale is part of it because a thumbnail is pixels: one made for a 1x
    /// screen is soft on a 2x one.
    ///
    /// `fills` asks for a picture that **covers** the square rather than fits
    /// in it, for a slot that draws it aspect-fill (the Subject Card). Quick
    /// Look answers with a thumbnail that fits the size it is asked for, so a
    /// 4:3 photo asked for at the Card's 200pt came back 200×150 and was
    /// stretched to 267×200 to fill — soft. A filling request asks for more
    /// along the long side (`fillingSize`), so the short side lands at `side`.
    /// The key stays `side`, so the cache holds one picture per slot.
    nonisolated struct Request: Hashable, Sendable {
        let url: URL
        let side: CGFloat
        let scale: CGFloat
        var fills = false
        var moment: Moment? = nil
    }

    /// One place in a file to picture instead of its start.
    nonisolated enum Moment: Hashable, Sendable {
        /// A PDF page, from 1.
        case page(Int)
        /// A video's frame at this second.
        case second(Double)
    }

    /// The file as it was when its thumbnail was made.
    nonisolated struct Stamp: Hashable, Sendable {
        let modificationDate: Date
        let size: Int64
    }

    /// Makes one thumbnail: Quick Look in the app, a stand-in in tests.
    typealias Generator = @Sendable (Request) async -> CGImage?

    /// Quick Look for a file's start; PDFKit for a page, AVFoundation for a
    /// video frame.
    static let system: Generator = { request in
        switch request.moment {
        case .page(let number): return await pdfPage(number, of: request)
        case .second(let seconds): return await videoFrame(at: seconds, of: request)
        case nil: return await quickLook(request)
        }
    }

    /// `.thumbnail` only. Asking for every representation would hand back the
    /// file's icon when there is no thumbnail, and the caller already has that.
    @concurrent
    nonisolated static func quickLook(_ request: Request) async -> CGImage? {
        let qlRequest = QLThumbnailGenerator.Request(
            fileAt: request.url,
            size: fillingSize(request, aspect: imageAspect(request)),
            scale: request.scale,
            representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: qlRequest)
            .cgImage
    }

    /// The square to ask for, in points: `side`, or for a filling request
    /// `side` times the picture's long side over its short one, so the short
    /// side is `side` once it fits. Where the aspect is not known — a document,
    /// a video's first frame — 16:9 is assumed, which covers a page and every
    /// common photo and screen. Capped at 4:1: a panorama past that is
    /// upscaled a little rather than held at 2,000 pixels a side.
    nonisolated static func fillingSize(_ request: Request, aspect: CGFloat?) -> CGSize {
        let ratio = request.fills ? min(max(aspect ?? 16.0 / 9.0, 1), 4) : 1
        return CGSize(width: request.side * ratio, height: request.side * ratio)
    }

    /// An image file's long side over its short one, from its header alone.
    nonisolated static func imageAspect(_ request: Request) -> CGFloat? {
        guard request.fills,
              let source = CGImageSourceCreateWithURL(request.url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else { return nil }
        return max(width, height) / min(width, height)
    }

    /// Page `number` of a PDF, on white, as Preview draws a page.
    @concurrent
    nonisolated static func pdfPage(_ number: Int, of request: Request) async -> CGImage? {
        guard let page = PDFDocument(url: request.url)?.page(at: number - 1) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let size = turned ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let box = fillingSize(request, aspect: max(size.width, size.height) / min(size.width, size.height)).width
        let scale = box * request.scale / max(size.width, size.height)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        // PDFKit applies the page's rotation and its box's origin.
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    /// A video's frame at `seconds`, upright, the nearest the decoder has
    /// rather than an exact one: a frame either side of the Passage's second
    /// pictures the same moment, and an exact seek decodes from the last
    /// keyframe.
    @concurrent
    nonisolated static func videoFrame(at seconds: Double, of request: Request) async -> CGImage? {
        let asset = AVURLAsset(url: request.url)
        var aspect: CGFloat?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let upright = natural.applying(transform)
            let width = abs(upright.width), height = abs(upright.height)
            if width > 0, height > 0 { aspect = max(width, height) / min(width, height) }
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let box = fillingSize(request, aspect: aspect)
        generator.maximumSize = CGSize(width: box.width * request.scale, height: box.height * request.scale)
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    private let generator: Generator
    private let cache = NSCache<NSString, Entry>()
    /// One generation per file version at a time: rows rebuilt by a keystroke
    /// ask again before the first answer is in.
    private var inFlight: [InFlightKey: Task<NSImage?, Never>] = [:]

    init(generator: @escaping Generator = Thumbnails.system) {
        self.generator = generator
        cache.countLimit = 400
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    /// The last thumbnail made for `request`, whether or not the file has
    /// changed since.
    ///
    /// What a view draws on its first frame. Rows are rebuilt on every
    /// keystroke, and a row that started from its icon each time would flash
    /// the icon before the same thumbnail came back. `thumbnail(for:)` then
    /// says whether this one still stands.
    func cached(_ request: Request) -> NSImage? {
        cache.object(forKey: Self.cacheKey(request))?.image
    }

    /// The thumbnail for the file as it is now, or `nil` where there is none:
    /// Quick Look could not draw it, it is not a regular file, or it is gone.
    func thumbnail(for request: Request) async -> NSImage? {
        let key = Self.cacheKey(request)
        guard let stamp = await Self.stamp(of: request.url) else {
            cache.removeObject(forKey: key)
            return nil
        }
        if let entry = cache.object(forKey: key), entry.stamp == stamp {
            return entry.image
        }

        let flight = InFlightKey(request: request, stamp: stamp)
        if let pending = inFlight[flight] { return await pending.value }

        let generator = generator
        let task = Task { () -> NSImage? in
            guard let cgImage = await generator(request) else { return nil }
            return NSImage(
                cgImage: cgImage,
                size: NSSize(
                    width: CGFloat(cgImage.width) / request.scale,
                    height: CGFloat(cgImage.height) / request.scale
                )
            )
        }
        inFlight[flight] = task
        let image = await task.value
        inFlight[flight] = nil

        // A failure is cached too, against the same stamp: a file Quick Look
        // cannot draw is asked once per version, not once per appearance.
        let cost = image.map { Int($0.size.width * $0.size.height * request.scale * request.scale * 4) } ?? 0
        cache.setObject(Entry(stamp: stamp, image: image), forKey: key, cost: cost)
        return image
    }

    /// `stat`, off the main actor — the file may be on a slow volume. Follows
    /// symlinks, so a link to an image is thumbnailed as the image.
    @concurrent
    nonisolated static func stamp(of url: URL) async -> Stamp? {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let modified = info.st_mtimespec
        return Stamp(
            modificationDate: Date(
                timeIntervalSince1970: TimeInterval(modified.tv_sec) + TimeInterval(modified.tv_nsec) / 1_000_000_000
            ),
            size: Int64(info.st_size)
        )
    }

    private static func cacheKey(_ request: Request) -> NSString {
        let moment = switch request.moment {
        case .page(let number): "p\(number)"
        case .second(let seconds): "s\(seconds)"
        case nil: ""
        }
        return "\(request.url.path)|\(request.side)|\(request.scale)|\(request.fills)|\(moment)" as NSString
    }

    private struct InFlightKey: Hashable {
        let request: Request
        let stamp: Stamp
    }

    private final class Entry {
        let stamp: Stamp
        let image: NSImage?

        init(stamp: Stamp, image: NSImage?) {
            self.stamp = stamp
            self.image = image
        }
    }
}

/// A file's icon until its thumbnail lands, then the thumbnail — swapped, never
/// faded. With no URL it is just the icon.
///
/// The thumbnail is drawn aspect-fit in the icon's slot. A view that lays out
/// differently once it has a picture — the Subject Card, which goes edge to
/// edge — reads it through `ThumbnailReader` instead.
struct ThumbnailImage<Icon: View>: View {
    let url: URL?
    let side: CGFloat
    @ViewBuilder let icon: Icon

    var body: some View {
        ThumbnailReader(url: url, side: side) { thumbnail in
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                icon
            }
        }
    }
}

/// A file's thumbnail as it stands — `nil` until it lands, or where there is
/// none — handed to `content` to draw. The one place a view asks `Thumbnails`.
///
/// Asks only once it is on screen, through `.task`, so a list asks for the rows
/// a `LazyVStack` actually builds and not for every Result in memory. Leaving
/// the screen cancels the wait. The request is `side` points square at the
/// screen's backing scale.
///
/// The first frame is the last thumbnail made for the request, so a view
/// rebuilt — a row by a keystroke, the Card by any change in the coordinator —
/// does not flash back to its icon. The thumbnail is checked against the file
/// each time the view appears, and not otherwise. A caller that knows the file
/// changed under a view that stays — the Subject Card after Rotate — gives the
/// view a new identity.
struct ThumbnailReader<Content: View>: View {
    let url: URL?
    let side: CGFloat
    /// Drawn aspect-fill, so asked for large enough to cover `side`.
    var fills = false
    /// A place in the file to picture instead of its start.
    var moment: Thumbnails.Moment? = nil
    @ViewBuilder let content: (NSImage?) -> Content

    @Environment(\.displayScale) private var scale
    @State private var landed: Landed?

    private struct Landed {
        let request: Thumbnails.Request
        let image: NSImage?
    }

    private var request: Thumbnails.Request? {
        url.map { Thumbnails.Request(url: $0, side: side, scale: scale, fills: fills, moment: moment) }
    }

    var body: some View {
        if let request {
            content(image(for: request))
                .task(id: request) {
                    let image = await Thumbnails.shared.thumbnail(for: request)
                    guard !Task.isCancelled else { return }
                    landed = Landed(request: request, image: image)
                }
        } else {
            content(nil)
        }
    }

    /// What has landed for this request, or else the last thumbnail made for
    /// it. `landed` is compared against the request because the same view can
    /// be handed another file — the Card as the selection moves — and must not
    /// show the previous file's thumbnail for a frame.
    private func image(for request: Thumbnails.Request) -> NSImage? {
        if let landed, landed.request == request { return landed.image }
        return Thumbnails.shared.cached(request)
    }
}
