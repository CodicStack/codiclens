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

    private func filterItems() {
        if searchText.isEmpty {
            filteredItems = history.items
        } else {
            filteredItems = history.items
                .compactMap { item -> (ClipboardItem, Int)? in
                    guard let score = fuzzyScore(item.displayName, searchText) else { return nil }
                    return (item, score)
                }
                .sorted { $0.1 < $1.1 }
                .map { $0.0 }
        }
        selectedIndex = 0
    }

    func reset() {
        searchText = ""
        filteredItems = []
        selectedIndex = 0
    }
}
