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
    /// Subject results stay hidden until the debounced visibility gate opens,
    /// so the dropdown doesn't flicker on every keystroke.
    var displayResults: [ResultDisplayItem] {
        isResultsVisible ? results.map { ResultDisplayItem(from: $0) } : []
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
        filteredItems.map { ResultDisplayItem(from: $0) }
    }
}
