import AppKit

enum ResultIcon {
    case nsImage(NSImage)
    case sfSymbol(String)
}

struct ResultDisplayItem: Identifiable {
    /// The id of the thing this row *is*, as a string.
    ///
    /// Deliberately not a `UUID` any more. It used to be, and the one
    /// initialiser that could not supply one minted `UUID()` per call instead —
    /// so every rebuild handed `ForEach` a completely new set of rows and the
    /// whole list re-identified on every keystroke. A `String` makes it obvious
    /// that the id belongs to the source, and there is nothing convenient to
    /// invent when it doesn't.
    let id: String
    let name: String
    let icon: ResultIcon
    /// The file whose thumbnail replaces `icon` once it lands, if there is one.
    /// Not part of `id`: a row stays the same row while its picture arrives.
    let thumbnailURL: URL?
    let subtitle: String

    /// Whether the subtitle is worth marking the Query's characters up in.
    ///
    /// True where the subtitle names the thing — "Clipboard History" under
    /// "Clipboard", the path under an app — because there the same characters
    /// the Query matched in the name usually appear again, and marking them
    /// says why the row is here. False where the subtitle is a *derived* value:
    /// a relative timestamp like "5m ago" can line up with a letter of the
    /// Query by pure coincidence, and an underline there is noise pretending to
    /// be information.
    let highlightsSubtitle: Bool

    /// Where the subtitle is the words a file matched on (a Passage), the
    /// places FTS5 matched the Query in them, in characters. Marked instead of
    /// `highlightsSubtitle`'s guess: a long excerpt holds the Query's letters
    /// as a subsequence almost always, and underlining those would be noise.
    private(set) var subtitleMarks: [Range<Int>]?

    init(from subject: Subject) {
        self.id = subject.id.uuidString
        self.name = subject.displayName
        self.icon = .nsImage(subject.icon)
        self.thumbnailURL = subject.thumbnailURL
        self.subtitle = subject.subtitle
        self.highlightsSubtitle = true
    }

    init(from action: SubjectAction) {
        self.id = action.id.uuidString
        self.name = action.name
        self.icon = switch action.icon {
        case .sfSymbol(let name): .sfSymbol(name)
        case .appIcon(let image): .nsImage(image)
        }
        self.thumbnailURL = nil
        self.subtitle = action.isFinal ? "" : "→"
        self.highlightsSubtitle = false
    }

    init(from target: ActionTarget) {
        self.id = target.id.uuidString
        self.name = target.name
        self.icon = .nsImage(target.icon)
        self.thumbnailURL = target.thumbnailURL
        self.subtitle = target.subtitle
        self.highlightsSubtitle = true
        self.subtitleMarks = target.subtitleMarks
    }

    /// `imageURL` is the item's stored PNG, from `ClipboardHistory`; the row
    /// shows the generic photo symbol until its thumbnail lands.
    init(from item: ClipboardItem, imageURL: URL?) {
        self.id = item.id.uuidString
        self.name = item.displayName
        self.icon = item.isImage ? .sfSymbol("photo") : .sfSymbol("text.alignleft")
        self.thumbnailURL = imageURL
        self.subtitle = Self.age(of: item)
        self.highlightsSubtitle = false
    }

    // MARK: - The list below the apps

    // Subject search's second list mixes three Sources, so each of its rows
    // says which one it came from (ADR 0012). Ids are prefixed by Source: the
    // list holds a file, a Clipboard Item and an Emoji side by side.

    /// A File Result: its folder under its name, which is the Source as the
    /// user added it. Marked up, because a file found by its folder is there
    /// for the folder's name. A file found by what it says shows that
    /// instead — its Passage, with the matched words marked. The id is the
    /// file's either way.
    init(file hit: FileHit, icon: NSImage) {
        self.id = "file:" + hit.url.path
        self.name = hit.name
        self.icon = .nsImage(icon)
        self.thumbnailURL = hit.kind == .file ? hit.url : nil
        if let passage = hit.passage {
            self.subtitle = passage.subtitle
            self.highlightsSubtitle = false
            self.subtitleMarks = passage.subtitleMatches
        } else {
            self.subtitle = hit.folder
            self.highlightsSubtitle = true
        }
    }

    /// A Clipboard Item, named as one — "Clipboard · 5m ago".
    init(clipboardResult item: ClipboardItem, imageURL: URL?) {
        self.id = "clipboard:" + item.id.uuidString
        self.name = item.displayName
        self.icon = item.isImage ? .sfSymbol("photo") : .sfSymbol("text.alignleft")
        self.thumbnailURL = imageURL
        self.subtitle = "Clipboard · " + Self.age(of: item)
        self.highlightsSubtitle = false
    }

    /// An Emoji as a list row: its glyph where an icon goes and its CLDR name.
    /// `emoji` is what is drawn, in the tone in force; the id is the base's,
    /// because a variant is never a Result of its own.
    init(emoji: Emoji, base: Emoji) {
        self.id = "emoji:" + base.string
        self.name = emoji.name
        self.icon = .nsImage(EmojiRenderer.image(for: emoji.string, box: PanelLayout.resultIconSize))
        self.thumbnailURL = nil
        self.subtitle = "Emoji"
        self.highlightsSubtitle = false
    }

    /// The subtitle as the row draws it: a Passage's matched words
    /// underlined, a name marked up against the Query, or plain.
    func attributedSubtitle(query: String) -> AttributedString {
        guard let marks = subtitleMarks else {
            return highlightsSubtitle ? highlightedName(subtitle, query: query) : AttributedString(subtitle)
        }
        return underlined(subtitle, marks: marks)
    }

    private static func age(of item: ClipboardItem) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: item.timestamp, relativeTo: Date())
    }
}
