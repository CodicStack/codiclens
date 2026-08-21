import Foundation

/// Emoji search and the grid's selection model.
///
/// Two layouts, both sectioned. With no Query: Recents first, then one section
/// per category — so the grid is never empty, not even on first run, when there
/// are no Recents and the categories carry it alone. With a Query: one section
/// of ranked matches.
@Observable
final class EmojiSearchVM {
    /// One block of the grid with its own heading.
    struct Section: Identifiable {
        let title: String
        let emoji: [Emoji]
        var id: String { title }
    }

    // MARK: Ranking weights

    /// Keywords are a real signal but a weaker one than the name, so a keyword
    /// hit scores like a name hit of the same shape plus this. Small enough
    /// that an exact keyword ("hot" → 🔥) still beats a name match buried
    /// mid-word, large enough that it never beats a name that starts with the
    /// Query ("hot" → "hot dog").
    static let keywordDiscount = 5

    /// What being in Recents is worth. Enough to lift a relevant Emoji past its
    /// equally-good neighbours, not enough to drag an irrelevant one into view —
    /// Recents only ever adjust an Emoji that already matched.
    static let recentsBoost = 4

    /// How many cells to a row. The keyboard model needs this to jump a row, so
    /// it lives with the model rather than with the view.
    static let columnCount = 6

