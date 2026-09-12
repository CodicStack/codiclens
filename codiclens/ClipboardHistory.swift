import AppKit

/// The clipboard history and the rules that govern it: what counts as a new
/// entry, what gets deduplicated, and how many are kept.
///
/// Knows nothing about the pasteboard — `PasteboardWatcher` decodes that and
/// records what it finds here. Knows nothing about disk either; that's the
/// `ClipboardStore` behind it.
@Observable
final class ClipboardHistory {
    static let shared = ClipboardHistory(store: FileClipboardStore())

    private(set) var items: [ClipboardItem] = []

    private let store: ClipboardStore
    private let maxItems: Int

    init(store: ClipboardStore, maxItems: Int = 100) {
        self.store = store
        self.maxItems = maxItems
        self.items = store.loadItems()
    }

    // MARK: - Recording

    /// Records copied text, unless it's blank or already at the top.
    /// - Returns: whether it was recorded.
    @discardableResult
    func recordText(_ text: String, timestamp: Date = Date()) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let first = items.first, !first.isImage, first.content == text { return false }

        items.insert(ClipboardItem(content: text, timestamp: timestamp), at: 0)
        trimAndSave()
        return true
    }

    /// Records raw image data, unless it matches the image already at the top.
    @discardableResult
    func recordImage(_ pngData: Data, originalURL: URL? = nil, timestamp: Date = Date()) -> Bool {
        if let first = items.first, first.isImage, imageData(for: first) == pngData { return false }

        return insertImage(pngData, originalURL: originalURL, timestamp: timestamp)
    }

    /// Records output created inside Codiclens as a new Clipboard Item even
    /// when equal pixels already sit at the top. QR Code promises a new image,
    /// while pasteboard polling keeps its ordinary top-item deduplication.
    @discardableResult
    func recordGeneratedImage(_ pngData: Data, timestamp: Date = Date()) -> ClipboardItem? {
        guard insertImage(pngData, originalURL: nil, timestamp: timestamp) else { return nil }
        return items.first
    }

    private func insertImage(_ pngData: Data, originalURL: URL?, timestamp: Date) -> Bool {
        let fileName = uniqueImageFileName(Self.imageFileName(
            timestamp: timestamp,
            originalURL: originalURL,
            extensionOverride: "png"
        ))
        guard (try? store.writeImage(pngData, named: fileName)) != nil else { return false }

        items.insert(ClipboardItem(
            imageFileName: fileName,
            originalFilePath: originalURL?.path,
            timestamp: timestamp
        ), at: 0)
        trimAndSave()
        return true
    }

    /// Records an image file copied in the Finder, unless it's already at the top.
    @discardableResult
    func recordImageFile(at source: URL, timestamp: Date = Date()) -> Bool {
        if let first = items.first, first.originalFilePath == source.path { return false }

        let fileName = uniqueImageFileName(Self.imageFileName(timestamp: timestamp, originalURL: source))
        guard (try? store.copyImage(from: source, named: fileName)) != nil else { return false }

        items.insert(ClipboardItem(
            imageFileName: fileName,
            originalFilePath: source.path,
            timestamp: timestamp
        ), at: 0)
        trimAndSave()
        return true
    }

    // MARK: - Editing

    func updateText(at index: Int, text: String) {
        guard items.indices.contains(index), !items[index].isImage else { return }
        items[index] = ClipboardItem(content: text)
        save()
    }

    func updateText(for item: ClipboardItem, text: String) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        updateText(at: index, text: text)
    }

    func moveToTop(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }), index != 0 else { return }
        items.remove(at: index)
        items.insert(item, at: 0)
        save()
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        if let fileName = items[index].imageFileName {
            store.removeImage(named: fileName)
        }
        items.remove(at: index)
        save()
    }

    func remove(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        remove(at: index)
    }

    func index(of item: ClipboardItem) -> Int? {
        items.firstIndex(where: { $0.id == item.id })
    }

    // MARK: - Reading

    func imageURL(for item: ClipboardItem) -> URL? {
        item.imageFileName.map { store.imageURL(named: $0) }
    }

    func imageData(for item: ClipboardItem) -> Data? {
        item.imageFileName.flatMap { store.imageData(named: $0) }
    }

    /// What Quick Look should show: the stored image, and a written-out
    /// preview for text.
    ///
    /// Never the file the image was copied from, even when that file is still
    /// there. A Clipboard Item is a **snapshot** — the pixels as they were at
    /// copy time (`CONTEXT.md`, **Clipboard Item**) — so Quick Look, Paste,
    /// Share and Open in Preview all show the same thing, and editing the
    /// original afterwards changes none of them. `originalFilePath` survives to
    /// lend the entry its name and nothing else.
    func previewURL(for item: ClipboardItem) -> URL? {
        if let imageURL = imageURL(for: item) {
            return imageURL
        }
        return store.textPreviewURL(for: item)
    }

    // MARK: - Persistence

    private func trimAndSave() {
        if items.count > maxItems {
            for item in items.suffix(from: maxItems) {
                if let fileName = item.imageFileName {
                    store.removeImage(named: fileName)
                }
            }
            items = Array(items.prefix(maxItems))
        }
        save()
    }

    private func save() {
        store.saveItems(items)
    }

    /// A timestamp has one-second precision, so two images recorded during the
    /// same second need distinct paths. Otherwise the newer write silently
    /// changes the older Clipboard Item's snapshot too.
    private func uniqueImageFileName(_ proposed: String) -> String {
        guard store.imageData(named: proposed) != nil else { return proposed }

        let pathExtension = (proposed as NSString).pathExtension
        let stem = (proposed as NSString).deletingPathExtension
        var suffix = 2
        while true {
            let candidate = pathExtension.isEmpty
                ? "\(stem) \(suffix)"
                : "\(stem) \(suffix).\(pathExtension)"
            if store.imageData(named: candidate) == nil { return candidate }
            suffix += 1
        }
    }

    // MARK: - Naming

    /// Screenshots keep their capture time; copied files keep their own name.
    static func imageFileName(
        timestamp: Date,
        originalURL: URL?,
        extensionOverride: String? = nil
    ) -> String {
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
