import AppKit

@Observable
class ActionSearchVM {
    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            filterActions()
        }
    }
    var selectedIndex: Int = 0

    private(set) var allActions: [SubjectAction] = []
    private(set) var filteredActions: [SubjectAction] = []

    func loadActions(for subject: Subject) {
        searchText = ""
        allActions = SubjectAction.actions(for: subject)
        filteredActions = allActions
        selectedIndex = 0
    }

    private func filterActions() {
        if searchText.isEmpty {
            filteredActions = allActions
        } else {
            filteredActions = allActions.filter { action in
                fuzzyScore(action.name, searchText) != nil
            }
        }
        selectedIndex = 0
    }

    func reset() {
        searchText = ""
        allActions = []
        filteredActions = []
        selectedIndex = 0
    }
}
