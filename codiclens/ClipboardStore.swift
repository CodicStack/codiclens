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

    /// Where Quick Look's text copy of a file it cannot draw is written
    /// (`QuickLookPreviewItem`), beside the Clipboard Items' text previews.
    /// `nil` hands Quick Look every file as it is.
    var fileTextPreviewsDirectory: URL? { get }

    /// How many bytes the history takes on disk: its items, their images and
    /// their previews. Walks the disk in the app, so callers ask sparingly.
    func diskUsage() -> Int64
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
        // A copy is removed when its item goes; one still here was being
        // shown when the app quit.
        try? FileManager.default.removeItem(at: filePreviewsDirectory)
    }

    private var itemsURL: URL {
        directory(root).appendingPathComponent("clipboard_history.json")
    }

    /// Not created on read: `imageURL(named:)` is asked for every image row
    /// the Results Slab draws, and only a write needs the directory to exist.
    private var imagesDirectory: URL {
        root.appendingPathComponent("images")
    }

    private var previewsDirectory: URL {
        directory(root.appendingPathComponent("previews"))
    }

    var fileTextPreviewsDirectory: URL? { filePreviewsDirectory }

    /// Not created on read: a copy makes its own folder inside it.
    private var filePreviewsDirectory: URL {
        root.appendingPathComponent("previews").appendingPathComponent("files")
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
        _ = directory(imagesDirectory)
        try data.write(to: imageURL(named: fileName), options: .atomic)
    }

    func copyImage(from source: URL, named fileName: String) throws {
        _ = directory(imagesDirectory)
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

    /// The JSON file plus every file under `images/` and `previews/`, by the
    /// space each takes on disk. Nothing else in `root` belongs to the history.
    func diskUsage() -> Int64 {
        [itemsURL, imagesDirectory, root.appendingPathComponent("previews")]
            .reduce(0) { $0 + Self.allocatedBytes(at: $1) }
    }

    private static let sizeKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
    ]

    /// A file's size, or the sum of the files under a folder. `0` when
    /// nothing is there.
    private static func allocatedBytes(at url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: sizeKeys), values.isRegularFile == true {
            return fileBytes(values)
        }
        guard let files = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(sizeKeys)
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: sizeKeys),
                  values.isRegularFile == true
            else { continue }
            total += fileBytes(values)
        }
        return total
    }

    private static func fileBytes(_ values: URLResourceValues) -> Int64 {
        Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
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

    var fileTextPreviewsDirectory: URL? { nil }

    /// What the app would write: the items as JSON, plus each image's bytes.
    func diskUsage() -> Int64 {
        let json = (try? JSONEncoder().encode(items))?.count ?? 0
        return Int64(images.values.reduce(json) { $0 + $1.count })
    }
}
