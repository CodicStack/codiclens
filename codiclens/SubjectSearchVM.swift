import AppKit
import Combine

/// When the list below the apps is searched: on the keystroke, without
/// holding it up, and once typing pauses.
///
/// The app's is `LiveSearchSchedule`. A test hands in one that holds both
/// until the test runs them, so no test waits on a clock or races one.
protocol SearchSchedule: AnyObject {
    /// Runs `search` now, off the keystroke.
    func run(_ search: @escaping @MainActor () async -> Void)
    /// Runs `settle` once typing has paused, unless another keystroke asks
    /// first — then only the newest is run, once that one has paused.
    func afterPause(_ settle: @escaping @MainActor () -> Void)
}

/// A `Task` for the search, and a 120ms Combine debounce for the pause. The
/// debounce is right here, not a hack: it decides *when to ask* again, and
/// nothing on screen waits for it.
final class LiveSearchSchedule: SearchSchedule {
    private let typed = PassthroughSubject<@MainActor () -> Void, Never>()
    private var pause: AnyCancellable?

    init() {
        pause = typed
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { settle in settle() }
    }

    func run(_ search: @escaping @MainActor () async -> Void) {
        Task { await search() }
    }

    func afterPause(_ settle: @escaping @MainActor () -> Void) {
        typed.send(settle)
    }
}

