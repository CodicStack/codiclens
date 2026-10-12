import Foundation

/// The shape every search phase shares: a query, an ordered list of results,
/// and a selection into them.
///
/// `CommandCoordinator` resolves the current phase to one scope, instead of
/// switching on phase inside every accessor. Adding a phase means adding an
/// adapter below and one line in `CommandCoordinator.currentScope`.
protocol SearchScope: AnyObject {
    var searchText: String { get set }
    var selectedIndex: Int { get set }

    /// Results as the results list renders them. Each adapter decides what its
    /// own results are — including whether it currently has any to show.
    var displayResults: [ResultDisplayItem] { get }

    func reset()
}

// MARK: - Adapters

extension SubjectSearchVM: SearchScope {
    /// Every match, as soon as there is one.
    ///
    /// These used to be withheld for 600ms after each keystroke by a debounced
    /// visibility flag, to stop the list "flickering". What it actually did was
    /// hold an answer the app already had: with the Slab showing and no Results
    /// in it, the only thing left to draw was the "No results" row — so every
    /// search said *no* for six-tenths of a second and then changed its mind.
    /// That is the whole of the reported defect, and a debounce cannot fix it
    /// because a debounce is what it is.
    ///
    /// The list below the apps answers a moment after the keystroke, off the
    /// main actor, and is not withheld either: until a Query's own answer lands
    /// the previous one stays, and "No results" waits for it (`hasAnswered`).
    /// Its rows carry their own display, which names the Source each came
    /// from.
    var displayResults: [ResultDisplayItem] {
        results.map { sourceResult(for: $0)?.display ?? ResultDisplayItem(from: $0) }
    }
}

extension ActionSearchVM: SearchScope {
    var displayResults: [ResultDisplayItem] {
        filteredActions.map { ResultDisplayItem(from: $0) }
    }
}

extension TargetSearchVM: SearchScope {
    var displayResults: [ResultDisplayItem] {
        filteredTargets.map { ResultDisplayItem(from: $0) }
    }
}

extension ClipboardSearchVM: SearchScope {
    var displayResults: [ResultDisplayItem] {
        filteredItems.map { ResultDisplayItem(from: $0, imageURL: imageURL(for: $0)) }
    }
}

extension EmojiSearchVM: SearchScope {
    /// **Empty on purpose.** In grid Mode a Result is a cell, not a row, and the
    /// cells are `EmojiGridView` reading `sections` — nothing renders a list of
    /// Emoji anywhere.
    ///
    /// This used to return a built list, maintained on every keystroke, and with
    /// an empty Query that is all 1,914 Emoji: an `NSImage` and a fresh `UUID`
    /// each, on the main thread, for rows that were never drawn. Neither of the
    /// two things that ask a scope whether it has results needs an answer here —
    /// the Results Slab is unconditional in Emoji Mode because the grid is never
    /// empty, and row navigation goes through `emojiVM.moveRow`.
    var displayResults: [ResultDisplayItem] { [] }
}
