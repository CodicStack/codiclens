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
            filteredItems = ClipboardManager.shared.items.filter { item in
                fuzzyScore(item.displayName, searchText) != nil
            }
        }
        selectedIndex = 0
    }

    func reset() {
        searchText = ""
        filteredItems = []
        selectedIndex = 0
    }
}
