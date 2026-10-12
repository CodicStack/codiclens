import Foundation

@Observable
class ClipboardSearchVM {
    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            filterItems()
        }
    }
    var selectedIndex: Int = 0

    private(set) var filteredItems: [ClipboardItem] = []

    private let history: ClipboardHistory

    init(history: ClipboardHistory) {
        self.history = history
    }

    func load() {
        searchText = ""
        filteredItems = history.items
        selectedIndex = 0
    }

    /// Re-reads the history under the Query in force, keeping the selection's
    /// place rather than its item. After a removal that selects the row that
    /// took the removed one's place, or the new last row if it was last.
    /// `load()` is the other one: a fresh browser, Query cleared.
    func reload() {
        let index = selectedIndex
        filterItems()
        selectedIndex = min(index, max(filteredItems.count - 1, 0))
    }

    private func filterItems() {
        if searchText.isEmpty {
            filteredItems = history.items
        } else {
            filteredItems = Self.scored(history.items, query: searchText).map(\.item)
        }
        selectedIndex = 0
    }

    /// The Clipboard Items that match `query`, best first, with their
    /// `fuzzyScore`. The one matching rule for Clipboard History: this browser
    /// and the list below the apps in Subject search both use it.
    nonisolated static func scored(_ items: [ClipboardItem], query: String) -> [(item: ClipboardItem, score: Int)] {
        items
            .compactMap { item -> (item: ClipboardItem, score: Int)? in
                guard let score = fuzzyScore(item.displayName, query) else { return nil }
                return (item, score)
            }
            .sorted { $0.score < $1.score }
    }

    /// An image item's stored PNG — what its row's thumbnail and the Subject
    /// Card's preview are drawn from.
    func imageURL(for item: ClipboardItem) -> URL? {
        history.imageURL(for: item)
    }

    func reset() {
        searchText = ""
        filteredItems = []
        selectedIndex = 0
    }
}
