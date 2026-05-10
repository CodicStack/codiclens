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

    func load() {
        searchText = ""
        filteredItems = ClipboardManager.shared.items
        selectedIndex = 0
    }

    private func filterItems() {
        if searchText.isEmpty {
            filteredItems = ClipboardManager.shared.items
        } else {
            filteredItems = ClipboardManager.shared.items
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