@Observable
class SubjectSearchVM {
    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            queryChanged()
        }
    }
    var results: [Subject] = []
    var isSearchCommitted: Bool = false

    /// The highlighted row, which Enter acts on.
    ///
    /// Set from outside only by the user moving it, so setting it is what
    /// remembers the row by its id (`heldRow`): the list below the apps
    /// re-ranks while typing goes on, and a row the user moved onto by hand
    /// is followed there. Index 0 is the first row, which is where an
    /// untouched selection stays.
    var selectedIndex: Int {
        get { selection }
        set {
            selection = newValue
            heldRow = newValue == 0 ? nil : rowID(at: newValue)
        }
    }
    private var selection = 0

    /// The `ResultDisplayItem.id` of the row the user moved the selection
    /// onto by hand, or nil while it is on the first row. Cleared when that
    /// row leaves the list, and the selection goes back to the first row.
    @ObservationIgnored private var heldRow: String?

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
    /// Two answers: the apps on the keystroke, once the Index has landed, and
    /// the list below them a moment later, off the main actor. Until the list
    /// has answered *this* Query the one on screen answers an earlier one, so
    /// it says nothing about this one, and neither may "No results". A path
    /// has no list below it, and keeps the Index's gate alone.
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

    /// The list below the apps, as `answeredQuery` was answered. It stays
    /// while the next Query is out, so the list is never blanked between
    /// keystrokes, and is replaced in place when that answer lands — rows keep
    /// their ids (`ResultDisplayItem`), so they update rather than rebuild.
    private(set) var sourceResults: [SourceResult] = [] {
        didSet {
            sourceResultsBySubject = Dictionary(
                uniqueKeysWithValues: sourceResults.map { ($0.subject.id, $0) }
            )
        }
    }
    private var sourceResultsBySubject: [UUID: SourceResult] = [:]

    /// The Query `sourceResults` answer.
    private var answeredQuery: String?

    /// The Query the settled pass has answered, once it has: from then on a
    /// word search for it is dropped as it lands, so the list does not change
    /// again until the Query does.
    private var settledQuery: String?

    /// Bumped by every settled pass, so only the newest one lands.
    private var settleGeneration = 0

    /// The Query a keystroke's search of the list below the apps is waiting
    /// to run for, and whether one is out. One is out at a time, and a Query
    /// typed meanwhile replaces whatever was waiting: the File Index reader is
    /// one connection behind a lock, and a search can take half a second ("the "
    /// over a million Passages), so a search per keystroke would queue behind
    /// it and every answer but the last would be dropped as it landed.
    private var waitingQuery: String?
    private var isSearching = false

    private let sources: SourceStore
    private let history: ClipboardHistory
    private let emoji: EmojiSearchVM
    private let searchFiles: FileIndex.Search
    private let searchSettled: FileIndex.SettledSearch
    private let schedule: SearchSchedule

    private let commitSubject = PassthroughSubject<Void, Never>()
    private var commitCancellable: AnyCancellable?

    /// - Parameters:
    ///   - sources: which Sources are switched on. Read on every search, so a
    ///     switch thrown in Settings takes effect on the next keystroke.
    ///   - history, emoji: what the list below the apps ranks Clipboard Items
    ///     and Emoji from — the same history and dataset their own Modes use.
    ///   - searchFiles: the File Index's word search, on the keystroke. Tests
    ///     pass a stand-in.
    ///   - searchSettled: the File Index's settled search, once typing pauses,
    ///     where search by meaning joins. Tests pass a stand-in.
    ///   - schedule: when the list below the apps is searched. Tests pass one
    ///     they run by hand.
    init(
        index: AppIndex,
        sources: SourceStore,
        history: ClipboardHistory,
        emoji: EmojiSearchVM,
        searchFiles: @escaping FileIndex.Search,
        searchSettled: @escaping FileIndex.SettledSearch,
        schedule: SearchSchedule
    ) {
        self.index = index
        self.sources = sources
        self.history = history
        self.emoji = emoji
        self.searchFiles = searchFiles
        self.searchSettled = searchSettled
        self.schedule = schedule
        self.builtIns = Self.makeBuiltIns()

        // Starts the first scan on a background queue and begins watching.
        // Nothing about a cold start blocks here.
        index.start()

        commitCancellable = commitSubject
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.isSearchCommitted = true
            }

        index.onFirstPopulation { [weak self] in
            self?.indexFirstPopulated()
        }
    }

    /// The Index has landed for the very first time. Match the Query once.
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
        matchQuery()
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
    /// The Query has not changed, so the list below the apps is not asked
    /// again: an answer that landed while the text stood was kept for this.
    func withdrawText() {
        isSearchCommitted = false
        matchQuery()
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

    /// A keystroke: the apps now, and the list below them asked again — at
    /// once for its word matches, and once more when typing pauses.
    ///
    /// A path, and an empty Query, have no list below them: it goes.
    private func queryChanged() {
        isSearchCommitted = false
        settledQuery = nil
        guard !searchText.isEmpty, !isPathQuery else {
            sourceResults = []
            answeredQuery = nil
            waitingQuery = nil
            matchQuery()
            return
        }
        matchQuery()
        ask(searchText)
        schedule.afterPause { [weak self] in self?.settle() }
    }

    /// Runs the Query against the Index and puts the apps on top of the list
    /// below them as it stands.
    ///
    /// Called on a keystroke, on Escape from ⌘E's text and when the Index first
    /// lands — never on a later rebuild, which swaps the Index but does not
    /// come through here. Re-running the Query live would reshuffle the rows
    /// under the user's fingers and could move the selected row out from under
    /// Enter, launching the wrong app. The new Index takes effect on the next
    /// keystroke.
    private func matchQuery() {
        guard !searchText.isEmpty else {
            appResults = []
            results = []
            heldRow = nil
            selection = 0
            return
        }

        // A path is not an app search. `/` and `~` cannot begin an app name, so
        // the Index is never consulted and none of its gates move: the path
        // either names exactly one thing or it names nothing at all. No completion list, no directory
        // read — see `docs/adr/0008-a-file-can-be-a-subject.md`.
        if isPathQuery {
            appResults = []
            results = PathSubject.resolve(searchText).map { [$0] } ?? []
            heldRow = nil
            selection = 0
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
        compose()
        commitSubject.send()
    }

    /// The apps, then the list below them, and the selection where the user
    /// left it: on the row they moved onto by hand while it is still listed,
    /// otherwise on the first row.
    private func compose() {
        // An app the File Index also holds is already above, as an app.
        let appPaths = Set(appResults.compactMap(\.path))
        let below = sourceResults.filter { row in
            guard case .file(let file) = row.hit else { return true }
            return !appPaths.contains(file.url.path)
        }
        results = appResults + below.map(\.subject)

        let held = heldRow.flatMap { id in results.indices.first { rowID(at: $0) == id } }
        if held == nil { heldRow = nil }
        selection = held ?? 0
    }

    /// The id `displayResults` gives the row at `index`.
    private func rowID(at index: Int) -> String? {
        guard results.indices.contains(index) else { return nil }
        let subject = results[index]
        return sourceResult(for: subject)?.display.id ?? ResultDisplayItem(from: subject).id
    }

    /// Typing has paused on this Query: the settled pass.
    ///
    /// The File Index's settled search — the word search with the last word a
    /// prefix in Passages too, and with search by meaning on, meaning fused in
    /// (`FileIndex.searchSettled`) — ranked with the Clipboard Items and Emoji
    /// as the keystroke's answer is, re-ranks the list once. After that the
    /// list does not change until the Query does (`settledQuery`).
    ///
    /// It runs beside the keystroke's search, not behind it: it reads on a
    /// connection of its own, and the first one of a session waits for the
    /// query encoder, which must not hold up the next keystroke's words. Only
    /// the newest settled pass lands: the File Index answers one superseded
    /// or cancelled with nothing, and that nothing is not an answer.
    private func settle() {
        guard !searchText.isEmpty, !isPathQuery else { return }
        settleGeneration += 1
        let generation = settleGeneration
        let search = sourceSearch(searchText, files: searchSettled)
        schedule.run { [weak self] in
            let ranked = await search.ranked()
            guard let self, generation == settleGeneration else { return }
            land(ranked, for: search.query, settled: true)
        }
    }

    /// Asks for the list below the apps for `query`: now, if no search is
    /// out, or as soon as the one that is lands.
    private func ask(_ query: String) {
        waitingQuery = query
        guard !isSearching else { return }
        isSearching = true
        schedule.run { [weak self] in await self?.searchWhileAsked() }
    }

    /// Searches for the Query waiting until none is.
    private func searchWhileAsked() async {
        let words = searchFiles
        while let query = waitingQuery {
            waitingQuery = nil
            let search = sourceSearch(query, files: { query in words(query) })
            land(await search.ranked(), for: query)
        }
        isSearching = false
    }

    /// What the list below the apps ranks for `query`, with `files` as the
    /// File Index's part. Copied here, on the main actor; the File Index read
    /// and the ranking run off it (`SourceSearch.ranked`).
    private func sourceSearch(_ query: String, files: @escaping SourceSearch.FileSearch) -> SourceSearch {
        SourceSearch(
            query: query,
            searchFiles: files,
            clipboard: sources.isEnabled(.clipboardHistory) ? history.items.filter { !$0.isImage } : [],
            emoji: sources.isEnabled(.emoji) ? emoji.index.all : [],
            recentEmoji: emoji.recents.strings
        )
    }

    /// An answer for `query` replaces the list below the apps, if `query` is
    /// still the Query. One for a Query the user has typed past is dropped: it
    /// would put rows answering an older Query over the newer one's. So is a
    /// word answer for a Query the settled pass has already answered. A Query
    /// standing as text keeps standing; the answer is kept for Escape.
    private func land(_ ranked: [SourceSearch.Ranked], for query: String, settled: Bool = false) {
        guard query == searchText, settled || settledQuery != query else { return }
        if settled { settledQuery = query }
        answeredQuery = query
        sourceResults = ranked.map { row(for: $0.hit) }
        if !standsAsText { compose() }
    }

    private func row(for hit: SourceSearch.Hit) -> SourceResult {
        switch hit {
        case .file(let file):
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
                thumbnailURL: file.kind == .file ? file.url : nil,
                passage: file.passage.map(SubjectPassage.init)
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
        settledQuery = nil
        waitingQuery = nil
        selectedIndex = 0
        isSearchCommitted = false
    }
}
