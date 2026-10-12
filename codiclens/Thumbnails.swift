import AppKit
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
final class Thumbnails {
    static let shared = Thumbnails()

    /// A file, at a side in points, for a screen of a backing scale.
    ///
    /// The scale is part of it because a thumbnail is pixels: one made for a 1x
    /// screen is soft on a 2x one.
    nonisolated struct Request: Hashable, Sendable {
        let url: URL
        let side: CGFloat
        let scale: CGFloat
    }

    /// The file as it was when its thumbnail was made.
    nonisolated struct Stamp: Hashable, Sendable {
        let modificationDate: Date
        let size: Int64
    }

    /// Makes one thumbnail: Quick Look in the app, a stand-in in tests.
    typealias Generator = @Sendable (Request) async -> CGImage?

    /// `.thumbnail` only. Asking for every representation would hand back the
    /// file's icon when there is no thumbnail, and the caller already has that.
    static let quickLook: Generator = { request in
        let qlRequest = QLThumbnailGenerator.Request(
            fileAt: request.url,
            size: CGSize(width: request.side, height: request.side),
            scale: request.scale,
            representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: qlRequest)
            .cgImage
    }

    private let generator: Generator
    private let cache = NSCache<NSString, Entry>()
    /// One generation per file version at a time: rows rebuilt by a keystroke
    /// ask again before the first answer is in.
    private var inFlight: [InFlightKey: Task<NSImage?, Never>] = [:]

    init(generator: @escaping Generator = Thumbnails.quickLook) {
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
        "\(request.url.path)|\(request.side)|\(request.scale)" as NSString
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
/// Asks only once it is on screen, through `.task`, so a list asks for the rows
/// a `LazyVStack` actually builds and not for every Result in memory. Leaving
/// the screen cancels the wait. The request is sized to the slot it is drawn in
/// and the screen's backing scale.
///
/// The thumbnail is checked against the file each time the view appears, and
/// not otherwise. A caller that knows the file changed under a view that stays —
/// the Subject Card after Rotate — gives the view a new identity.
struct ThumbnailImage<Icon: View>: View {
    let url: URL?
    let side: CGFloat
    @ViewBuilder let icon: Icon

    @Environment(\.displayScale) private var scale
    @State private var landed: Landed?

    private struct Landed {
        let request: Thumbnails.Request
        let image: NSImage?
    }

    private var request: Thumbnails.Request? {
        url.map { Thumbnails.Request(url: $0, side: side, scale: scale) }
    }

    var body: some View {
        if let request {
            Group {
                if let image = image(for: request) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    icon
                }
            }
            .task(id: request) {
                let image = await Thumbnails.shared.thumbnail(for: request)
                guard !Task.isCancelled else { return }
                landed = Landed(request: request, image: image)
            }
        } else {
            icon
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
