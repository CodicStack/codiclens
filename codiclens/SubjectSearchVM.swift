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
    var isSearchCommitted: Bool = false

    /// The Index of installed apps. This view model consumes it and never
    /// builds it — rebuilds happen behind `AppIndex`.
    private let index: AppIndex

    /// Whether the Index has answered at all yet.
    ///
    /// The first scan runs on a background queue, so for the first moment of
    /// the app's life `index.apps` is empty — not because nothing is installed
    /// but because nobody has looked. A Query run against that Index has not
    /// been answered; it has not been *asked*. Everything that would otherwise
    /// treat zero matches as an answer — the "No results" row, the Card's "No
    /// match" and the shake — waits on this.
    ///
    /// Exposed rather than letting a view reach through to `AppIndex.shared`:
    /// the Index this view model searches is the one it was handed, and a test
    /// hands it a different one.
    var isIndexReady: Bool { index.hasPopulated }

    /// Whether this Query is a path rather than an app search.
    ///
    /// `/` and `~` and nothing else — see `PathSubject`. The prefixes were
    /// chosen because they cannot begin an app name, which is what lets a Path
    /// Subject sit alongside the Index without touching any of its gates.
    var isPathQuery: Bool { PathSubject.isPath(searchText) }

    /// Whether the Query stands as a text Subject.
    ///
    /// Only ⌘E does that — zero matches is "No results" and never a text
    /// Subject, see `docs/adr/0012-files-in-subject-search-text-mode-is-cmd-e.md`.
    var standsAsText: Bool {
        guard selectedIndex < results.count, case .text = results[selectedIndex].kind else { return false }
        return true
    }

    /// Whether the Query has been answered in full, which is what "No
    /// results" and the Card's "No match" wait on.
    ///
    /// Two answers, arriving at two moments: the apps on the keystroke, once
    /// the Index has landed, and the list below them once typing pauses
    /// (`searchSources`). Saying "No results" between the two would be the
    /// "No results, then it changes its mind" defect again, so the claim waits
    /// for both. A path has no list below it, and keeps the Index's gate alone.
    var hasAnswered: Bool {
        guard isIndexReady else { return false }
        return isPathQuery || answeredQuery == searchText
    }

    /// Whether this Query was answered with nothing.
    ///
    /// The state the Panel shakes about. A Query standing as text after ⌘E
    /// still matched nothing, so it does not shake a second time.
    ///
    /// A path is answered by the filesystem, synchronously and completely, so
    /// it needs no Index gate: `~/nope` names nothing the instant the key
    /// lands. Anything else is a no-match once the apps *and* the list below
    /// them have answered with nothing.
    var hasNoMatch: Bool {
        guard !searchText.isEmpty else { return false }
        if isPathQuery { return results.isEmpty }
        return hasAnswered && appResults.isEmpty && sourceResults.isEmpty
    }

    /// Built-ins live here, not in the Index: they aren't files on disk, and a
    /// rebuild must not be able to drop them.
    private let builtIns: [Subject]

    /// Up to five apps and Built-ins: the part of the list that answers on the
    /// keystroke, and that nothing below it may move.
    private var appResults: [Subject] = []

    /// A row of the list below the apps: the Subject Enter and Tab act on, and
    /// the row that says which Source it came from.
    struct SourceResult {
        let hit: SourceSearch.Hit
        let subject: Subject
        let display: ResultDisplayItem

        /// The Emoji as the dataset has it, before any Skin Tone: what Recents
        /// record when the row is used.
        var emojiBase: Emoji? {
            if case .emoji(let base) = hit { return base }
            return nil
        }
    }

    /// The list below the apps, for `answeredQuery`. Empty until the pause,
    /// and emptied again the moment the Query changes: a list answering the
    /// previous Query is not an answer to this one.
    private(set) var sourceResults: [SourceResult] = [] {
        didSet {
            sourceResultsBySubject = Dictionary(
                uniqueKeysWithValues: sourceResults.map { ($0.subject.id, $0) }
            )
        }
    }
    private var sourceResultsBySubject: [UUID: SourceResult] = [:]

    /// The Query `sourceResults` answer. The list lands once per Query and is
    /// never ranked again until the Query changes — ADR 0012, and ADR 0004's
    /// rule that rows do not move under the user.
    private var answeredQuery: String?

    private let sources: SourceStore
    private let history: ClipboardHistory
    private let emoji: EmojiSearchVM
    private let searchFiles: FileIndex.Search

    private let commitSubject = PassthroughSubject<Void, Never>()
    private var commitCancellable: AnyCancellable?
    private let sourceSearchSubject = PassthroughSubject<Void, Never>()
    private var sourceSearchCancellable: AnyCancellable?

    /// - Parameters:
    ///   - sources: which Sources are switched on. Read on every search, so a
    ///     switch thrown in Settings takes effect on the next keystroke.
    ///   - history, emoji: what the list below the apps ranks Clipboard Items
    ///     and Emoji from — the same history and dataset their own Modes use.
    ///   - searchFiles: the File Index. Tests pass a stand-in.
    init(
        index: AppIndex,
        sources: SourceStore,
        history: ClipboardHistory,
        emoji: EmojiSearchVM,
        searchFiles: @escaping FileIndex.Search
    ) {
        self.index = index
        self.sources = sources
        self.history = history
        self.emoji = emoji
        self.searchFiles = searchFiles
        self.builtIns = Self.makeBuiltIns()

        // Starts the first scan on a background queue and begins watching.
        // Nothing about a cold start blocks here.
        index.start()

        commitCancellable = commitSubject
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.isSearchCommitted = true
            }

        // The list below the apps lands once typing pauses. A debounce is
        // right here, not a hack: it decides *when to ask*, and nothing is
        // shown in the meantime that has to be taken back.
        sourceSearchCancellable = sourceSearchSubject
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] in
                Task { await self?.searchSources() }
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
    /// all, so whatever is on screen is the Built-ins at most: an app search
    /// that could not run yet. Re-running it destroys nothing — unless the user
    /// has already turned the Query into text with ⌘E, which is a choice.
    ///
    /// Every later rebuild is exactly the case the rule is about. Do not
    /// "simplify" this into an unconditional observer of `AppIndex.apps`.
    private func indexFirstPopulated() {
        guard !searchText.isEmpty, !standsAsText else { return }
        updateResults()
    }

    /// ⌘E: the Query, or what the user edited it into, stands as a text
    /// Subject and the only Result, until the next keystroke searches again.
    ///
    /// The search counts as settled, so that keystroke starts a new Query
    /// rather than extending this one: the text was written in the editor, not
    /// in the Query.
    func standAsText(_ subject: Subject) {
        results = [subject]
        selectedIndex = 0
        isSearchCommitted = true
    }

    /// Escape on a Query standing as text: back to what the Query matched.
    /// The Query has not changed, so neither has the list below the apps.
    func withdrawText() {
        updateResults()
    }

    /// The row of the list below the apps that `subject` is, if it is one.
    func sourceResult(for subject: Subject) -> SourceResult? {
        sourceResultsBySubject[subject.id]
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
        isSearchCommitted = false

        if answeredQuery != searchText {
            answeredQuery = nil
            sourceResults = []
        }

        guard !searchText.isEmpty else {
            appResults = []
            results = []
            selectedIndex = 0
            return
        }

        // A path is not an app search. `/` and `~` cannot begin an app name, so
        // the Index is never consulted and none of its gates move: the path
        // either names exactly one thing or it names nothing at all. No completion list, no directory
        // read — see `docs/adr/0008-a-file-can-be-a-subject.md`.
        if isPathQuery {
            appResults = []
            results = PathSubject.resolve(searchText).map { [$0] } ?? []
            selectedIndex = 0
            commitSubject.send()
            return
        }

        var scored: [(Candidate, Int)] = []
        if sources.isEnabled(.applications) {
            for app in index.apps {
                guard let score = fuzzyScore(app.displayName, searchText) else { continue }
                scored.append((.app(app), score))
            }
        }
        if sources.isEnabled(.builtIns) {
            for subject in builtIns {
                guard let score = fuzzyScore(subject.displayName, searchText) else { continue }
                scored.append((.builtIn(subject), score))
            }
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

        // Zero matches is "No results", never a text Subject. Text is something
        // the user asks for, with ⌘E — `standAsText`.
        results = appResults + sourceResults.map(\.subject)
        selectedIndex = 0

        commitSubject.send()
        if answeredQuery != searchText { sourceSearchSubject.send() }
    }

    /// The debounced step: the list below the apps, for the Query in force.
    /// Internal so a test can run it without waiting out the debounce.
    ///
    /// What it ranks is copied here, on the main actor; the File Index read
    /// and the ranking run off it (`SourceSearch.ranked`). The answer is kept
    /// only if the Query is still the one it was asked for and nothing has
    /// answered that Query yet — so it lands once, and the rows above it, the
    /// apps, do not move. A Query standing as text keeps standing: the answer
    /// is kept for Escape to come back to.
    func searchSources() async {
        let query = searchText
        guard !query.isEmpty, !isPathQuery, answeredQuery != query else { return }

        let search = SourceSearch(
            query: query,
            searchFiles: searchFiles,
            clipboard: sources.isEnabled(.clipboardHistory) ? history.items.filter { !$0.isImage } : [],
            emoji: sources.isEnabled(.emoji) ? emoji.index.all : [],
            recentEmoji: emoji.recents.strings
        )
        let ranked = await search.ranked()

        guard searchText == query, answeredQuery != query else { return }
        answeredQuery = query
        // An app the File Index also holds is already above, as an app.
        let appPaths = Set(appResults.compactMap(\.path))
        sourceResults = ranked.compactMap { row(for: $0.hit, skipping: appPaths) }
        if !standsAsText {
            results = appResults + sourceResults.map(\.subject)
        }
    }

    private func row(for hit: SourceSearch.Hit, skipping appPaths: Set<String>) -> SourceResult? {
        switch hit {
        case .file(let file):
            guard !appPaths.contains(file.url.path) else { return nil }
            // The type's icon, not the file's: one cached lookup per type
            // instead of a disk read per row. The thumbnail replaces it, and
            // choosing the row resolves the file in full (`PathSubject`).
            let icon = NSWorkspace.shared.icon(for: file.contentType)
            icon.size = NSSize(width: 32, height: 32)
            let subject = Subject(
                displayName: file.name,
                path: file.url.path,
                url: file.url,
                icon: icon,
                kind: file.kind == .folder ? .folder : .file(contentType: file.contentType),
                thumbnailURL: file.kind == .file ? file.url : nil
            )
            return SourceResult(hit: hit, subject: subject, display: ResultDisplayItem(file: file, icon: icon))

        case .clipboard(let item):
            let imageURL = history.imageURL(for: item)
            return SourceResult(
                hit: hit,
                subject: Subject(clipboardItem: item, imageURL: imageURL),
                display: ResultDisplayItem(clipboardResult: item, imageURL: imageURL)
            )

        case .emoji(let base):
            // Drawn and inserted in the default tone, as Emoji Mode would.
            let toned = emoji.index.emoji(base, in: emoji.preferences.defaultSkinTone)
            return SourceResult(
                hit: hit,
                subject: Subject(emoji: toned),
                display: ResultDisplayItem(emoji: toned, base: base)
            )
        }
    }

    func reset() {
        searchText = ""
        results = []
        appResults = []
        sourceResults = []
        answeredQuery = nil
        selectedIndex = 0
        isSearchCommitted = false
    }
}
