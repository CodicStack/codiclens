import Foundation

/// Where clipboard history is kept. Two adapters satisfy it: `FileClipboardStore`
/// in the app, `InMemoryClipboardStore` in tests.
///
/// The on-disk layout — Application Support, `images/`, `previews/` — is this
/// module's business and nobody else's.
protocol ClipboardStore: AnyObject {
    func loadItems() -> [ClipboardItem]
    func saveItems(_ items: [ClipboardItem])

    func imageURL(named fileName: String) -> URL
    func imageData(named fileName: String) -> Data?
    func writeImage(_ data: Data, named fileName: String) throws
    func copyImage(from source: URL, named fileName: String) throws
    func removeImage(named fileName: String)

    /// Quick Look needs a file to preview, so text items get written out on demand.
    func textPreviewURL(for item: ClipboardItem) -> URL?
}

// MARK: - Application Support

final class FileClipboardStore: ClipboardStore {
    private let root: URL

    /// - Parameter root: the directory to keep history in. Defaults to
    ///   `~/Library/Application Support/codiclens`.
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("codiclens")
    }

    private var itemsURL: URL {
        directory(root).appendingPathComponent("clipboard_history.json")
    }

    private var imagesDirectory: URL {
        directory(root.appendingPathComponent("images"))
    }

    private var previewsDirectory: URL {
        directory(root.appendingPathComponent("previews"))
    }

    private func directory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func loadItems() -> [ClipboardItem] {
        guard let data = try? Data(contentsOf: itemsURL),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data)
        else { return [] }
        return decoded
    }

    func saveItems(_ items: [ClipboardItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: itemsURL, options: .atomic)
    }

    func imageURL(named fileName: String) -> URL {
        imagesDirectory.appendingPathComponent(fileName)
    }

    func imageData(named fileName: String) -> Data? {
        try? Data(contentsOf: imageURL(named: fileName))
    }

    func writeImage(_ data: Data, named fileName: String) throws {
        try data.write(to: imageURL(named: fileName), options: .atomic)
    }

    func copyImage(from source: URL, named fileName: String) throws {
        try FileManager.default.copyItem(at: source, to: imageURL(named: fileName))
    }

    func removeImage(named fileName: String) {
        try? FileManager.default.removeItem(at: imageURL(named: fileName))
    }

    func textPreviewURL(for item: ClipboardItem) -> URL? {
        let fileURL = previewsDirectory.appendingPathComponent("\(item.id.uuidString).txt")
        do {
            try item.content.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }
}

// MARK: - Tests

final class InMemoryClipboardStore: ClipboardStore {
    private(set) var items: [ClipboardItem] = []
    private(set) var images: [String: Data] = [:]

    init(items: [ClipboardItem] = []) {
        self.items = items
    }

    func loadItems() -> [ClipboardItem] { items }

    func saveItems(_ items: [ClipboardItem]) { self.items = items }

    func imageURL(named fileName: String) -> URL {
        URL(fileURLWithPath: "/dev/null/images").appendingPathComponent(fileName)
    }

    func imageData(named fileName: String) -> Data? { images[fileName] }

    func writeImage(_ data: Data, named fileName: String) throws { images[fileName] = data }

    func copyImage(from source: URL, named fileName: String) throws {
        images[fileName] = try Data(contentsOf: source)
    }

    func removeImage(named fileName: String) { images[fileName] = nil }

    func textPreviewURL(for item: ClipboardItem) -> URL? { nil }
}
