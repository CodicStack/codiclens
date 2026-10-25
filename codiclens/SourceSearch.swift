import Foundation

/// The list below the apps in Subject search: File Results, Clipboard Items
/// and Emoji, ranked against each other by score — see
/// `docs/adr/0012-files-in-subject-search-text-mode-is-cmd-e.md`.
///
/// A copy of everything it ranks, taken on the main actor as the search
/// starts, so the ranking itself can run anywhere. `SubjectSearchVM` owns when it runs
/// and what becomes of the answer; this owns only the order.
///
/// Every Source scores on `fuzzyScore`'s scale, lower is better, and that is
/// the whole of the cross-Source ranking: there is no priority between Sources
/// (`GLOSSARY.md`, **Source**). Ties go files, then Clipboard, then Emoji, so the
/// order is stable — a tie-break, not a priority. The settled pass's Kind
/// block — the files of the Kind a Kind Word asks for — scores below zero
/// (`FileHit.kindScore`), so it comes before every Clipboard Item and Emoji:
/// the Query asked for that Kind. Below it they mix with the rest by score.
nonisolated struct SourceSearch: Sendable {
    /// One row of the list, before it is a Subject.
    enum Hit: Sendable {
        case file(FileHit)
        case clipboard(ClipboardItem)
        case emoji(Emoji)
    }

    struct Ranked: Sendable {
        let hit: Hit
        let score: Int
    }

    /// As many File Results as the File Index gives back. The list scrolls,
    /// and files are the reason it exists.
    static let fileLimit = 50

    /// Clipboard and Emoji are capped so a short Query, which matches dozens
    /// of each, cannot bury the files under them.
    static let clipboardCap = 3
    static let emojiCap = 3

    /// The File Index's part: the word search on the keystroke, the settled
    /// search once typing pauses (`SubjectSearchVM`).
    typealias FileSearch = @Sendable (_ query: String) async -> [FileHit]

    let query: String
    let searchFiles: FileSearch
    /// Text Clipboard Items, or none when Clipboard History is switched off.
    /// An image's name is only its timestamp, so it has nothing to match on.
    let clipboard: [ClipboardItem]
    /// The Emoji dataset, or none when Emoji is switched off.
    let emoji: [Emoji]
    let recentEmoji: [String]

    /// Off the main actor: the File Index read and ranking 1,914 Emoji are
    /// paid on the keystroke, and must not hold it up.
    @concurrent
    func ranked() async -> [Ranked] {
        rank(files: await searchFiles(query))
    }

    /// `files`, the File Index's answer, ranked with the Clipboard Items and
    /// Emoji that match.
    func rank(files: [FileHit]) -> [Ranked] {
        let fileRows = files
            .prefix(Self.fileLimit)
            .map { Ranked(hit: .file($0), score: $0.score) }

        let clipboardRows = ClipboardSearchVM.scored(clipboard, query: query)
            .prefix(Self.clipboardCap)
            .map { Ranked(hit: .clipboard($0.item), score: $0.score) }

        // Emoji Mode trims its Query; so does this, so the two agree.
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let emojiRows = trimmed.isEmpty ? [] : EmojiSearchVM.scored(emoji, query: trimmed, recents: recentEmoji)
            .prefix(Self.emojiCap)
            .map { Ranked(hit: .emoji($0.emoji), score: $0.score) }

        return (fileRows + clipboardRows + emojiRows)
            .enumerated()
            .sorted { ($0.element.score, $0.offset) < ($1.element.score, $1.offset) }
            .map(\.element)
    }
}
