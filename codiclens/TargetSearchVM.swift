import AppKit
import Combine
import os

@Observable
class TargetSearchVM {
    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            if isFileSearchMode {
                // The running search answers a Query that is already gone;
                // stop its `mdfind` now rather than when the debounce lands.
                cancelFileSearch()
                fileSearchSubject.send(searchText)
            } else {
                filterTargets()
            }
        }
    }
    var selectedIndex: Int = 0
    var isSearching: Bool = false

    var allTargets: [ActionTarget] = []
    var filteredTargets: [ActionTarget] = []

    private var isFileSearchMode = false
    private let fileSearchSubject = PassthroughSubject<String, Never>()
    private let shareTargetProvider: @MainActor (Payload) -> [ActionTarget]
    nonisolated private let searchFiles: FileIndex.Search
    nonisolated private let fileSearchLauncher: FileTargetSearch.Launcher
    private var cancellable: AnyCancellable?
    /// The file search in flight, if any. Cancelled — its `mdfind`s
    /// terminated — by the next keystroke and by leaving file search.
    private(set) var fileSearch: FileTargetSearch?

    /// - Parameter searchFiles: the File Index, asked before `mdfind`.
    init(
        shareTargetProvider: @escaping @MainActor (Payload) -> [ActionTarget] = {
            ActionTarget.shareTargets(for: $0)
        },
        searchFiles: @escaping FileIndex.Search,
        fileSearchLauncher: @escaping FileTargetSearch.Launcher = FileTargetSearch.mdfind
    ) {
        self.shareTargetProvider = shareTargetProvider
        self.searchFiles = searchFiles
        self.fileSearchLauncher = fileSearchLauncher
        cancellable = fileSearchSubject
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] text in
                self?.performFileSearch(text)
            }
    }

    func loadTargets(for subject: Subject, action: SubjectAction) {
        leaveFileSearchMode()
        searchText = ""

        // "Use as Subject" finds a file or an app the same way Finder's own
        // Actions do — the same `mdfind` Target list, reached from a different
        // Subject. One rule rather than a Finder special case; see
        // `docs/adr/0008-a-file-can-be-a-subject.md`.
        if case .useAsSubject = action.handler {
            isFileSearchMode = true
            allTargets = []
            filteredTargets = []
            selectedIndex = 0
            return
        }

        if case .app(let bundleId, _) = subject.kind, bundleId == "com.apple.finder" {
            isFileSearchMode = true
            allTargets = []
            filteredTargets = []
            selectedIndex = 0
            return
        }

        // Share is deliberately absent: its Targets come from the *Payload*,
        // not the Subject — a Clipboard Image shares as its stored PNG and a
        // Clipboard Item has no URL of its own — and only the coordinator can
        // resolve one. It calls `loadShareTargets` instead.
        switch action.handler {
        case .openWith:
            allTargets = ActionTarget.openWithTargets(for: subject)
        default:
            allTargets = []
        }
        filteredTargets = allTargets
        selectedIndex = 0
    }

    /// The Targets a Share Payload has. Every Share comes through here —
    /// `CommandCoordinator` decides what a Subject shares as, because a
    /// Clipboard Item's content lives in the history rather than in the
    /// Subject.
    func loadShareTargets(for payload: Payload) {
        leaveFileSearchMode()
        searchText = ""
        allTargets = shareTargetProvider(payload)
        filteredTargets = allTargets
        selectedIndex = 0
    }

    /// Runs the debounced Query. Internal so tests can start a search
    /// without waiting out the debounce.
    func performFileSearch(_ text: String) {
        guard isFileSearchMode, searchText == text else { return }
        cancelFileSearch()

        guard !text.isEmpty else {
            filteredTargets = []
            selectedIndex = 0
            isSearching = false
            return
        }

        let queryText = text
        let search = FileTargetSearch(query: queryText, searchFiles: searchFiles, launcher: fileSearchLauncher)
        fileSearch = search
        isSearching = true

        // Two answers, in order. The File Index's lands first and is shown at
        // once, still "searching"; Spotlight's lands below it, so nothing on
        // screen moves and the selection stays where the user put it.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let indexed = search.indexTargets()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(search) else { return }
                self.filteredTargets = indexed
                self.selectedIndex = 0
            }

            guard let rest = search.spotlightTargets(excluding: indexed) else { return }

            let signposter = FileTargetSearch.signposter
            let hop = signposter.beginInterval("Main hop", id: signposter.makeSignpostID())
            DispatchQueue.main.async { [weak self] in
                signposter.endInterval("Main hop", hop)
                guard let self, self.isCurrent(search) else { return }
                if self.fileSearch === search { self.fileSearch = nil }
                self.filteredTargets = indexed + rest
                self.isSearching = false
            }
        }
    }

    /// Whether `search` still answers the Query on screen: file search is
    /// still the Target source, the Query has not moved on, and nothing has
    /// cancelled it.
    private func isCurrent(_ search: FileTargetSearch) -> Bool {
        isFileSearchMode && searchText == search.query && !search.isCancelled
    }

    private func filterTargets() {
        if searchText.isEmpty {
            filteredTargets = allTargets
        } else {
            filteredTargets = allTargets.filter { target in
                fuzzyScore(target.name, searchText) != nil
            }
        }
        selectedIndex = 0
    }

    func reset() {
        leaveFileSearchMode()
        searchText = ""
        allTargets = []
        filteredTargets = []
        selectedIndex = 0
    }

    /// Revokes file search before another Target source takes ownership.
    /// Queued debounce and completion handlers check this mode before writing.
    private func leaveFileSearchMode() {
        isFileSearchMode = false
        isSearching = false
        cancelFileSearch()
    }

    private func cancelFileSearch() {
        fileSearch?.cancel()
        fileSearch = nil
    }
}
