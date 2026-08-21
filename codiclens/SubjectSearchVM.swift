import AppKit
import Combine

@Observable
class SubjectSearchVM {
    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            updateResults()
        }
    }
    var results: [Subject] = []
    var selectedIndex: Int = 0
    var isResultsVisible: Bool = false
    var isSearchCommitted: Bool = false

    /// The Index of installed apps. This view model consumes it and never
    /// builds it — rebuilds happen behind `AppIndex`.
    private let index: AppIndex

    /// Built-ins live here, not in the Index: they aren't files on disk, and a
    /// rebuild must not be able to drop them.
    private let builtIns: [Subject]

    private var appResults: [Subject] = []

    private let visibilitySubject = PassthroughSubject<Void, Never>()
    private let commitSubject = PassthroughSubject<Void, Never>()
    private var visibilityCancellable: AnyCancellable?
    private var commitCancellable: AnyCancellable?

    init(index: AppIndex = .current) {
        self.index = index
        self.builtIns = Self.makeBuiltIns()

        // Starts the first scan on a background queue and begins watching.
        // Nothing about a cold start blocks here.
        index.start()

        visibilityCancellable = visibilitySubject
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.isResultsVisible = true
            }

        commitCancellable = commitSubject
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.isSearchCommitted = true
            }

        index.onFirstPopulation { [weak self] in
            self?.indexFirstPopulated()
        }
    }

    /// The Index has landed for the very first time. Re-run the Query once.
    ///
    /// This is not an exception to the mid-search rule below — it sits outside
    /// it. That rule protects Results the user can see and has selected into:
    /// reshuffling them can move the selected row out from under Enter and
    /// launch the wrong app. Before the first scan lands there is no Index at
    /// all, so whatever is on screen is the text-mode fallback: a Subject the
    /// user never chose, standing in for an app search that could not run yet.
    /// Replacing it destroys nothing.
    ///
    /// Every later rebuild is exactly the case the rule is about. Do not
    /// "simplify" this into an unconditional observer of `AppIndex.apps`, and
    /// do not widen the condition to "the visible result is a text Subject" —
    /// that also matches a genuine no-match, which is a state the user is
    /// entitled to sit in.
    private func indexFirstPopulated() {
        guard !searchText.isEmpty else { return }
        updateResults()
    }

    /// Rebuilds the Index by hand. The Settings UI calls this; search picks the
    /// new Index up on the next keystroke.
    func refreshIndex() {
        index.refresh()
    }

    private static func makeBuiltIns() -> [Subject] {
        [
            builtIn(name: "Settings", symbol: "gear", kind: .builtIn(.settings)),
            builtIn(name: "Clipboard", symbol: "clipboard", kind: .builtIn(.clipboard)),
            Subject.emojiBuiltIn
        ]
    }

    private static func builtIn(name: String, symbol: String, kind: SubjectKind) -> Subject {
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        icon.size = NSSize(width: 32, height: 32)
        return Subject(displayName: name, path: nil, url: nil, icon: icon, kind: kind)
    }

    /// A match before it becomes a Subject. Apps stay iconless until they make
    /// the top five.
    private enum Candidate {
        case app(IndexedApp)
        case builtIn(Subject)

        var displayName: String {
            switch self {
            case .app(let app): app.displayName
            case .builtIn(let subject): subject.displayName
            }
        }
    }

    /// Runs the Query against the Index.
    ///
    /// Called only from `searchText`'s `didSet` — a rebuild that lands while
    /// results are on screen swaps the Index but does not come through here.
    /// Re-running the Query live would reshuffle the rows under the user's
    /// fingers and could move the selected row out from under Enter, launching
    /// the wrong app. The new Index takes effect on the next keystroke.
    private func updateResults() {
        isResultsVisible = false
        isSearchCommitted = false

        guard !searchText.isEmpty else {
            appResults = []
            results = []
            selectedIndex = 0
            return
        }

        var scored: [(Candidate, Int)] = []
        for app in index.apps {
            guard let score = fuzzyScore(app.displayName, searchText) else { continue }
            scored.append((.app(app), score))
        }
        for subject in builtIns {
            guard let score = fuzzyScore(subject.displayName, searchText) else { continue }
            scored.append((.builtIn(subject), score))
        }

        appResults = scored
            .sorted { $0.1 < $1.1 }
            .prefix(5)
            .map { candidate, _ in
                switch candidate {
                case .app(let app): index.subject(for: app)
                case .builtIn(let subject): subject
                }
            }

        if appResults.isEmpty {
            results = [Subject(text: searchText)]
        } else {
            results = appResults
        }
        selectedIndex = 0

        visibilitySubject.send()
        commitSubject.send()
    }

    func reset() {
        searchText = ""
        results = []
        appResults = []
        selectedIndex = 0
        isResultsVisible = false
        isSearchCommitted = false
    }
}
