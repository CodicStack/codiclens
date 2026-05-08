import AppKit
import ImageIO

@Observable
class ClipboardManager {
    static let shared = ClipboardManager()

    private(set) var items: [ClipboardItem] = []
    private var lastChangeCount: Int = 0
    private var timer: Timer?
    private let maxItems = 100

    private var storageURL: URL {
        let dir = appSupportDirectory
        return dir.appendingPathComponent("clipboard_history.json")
    }

    private var appSupportDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("codiclens")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var imagesDirectory: URL {
        let dir = appSupportDirectory.appendingPathComponent("images")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var previewsDirectory: URL {
        let dir = appSupportDirectory.appendingPathComponent("previews")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        load()
        lastChangeCount = NSPasteboard.general.changeCount
        startPolling()
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
    }

    private func checkForChanges() {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        let pb = NSPasteboard.general
        let originalImageURL = imageFileURLs(from: pb).first

        if let imageData = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            if let first = items.first, first.isImage,
               let existingData = self.imageData(for: first),
               existingData == imageData { return }

            let timestamp = Date()
            let fileName = imageFileName(timestamp: timestamp, originalURL: originalImageURL, extensionOverride: "png")
            let fileURL = imagesDirectory.appendingPathComponent(fileName)

            let pngData: Data
            if pb.data(forType: .png) != nil {
                pngData = imageData
            } else if let bitmapRep = NSBitmapImageRep(data: imageData),
                      let converted = bitmapRep.representation(using: .png, properties: [:]) {
                pngData = converted
            } else {
                pngData = imageData
            }

            do {
                try pngData.write(to: fileURL, options: .atomic)
                items.insert(ClipboardItem(
                    imageFileName: fileName,
                    originalFilePath: originalImageURL?.path,
                    timestamp: timestamp
                ), at: 0)
                trimAndSave()
            } catch {}
            return
        }

        if let originalImageURL {
            if let first = items.first, first.originalFilePath == originalImageURL.path { return }

            let timestamp = Date()
            let fileName = imageFileName(timestamp: timestamp, originalURL: originalImageURL)
            let fileURL = imagesDirectory.appendingPathComponent(fileName)

            do {
                try FileManager.default.copyItem(at: originalImageURL, to: fileURL)
                items.insert(ClipboardItem(
                    imageFileName: fileName,
                    originalFilePath: originalImageURL.path,
                    timestamp: timestamp
                ), at: 0)
                trimAndSave()
            } catch {}
            return
        }

        guard let text = pb.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if let existing = items.first, !existing.isImage, existing.content == text { return }

        items.insert(ClipboardItem(content: text), at: 0)
        trimAndSave()
    }

    func updateText(at index: Int, text: String) {
        guard index < items.count, !items[index].isImage else { return }
        items[index] = ClipboardItem(content: text)
        save()
    }

    func remove(at index: Int) {
        guard index < items.count else { return }
        let item = items[index]
        if let fileName = item.imageFileName {
            let fileURL = imagesDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
        items.remove(at: index)
        save()
    }

    func imageData(for item: ClipboardItem) -> Data? {
        guard let fileName = item.imageFileName else { return nil }
        let fileURL = imagesDirectory.appendingPathComponent(fileName)
        return try? Data(contentsOf: fileURL)
    }

    func previewURL(for item: ClipboardItem) -> URL? {
        if let originalURL = item.originalFileURL,
           FileManager.default.fileExists(atPath: originalURL.path) {
            return originalURL
        }

        if let fileName = item.imageFileName {
            return imagesDirectory.appendingPathComponent(fileName)
        }

        return textPreviewURL(for: item)
    }

    func thumbnail(for item: ClipboardItem, size: CGFloat = 32) -> NSImage? {
        guard let fileName = item.imageFileName else { return nil }
        let fileURL = imagesDirectory.appendingPathComponent(fileName)
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: size * 2,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    private func trimAndSave() {
        if items.count > maxItems {
            let removed = items.suffix(from: maxItems)
            for item in removed {
                if let fileName = item.imageFileName {
                    let fileURL = imagesDirectory.appendingPathComponent(fileName)
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
            items = Array(items.prefix(maxItems))
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data)
        else { return }
        items = decoded
    }

    private func textPreviewURL(for item: ClipboardItem) -> URL? {
        let fileURL = previewsDirectory.appendingPathComponent("\(item.id.uuidString).txt")
        do {
            try item.content.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }

    private func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { isPreviewableImageFile($0) }
    }

    private func isPreviewableImageFile(_ url: URL) -> Bool {
        let extensions: Set<String> = [
            "jpg", "jpeg", "png", "gif", "heic", "heif",
            "tiff", "tif", "bmp", "webp", "pdf", "svg"
        ]
        return extensions.contains(url.pathExtension.lowercased())
    }

    private func imageFileName(timestamp: Date, originalURL: URL?, extensionOverride: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"

        let ext: String
        if let extensionOverride {
            ext = extensionOverride
        } else if let originalURL, !originalURL.pathExtension.isEmpty {
            ext = originalURL.pathExtension.lowercased()
        } else {
            ext = "png"
        }

        if let originalURL {
            let base = (originalURL.deletingPathExtension().lastPathComponent as NSString)
                .replacingOccurrences(of: "/", with: "-")
            return "\(base) \(formatter.string(from: timestamp)).\(ext)"
        }

        return "Screenshot \(formatter.string(from: timestamp)).\(ext)"
    }
}
