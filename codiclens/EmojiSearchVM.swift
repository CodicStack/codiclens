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

        /// Derived from the contents, and computed once when the section is
        /// built rather than on every diff.
        ///
        /// **Identity has to move when the contents do.** It used to be the
        /// title alone, and every Query produces a section called "Results" — so
        /// from a lazy container's point of view the section it was already
        /// showing was still the current one, and a `LazyVStack` that believes
        /// that is entitled to keep the cells it has already built. That is how
        /// a grid filtered to ten matches went on showing the previous Query's
        /// results while the Subject Card, reading `flattened` directly, showed
        /// the right one. Anything short of the whole contents — a count, a
        /// first element — leaves two different Queries able to collide.
        ///
        /// `Hasher` is seeded per process, so this is stable for as long as any
        /// diff cares about and deliberately not persisted.
        let id: String

        init(title: String, emoji: [Emoji]) {
            self.title = title
            self.emoji = emoji
            var hasher = Hasher()
            hasher.combine(title)
            for one in emoji { hasher.combine(one.string) }
            self.id = "\(title)#\(hasher.finalize())"
        }
    }

    // MARK: Ranking weights

    /// Keywords are a real signal but a weaker one than the name, so a keyword
    /// hit scores like a name hit of the same shape plus this. Small enough
    /// that an exact keyword ("hot" → 🔥) still beats a name match buried
    /// mid-word, large enough that it never beats a name that starts with the
    /// Query ("hot" → "hot dog").
    nonisolated static let keywordDiscount = 5

    /// What being in Recents is worth. Enough to lift a relevant Emoji past its
    /// equally-good neighbours, not enough to drag an irrelevant one into view —
    /// Recents only ever adjust an Emoji that already matched.
    nonisolated static let recentsBoost = 4

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

    /// The Emoji whose six-tone override picker is open, if one is.
    private(set) var tonePickerEmoji: Emoji?

    /// Index into `SkinTone.allCases` while the picker is open.
    var toneIndex: Int = 0

    /// The dataset, resolved the first time anything actually needs it.
    ///
    /// Deliberately not `EmojiIndex.shared` as a default argument. This view
    /// model is constructed with the `PanelController`, which happens while
    /// the app is launching — and reading `shared` there parsed a 226 KB
    /// JSON on the main thread before the first Panel could appear.
    /// `EmojiIndex.prewarm()` gets it decoded off-thread instead, and this only
    /// ever asks for it once Emoji Mode is being built.
    var index: EmojiIndex {
        if let resolvedIndex { return resolvedIndex }
        let shared = EmojiIndex.shared
        resolvedIndex = shared
        return shared
    }

    @ObservationIgnored private var resolvedIndex: EmojiIndex?

    let recents: EmojiRecents
    let preferences: EmojiPreferences

    /// - Parameters:
    ///   - index: the dataset to search. Nil means the bundled one, fetched
    ///     lazily; tests pass their own.
    ///   - recents, preferences: the app passes the shared ones, which live
    ///     in Application Support and `UserDefaults`; tests pass their own.
    init(
        index: EmojiIndex? = nil,
        recents: EmojiRecents,
        preferences: EmojiPreferences
    ) {
        self.resolvedIndex = index
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
    nonisolated static func score(_ emoji: Emoji, query: String, recentRank: Int?) -> Int? {
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
        scored(emoji, query: query, recents: recents.strings).map(\.emoji)
    }

    /// `rank`, keeping each Emoji's score, from a copy of the Recents rather
    /// than the store — so it can run off the main thread, which is where the
    /// list below the apps in Subject search ranks Emoji.
    nonisolated static func scored(
        _ emoji: [Emoji],
        query: String,
        recents: [String]
    ) -> [(emoji: Emoji, score: Int)] {
        let recentRanks = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return emoji.enumerated()
            .compactMap { offset, candidate -> (Emoji, Int, Int, Int)? in
                let recentRank = recentRanks[candidate.string]
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
            .map { (emoji: $0.0, score: $0.1) }
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

    /// An Emoji as the grid should draw it: wearing the tone in force.
    ///
    /// The grid drew untoned bases while the Subject Card drew
    /// `resolvedSelection` — the same Emoji wearing the tone in force — so
    /// anyone with a default tone set saw the Card showing a visibly different
    /// glyph from the cell they had highlighted, and reported it as the Card
    /// showing the wrong emoji. It was not wrong; the two surfaces were
    /// answering different questions.
    ///
    /// `effectiveTone`, the same one `resolvedSelection` uses, so there is
    /// exactly one tone on screen at a time and the highlighted cell is always
    /// the glyph the Card shows and Enter pastes. Choosing the *persisted*
    /// default here instead would be cheaper while the ⌥Enter picker is open,
    /// and would reintroduce a state where the Card and the cell disagree.
    ///
    /// Free when no tone is in force, which is the common case: applying
    /// `SkinTone.none` returns the Emoji unchanged without a lookup.
    ///
    /// Toning is presentation only. Selection, ordering and identity all stay
    /// with the base — a variant never becomes a Result of its own.
    func displayed(_ emoji: Emoji) -> Emoji {
        index.emoji(emoji, in: effectiveTone)
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