    // MARK: State

    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            rebuild()
        }
    }

    /// Index into `flattened`.
    var selectedIndex: Int = 0

    private(set) var sections: [Section] = []

    /// Every Emoji on screen in reading order. The selection lives in this
    /// space; the grid renders from `sections`.
    private(set) var flattened: [Emoji] = []

    /// `flattened` as the Results Slab's list form. Built once per rebuild
    /// rather than on demand: with no Query this is every Emoji there is, and
    /// the slab asks for it several times per keystroke.
    private(set) var displayItems: [ResultDisplayItem] = []

    /// The Emoji whose six-tone override picker is open, if one is.
    private(set) var tonePickerEmoji: Emoji?

    /// Index into `SkinTone.allCases` while the picker is open.
    var toneIndex: Int = 0

    let index: EmojiIndex
    let recents: EmojiRecents
    let preferences: EmojiPreferences

    init(
        index: EmojiIndex = .shared,
        recents: EmojiRecents = .shared,
        preferences: EmojiPreferences = .shared
    ) {
        self.index = index
        self.recents = recents
        self.preferences = preferences
    }

    // MARK: Contents

    func load() {
        searchText = ""
        closeTonePicker()
        rebuild()
        selectedIndex = 0
    }

    func reset() {
        searchText = ""
        sections = []
        flattened = []
        displayItems = []
        selectedIndex = 0
        closeTonePicker()
    }

    private func rebuild() {
        sections = Self.sections(
            query: searchText,
            index: index,
            recents: recents
        )
        flattened = sections.flatMap(\.emoji)
        displayItems = flattened.map { ResultDisplayItem(from: $0) }
        selectedIndex = 0
        closeTonePicker()
    }

    /// The grid's contents for a Query. Pure, so the layout rules are testable
    /// without a panel.
    static func sections(
        query: String,
        index: EmojiIndex,
        recents: EmojiRecents
    ) -> [Section] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            // The Recents section is omitted entirely when there are none —
            // an empty heading is worse than no heading.
            let recentEmoji = recents.resolved(in: index)
            let recentSection = recentEmoji.isEmpty
                ? []
                : [Section(title: "Recents", emoji: recentEmoji)]
            return recentSection + index.byGroup().map {
                Section(title: $0.group, emoji: $0.emoji)
            }
        }

        let matches = rank(index.all, query: trimmed, recents: recents)
        return matches.isEmpty ? [] : [Section(title: "Results", emoji: matches)]
    }

    // MARK: Ranking

    /// How well one Emoji answers a Query. Lower is better, `nil` is no match —
    /// the same convention `fuzzyScore` uses, because this is built out of it.
    ///
    /// The name carries full weight; keywords carry the same shape of score
    /// plus `keywordDiscount`; being in Recents takes `recentsBoost` off
    /// whatever came out. Recents can only improve an Emoji that already
    /// matched, so a Query never surfaces something irrelevant just because it
    /// was used once.
    static func score(_ emoji: Emoji, query: String, recentRank: Int?) -> Int? {
        var best = fuzzyScore(emoji.name, query)

        for keyword in emoji.keywords {
            guard let keywordScore = fuzzyScore(keyword, query) else { continue }
            let discounted = keywordScore + keywordDiscount
            if best == nil || discounted < best! { best = discounted }
        }

        guard var score = best else { return nil }
        if recentRank != nil { score = max(0, score - recentsBoost) }
        return score
    }

    /// Emoji that match, best first. Ties break towards Recents, then towards
    /// the canonical Unicode order, so the result is stable.
    static func rank(_ emoji: [Emoji], query: String, recents: EmojiRecents) -> [Emoji] {
        emoji.enumerated()
            .compactMap { offset, candidate -> (Emoji, Int, Int, Int)? in
                let recentRank = recents.rank(of: candidate)
                guard let score = score(candidate, query: query, recentRank: recentRank) else {
                    return nil
                }
                return (candidate, score, recentRank ?? Int.max, offset)
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                if $0.2 != $1.2 { return $0.2 < $1.2 }
                return $0.3 < $1.3
            }
            .map(\.0)
    }

    // MARK: Selection

    var selected: Emoji? {
        flattened.indices.contains(selectedIndex) ? flattened[selectedIndex] : nil
    }

    /// The Emoji as it would be pasted: the selection wearing either the tone
    /// the override picker is showing or the persisted default.
    var resolvedSelection: Emoji? {
        guard let selected else { return nil }
        return index.emoji(selected, in: effectiveTone)
    }

    var effectiveTone: SkinTone {
        if tonePickerEmoji != nil, SkinTone.allCases.indices.contains(toneIndex) {
            return SkinTone.allCases[toneIndex]
        }
        return preferences.defaultSkinTone
    }

    /// One cell left or right. Wraps across rows and sections, because reading
    /// order is what "next" means in a grid.
    func moveCell(_ delta: Int) {
        guard !flattened.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), flattened.count - 1)
    }

    /// One row up or down.
    ///
    /// Sections restart their rows, so a jump stays inside the current section
    /// until it runs out, then lands in the same column of the neighbouring
    /// section rather than skipping a screenful.
    func moveRow(_ delta: Int) {
        guard !flattened.isEmpty, let (section, offsetInSection) = position(of: selectedIndex) else {
            return
        }
        let columns = Self.columnCount
        let current = sections[section]
        let target = offsetInSection + delta * columns

        if current.emoji.indices.contains(target) {
            selectedIndex = start(of: section) + target
            return
        }

        let column = offsetInSection % columns
        if delta > 0, sections.indices.contains(section + 1) {
            let next = sections[section + 1]
            selectedIndex = start(of: section + 1) + min(column, next.emoji.count - 1)
        } else if delta < 0, sections.indices.contains(section - 1) {
            let previous = sections[section - 1]
            let lastRow = ((previous.emoji.count - 1) / columns) * columns
            selectedIndex = start(of: section - 1) + min(lastRow + column, previous.emoji.count - 1)
        } else {
            // Already in the first or last section: settle on its edge.
            selectedIndex = start(of: section) + (delta > 0 ? current.emoji.count - 1 : 0)
        }
    }

    /// Which section a flattened index falls in, and how far into it.
    func position(of flatIndex: Int) -> (section: Int, offset: Int)? {
        var remaining = flatIndex
        for (number, section) in sections.enumerated() {
            if remaining < section.emoji.count { return (number, remaining) }
            remaining -= section.emoji.count
        }
        return nil
    }

    /// Where a section begins in `flattened`.
    func start(of section: Int) -> Int {
        sections.prefix(section).reduce(0) { $0 + $1.emoji.count }
    }

    // MARK: Skin Tone override

    var isTonePickerOpen: Bool { tonePickerEmoji != nil }

    /// Opens the six-tone override for the selection, if tones apply to it.
    /// - Returns: whether it opened.
    @discardableResult
    func openTonePicker() -> Bool {
        guard let selected, index.hasSkinTones(selected) else { return false }
        tonePickerEmoji = selected
        toneIndex = preferences.defaultSkinTone.rawValue
        return true
    }

    func closeTonePicker() {
        tonePickerEmoji = nil
        toneIndex = 0
    }

    func moveTone(_ delta: Int) {
        guard isTonePickerOpen else { return }
        toneIndex = min(max(toneIndex + delta, 0), SkinTone.allCases.count - 1)
    }

    /// The six choices the override picker shows, each already in its own tone.
    var tonePickerChoices: [Emoji] {
        guard let tonePickerEmoji else { return [] }
        return SkinTone.allCases.map { index.emoji(tonePickerEmoji, in: $0) }
    }

    // MARK: Recents

    /// Notes that the selection was used. Records the base rather than
    /// `resolvedSelection`, so a toned pick makes the base recent and the tone
    /// comes back from the preference next time.
    func recordSelectionUse() {
        guard let selected else { return }
        recents.record(selected)
    }
}
