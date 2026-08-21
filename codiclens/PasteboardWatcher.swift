import AppKit

/// Where a pasteboard image gets re-encoded as PNG.
///
/// The seam exists because that conversion is the expensive part of recording a
/// copy — decoding a screenshot's TIFF and re-encoding it is tens of
/// milliseconds for a Retina capture, and it used to happen on the main thread
/// inside the poll, so copying a screenshot stalled the UI. The pasteboard read
/// itself stays on the main thread: `NSPasteboard` is not thread-safe, and only
/// the conversion moves.
protocol ImageReencoder {
    /// Runs `convert` away from the main thread and delivers its result **on**
    /// the main thread.
    func reencode(_ convert: @escaping () -> Data?, completion: @escaping (Data?) -> Void)
}

/// The app's re-encoder: a utility queue out, the main queue back.
struct BackgroundImageReencoder: ImageReencoder {
    func reencode(_ convert: @escaping () -> Data?, completion: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let data = convert()
            DispatchQueue.main.async { completion(data) }
        }
    }
}

/// Converts in place. The test adapter, so `record()` stays synchronous.
struct InlineImageReencoder: ImageReencoder {
    func reencode(_ convert: @escaping () -> Data?, completion: @escaping (Data?) -> Void) {
        completion(convert())
    }
}

/// Watches the system pasteboard and records what shows up.
///
/// The adapter half of the old ClipboardManager: it decodes pasteboard
/// contents and hands them to `ClipboardHistory`, which decides what to keep.
final class PasteboardWatcher {
    private let history: ClipboardHistory
    private let pasteboard: NSPasteboard
    private let interval: TimeInterval
    private let reencoder: ImageReencoder
    private var lastChangeCount: Int
    private var timer: Timer?

    init(
        history: ClipboardHistory,
        pasteboard: NSPasteboard = .general,
        interval: TimeInterval = 0.5,
        reencoder: ImageReencoder = BackgroundImageReencoder()
    ) {
        self.history = history
        self.pasteboard = pasteboard
        self.interval = interval
        self.reencoder = reencoder
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollIfChanged()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Records the current pasteboard contents if its change count moved.
    func pollIfChanged() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        record()
    }

    /// Reads the pasteboard once, whatever its change count says.
    ///
    /// Every pasteboard read happens here, synchronously, before anything is
    /// handed off — so the background conversion never touches `NSPasteboard`.
    func record(timestamp: Date = Date()) {
        let originalImageURL = imageFileURLs().first

        // Raw image data wins: a screenshot is on the pasteboard as PNG or TIFF.
        // PNG needs nothing doing to it.
        if let png = pasteboard.data(forType: .png) {
            history.recordImage(png, originalURL: originalImageURL, timestamp: timestamp)
            return
        }

        if let tiff = pasteboard.data(forType: .tiff) {
            let history = history
            reencoder.reencode({ Self.pngData(fromTIFF: tiff) }) { png in
                // Falls back to the TIFF rather than dropping the copy: an entry
                // in the wrong format still pastes, a missing one does not.
                history.recordImage(png ?? tiff, originalURL: originalImageURL, timestamp: timestamp)
            }
            return
        }

        // Otherwise an image file copied in the Finder.
        if let originalImageURL {
            history.recordImageFile(at: originalImageURL, timestamp: timestamp)
            return
        }

        guard let text = pasteboard.string(forType: .string) else { return }
        history.recordText(text, timestamp: timestamp)
    }

    /// The expensive half, and the only part that runs off the main thread.
    /// Touches nothing but its argument.
    static func pngData(fromTIFF data: Data) -> Data? {
        guard let bitmap = NSBitmapImageRep(data: data) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func imageFileURLs() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { Self.isPreviewableImageFile($0) }
    }

    static func isPreviewableImageFile(_ url: URL) -> Bool {
        let extensions: Set<String> = [
            "jpg", "jpeg", "png", "gif", "heic", "heif",
            "tiff", "tif", "bmp", "webp", "pdf", "svg"
        ]
        return extensions.contains(url.pathExtension.lowercased())
    }
}
