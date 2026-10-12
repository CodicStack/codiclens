import AppKit
import UniformTypeIdentifiers

enum BuiltInType: CaseIterable {
    case settings
    case clipboard
    case emoji
}

enum SubjectKind {
    case app(bundleIdentifier: String?, isRunning: Bool)
    /// A file on disk, carrying the `UTType` it was resolved to.
    ///
    /// A `UTType` rather than its identifier because the type is what Actions
    /// ask questions of — OCR appears only where it `conforms(to: .image)` —
    /// and re-deriving one from a string at every such question is how the two
    /// spellings drift apart. Resolved once, at Subject construction, in
    /// `PathSubject`.
    case file(contentType: UTType)
    case folder
    case text(rawText: String)
    /// An entry from clipboard history, acted on exactly like any other subject.
    case clipboard(ClipboardItem)
    /// One Emoji. Not `.text`: an Emoji carries a CLDR name and keywords, and
    /// it is displayed as a glyph rather than as its own characters.
    case emoji(Emoji)
    case builtIn(BuiltInType)
}

struct Subject: Identifiable {
    let id = UUID()
    let displayName: String
    let path: String?
    let url: URL?
    let icon: NSImage
    let kind: SubjectKind
    /// The file whose contents stand in for `icon` once Quick Look has drawn
    /// them, through `ThumbnailImage`: a file Subject's own file, or a
    /// Clipboard Image's stored PNG. `nil` for everything that is its icon — an
    /// app, a folder, text, a Built-in.
    let thumbnailURL: URL?
    /// Where in the file a File Result matched, carried from its row to the
    /// Subject chosen from it and through its Actions. Nil for everything else,
    /// a file that matched on its name included.
    var passage: SubjectPassage?

    var subtitle: String {
        switch kind {
        case .text:
            return "Text"
        case .clipboard(let item):
            return item.isImage ? "Clipboard Image" : "Clipboard Text"
        case .builtIn(.settings):
            return "Codiclens"
        case .builtIn(.clipboard):
            return "Clipboard History"
        case .builtIn(.emoji):
            return "Emoji"
        case .emoji(let emoji):
            return emoji.string
        default:
            guard let path else { return "" }
            let home = FileManager.default.homeDirectoryForCurrentUser.path()
            if path.hasPrefix(home) {
                return "~" + path.dropFirst(home.count)
            }
            return path
        }
    }

    /// The clipboard entry behind this subject, if it is one.
    var clipboardItem: ClipboardItem? {
        if case .clipboard(let item) = kind { return item }
        return nil
    }

    /// The Emoji behind this subject, if it is one.
    var emoji: Emoji? {
        if case .emoji(let emoji) = kind { return emoji }
        return nil
    }

    init(
        displayName: String,
        path: String?,
        url: URL?,
        icon: NSImage,
        kind: SubjectKind,
        thumbnailURL: URL? = nil,
        passage: SubjectPassage? = nil
    ) {
        self.displayName = displayName
        self.path = path
        self.url = url
        self.icon = icon
        self.kind = kind
        self.thumbnailURL = thumbnailURL
        self.passage = passage
    }

    /// A Clipboard Item as a Subject. `imageURL` is its stored PNG, which only
    /// `ClipboardHistory` can say — `url` is the file it was copied *from*, a
    /// name and nothing else (`GLOSSARY.md`, **Clipboard Item**) — and it is
    /// what the Subject's thumbnail is drawn from.
    init(clipboardItem item: ClipboardItem, imageURL: URL?) {
        let symbol = item.isImage ? "photo" : "text.alignleft"
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        icon.size = NSSize(width: 32, height: 32)
        self.init(
            displayName: item.displayName,
            path: item.originalFilePath,
            url: item.originalFileURL,
            icon: icon,
            kind: .clipboard(item),
            thumbnailURL: imageURL
        )
    }

    /// An Emoji subject.
    ///
    /// `icon` is non-optional and an Emoji has no artwork to put there, so it
    /// gets a drawn one — deferred, so nothing is rasterised unless a Card
    /// actually shows it. The Results Slab does not use this path: in grid Mode
    /// `EmojiGridView` draws the glyph as text, which is sharper and cheaper.
    init(emoji: Emoji) {
        self.init(
            displayName: emoji.name,
            path: nil,
            url: nil,
            icon: EmojiRenderer.image(for: emoji.string),
            kind: .emoji(emoji)
        )
    }

    /// The Emoji Built-in, the way in from Subject search.
    ///
    /// One instance, not a fresh one per read: `id` is what the results list
    /// tracks, and a Built-in that changed identity on every keystroke would
    /// churn the list.
    static let emojiBuiltIn: Subject = {
        let icon = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: nil) ?? NSImage()
        icon.size = NSSize(width: 32, height: 32)
        return Subject(
            displayName: "Emoji",
            path: nil,
            url: nil,
            icon: icon,
            kind: .builtIn(.emoji)
        )
    }()

    /// A text subject, the shape transforms produce.
    init(text: String) {
        let icon = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil) ?? NSImage()
        icon.size = NSSize(width: 32, height: 32)
        self.init(displayName: text, path: nil, url: nil, icon: icon, kind: .text(rawText: text))
    }
}
