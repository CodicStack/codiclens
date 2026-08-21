import Foundation

/// Where Emoji Recents are kept. Two adapters satisfy it: `FileEmojiRecentsStore`
/// in the app, `InMemoryEmojiRecentsStore` in tests.
///
/// Same shape as `ClipboardStore`, and the same on-disk neighbourhood —
/// Application Support — but a separate file. Emoji Recents are per-Mode and
/// have nothing to do with app ranking or Clipboard History.
protocol EmojiRecentsStore: AnyObject {
    func loadRecents() -> [String]
    func saveRecents(_ recents: [String])
}

// MARK: - Application Support

final class FileEmojiRecentsStore: EmojiRecentsStore {
    private let root: URL

    /// - Parameter root: the directory to keep Recents in. Defaults to
    ///   `~/Library/Application Support/codiclens`.
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("codiclens")
    }

    private var recentsURL: URL {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("emoji_recents.json")
    }

    func loadRecents() -> [String] {
        guard let data = try? Data(contentsOf: recentsURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return decoded
    }

    func saveRecents(_ recents: [String]) {
        guard let data = try? JSONEncoder().encode(recents) else { return }
        try? data.write(to: recentsURL, options: .atomic)
    }
}

// MARK: - Tests

final class InMemoryEmojiRecentsStore: EmojiRecentsStore {
    private(set) var recents: [String]

    init(recents: [String] = []) {
        self.recents = recents
    }

    func loadRecents() -> [String] { recents }

    func saveRecents(_ recents: [String]) { self.recents = recents }
}

// MARK: - Recents

/// Recently used Emoji, most recent first.
///
/// Stores base emoji strings, not toned ones: a Skin Tone variant is never a
/// Result in its own right, so using 👍🏽 makes 👍 recent and the tone is
/// re-applied from the preference when it is picked again.
@Observable
final class EmojiRecents {
    static let shared = EmojiRecents(store: FileEmojiRecentsStore())

    /// How many to keep. Roughly two grid rows' worth of genuinely recent
    /// choices — past that, search is the better tool.
    static let limit = 48

    private let store: EmojiRecentsStore

    private(set) var strings: [String]

    init(store: EmojiRecentsStore) {
        self.store = store
        self.strings = Array(store.loadRecents().prefix(Self.limit))
    }

    /// Moves an Emoji to the front, or adds it there.
    func record(_ emoji: Emoji) {
        strings.removeAll { $0 == emoji.string }
        strings.insert(emoji.string, at: 0)
        if strings.count > Self.limit { strings.removeLast(strings.count - Self.limit) }
        store.saveRecents(strings)
    }

    func clear() {
        strings = []
        store.saveRecents(strings)
    }

    /// How recently an Emoji was used — 0 is most recent, `nil` is never.
    func rank(of emoji: Emoji) -> Int? {
        strings.firstIndex(of: emoji.string)
    }

    /// Recents resolved back to Emoji, dropping anything the index no longer
    /// knows — an emoji removed by a dataset bump, say.
    func resolved(in index: EmojiIndex) -> [Emoji] {
        strings.compactMap(index.emoji)
    }
}
