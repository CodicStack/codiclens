import AppKit

/// Watches the system pasteboard and records what shows up.
///
/// The adapter half of the old ClipboardManager: it decodes pasteboard
/// contents and hands them to `ClipboardHistory`, which decides what to keep.
final class PasteboardWatcher {
    private let history: ClipboardHistory
    private let pasteboard: NSPasteboard
    private let interval: TimeInterval
    private var lastChangeCount: Int
    private var timer: Timer?

    init(
        history: ClipboardHistory,
        pasteboard: NSPasteboard = .general,
        interval: TimeInterval = 0.5
    ) {
        self.history = history
        self.pasteboard = pasteboard
        self.interval = interval
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
    func record(timestamp: Date = Date()) {
        let originalImageURL = imageFileURLs().first

        // Raw image data wins: a screenshot is on the pasteboard as PNG or TIFF.
        if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            history.recordImage(
                Self.pngData(from: imageData, wasPNG: pasteboard.data(forType: .png) != nil),
                originalURL: originalImageURL,
                timestamp: timestamp
            )
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

    private static func pngData(from data: Data, wasPNG: Bool) -> Data {
        if wasPNG { return data }
        guard let bitmap = NSBitmapImageRep(data: data),
              let converted = bitmap.representation(using: .png, properties: [:]) else { return data }
        return converted
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
