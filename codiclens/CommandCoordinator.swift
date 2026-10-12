import AppKit
import UniformTypeIdentifiers

@Observable
class CommandCoordinator {
    enum Phase: Equatable {
        case searchingSubject
        case browsingClipboard
        case browsingEmoji
        case pickingAction
        case pickingTarget
        case showingResult(String)
    }

    var phase: Phase = .searchingSubject {
        didSet {
            // The Last Subject stands in the Subject search the Panel opened
            // on, and in the Actions Tab opened from there. Any other Phase is
            // somewhere else, and Shift+Tab must not bring it back.
            if phase != .searchingSubject && phase != .pickingAction {
                isLastSubjectStanding = false
            }
            if phase == .browsingClipboard || phase == .browsingEmoji {
                isSubjectFromSearch = false
            }
            // A failed Move or Rename is about the Phase it failed in, and so
            // is a Transcribe that came to nothing.
            if phase != oldValue {
                fileOperationFailure = nil
                transcriptionFailure = nil
                momentOpenFailed = false
                // The preview is of the Phase's Subject, and Tab or Shift+Tab
                // moves on from it.
                passagePreview = nil
            }
            // A transcript can only land on the Actions of the file it is
            // for. Leaving them, by any route, stops the command rather than
            // let it run on for an answer that would be dropped.
            if phase != .pickingAction { cancelTranscription() }
        }
    }

    /// Whether the Subject was chosen from Subject search's Results, so
    /// Shift+Tab from its Actions goes back there. A Clipboard Item or an Emoji
    /// chosen from the list below the apps would otherwise be sent to the
    /// Clipboard browser or the Emoji grid, which it never came from.
    private var isSubjectFromSearch = false
    var focusTrigger: Bool = false

    private(set) var selectedSubject: Subject?
    private(set) var selectedAction: SubjectAction?

    /// The clipboard entry being acted on, when the selected subject is one.
    var selectedClipboardItem: ClipboardItem? { selectedSubject?.clipboardItem }

    let subjectVM: SubjectSearchVM
    let actionVM = ActionSearchVM()
    let targetVM: TargetSearchVM
    let clipboardVM: ClipboardSearchVM
    let emojiVM: EmojiSearchVM
    let queryBuffer = QueryBuffer()

    /// Layout only — the card panel resizes when the phase changes.
    var onPhaseChange: (() -> Void)?

    private let runner: EffectRunner
    private let history: ClipboardHistory
    private let sources: SourceStore

    /// Everything that reaches the user's own data is a parameter without a
    /// default: `PanelController` hands in the shared ones, and a test that
    /// forgot one does not compile rather than read the real thing.
    ///
    /// - Parameters:
    ///   - emojiVM: injected so tests get their own Recents and preferences
    ///     instead of the ones in Application Support.
    ///   - index: the app Index Subject search matches against. Tests pass an
    ///     Index over no directories, so no test scans `/Applications` or
    ///     starts an FSEvents stream.
    ///   - sources: the Sources and their switches.
    ///   - searchFiles: the File Index, read by Subject search and by Finder's
    ///     Target list. Tests pass a stand-in.
    ///   - searchSettled: the File Index's settled search, where search by
    ///     meaning joins Subject search once typing pauses. Tests pass a
    ///     stand-in.
    ///   - searchSchedule: when Subject search asks for the list below the
    ///     apps. Tests pass one they run by hand.
    init(
        runner: EffectRunner,
        history: ClipboardHistory,
        emojiVM: EmojiSearchVM,
        index: AppIndex,
        sources: SourceStore,
        searchFiles: @escaping FileIndex.Search,
        searchSettled: @escaping FileIndex.SettledSearch,
        searchSchedule: SearchSchedule = LiveSearchSchedule()
    ) {
        self.runner = runner
        self.history = history
        self.sources = sources
        self.clipboardVM = ClipboardSearchVM(history: history)
        self.emojiVM = emojiVM
        self.subjectVM = SubjectSearchVM(
            index: index,
            sources: sources,
            history: history,
            emoji: emojiVM,
            searchFiles: searchFiles,
            searchSettled: searchSettled,
            schedule: searchSchedule
        )
        self.targetVM = TargetSearchVM(searchFiles: searchFiles)
    }

    var cardCount: Int {
        switch phase {
        case .searchingSubject, .browsingClipboard, .browsingEmoji: 1
        case .pickingAction, .showingResult: 2
        case .pickingTarget: 3
        }
    }

    var isClipboardBrowsing: Bool {
        phase == .browsingClipboard
    }

    /// Whether the Results Slab should be a grid rather than a list.
    var isEmojiBrowsing: Bool {
        phase == .browsingEmoji
    }

    /// Whether the Query stands as a text Subject, which only ⌘E does.
    var isTextMode: Bool { subjectVM.standsAsText }

    // MARK: - Last Subject

    /// The Clipboard Item or Emoji the user last acted on (`GLOSSARY.md`,
    /// **Last Subject**). In memory only: it outlives the Panel, not the app.
    private(set) var lastSubject: Subject?

    /// Whether the Last Subject is standing as the Subject: the Panel opened on
    /// it and nothing has been typed since.
    private(set) var isLastSubjectStanding = false

    /// The Subject Card's Subject, and what Enter and Tab act on, while the
    /// Last Subject stands. Not in `subjectVM.results`: it was not matched by
    /// a Query, so it has no Result row and the Slab stays away.
    var standingSubject: Subject? {
        guard isLastSubjectStanding, phase == .searchingSubject else { return nil }
        return lastSubject
    }

    /// Notes what was just acted on. Only a Clipboard Item still in Clipboard
    /// History, or an Emoji, becomes the Last Subject; acting on anything else
    /// ends it, because it is the *last* thing acted on.
    private func remember(actedOn subject: Subject) {
        switch subject.kind {
        case .clipboard(let item):
            lastSubject = history.index(of: item) == nil ? nil : subject
        case .emoji:
            lastSubject = subject
        default:
            lastSubject = nil
        }
    }

    /// Stands the Last Subject as the Panel opens, with the Query empty.
    ///
    /// A Clipboard Item is looked up again rather than trusted: it may have
    /// been deleted, or fallen off the end of the history, since. Without a
    /// Last Subject the previous Query stays, settled, as it always has.
    private func standLastSubject() {
        if let item = lastSubject?.clipboardItem {
            lastSubject = history.index(of: item).map { clipboardSubject(for: history.items[$0]) }
        }
        isLastSubjectStanding = lastSubject != nil
        if isLastSubjectStanding { subjectVM.reset() }
    }

    /// A Subject search Result as it is chosen, by Enter or Tab.
    ///
    /// A File Result is resolved again through `PathSubject`, exactly as a
    /// typed path is: it is what the File Index read some time ago, and
    /// choosing it is the moment to ask the disk what it is now — an app
    /// bundle in Downloads is an app, not a file. `nil` when it is gone. A
    /// Path Subject was resolved as it was typed, and anything else is
    /// already what it is.
    ///
    /// Its Passage comes with it: the Card goes on showing where the file
    /// matched, Shift+Space opens it there and Enter plays it from there.
    private func chosen(_ result: Subject) -> Subject? {
        guard case .file? = subjectVM.sourceResult(for: result)?.hit else { return result }
        guard var subject = result.url.flatMap({ PathSubject.subject(for: $0) }) else { return nil }
        subject.passage = result.passage
        return subject
    }

    /// The Emoji selection as it would be pasted — the base wearing the tone in
    /// force, whether that is the persisted default or a one-off override.
    var currentEmoji: Emoji? {
        guard phase == .browsingEmoji else { return nil }
        return emojiVM.resolvedSelection
    }

    /// The default Skin Tone, for Settings to read and write.
    var defaultSkinTone: SkinTone {
        get { emojiVM.preferences.defaultSkinTone }
        set { emojiVM.preferences.defaultSkinTone = newValue }
    }

    // MARK: - Editing a text Subject

    /// Whether the Subject Card is holding an editor rather than a preview.
    var isEditingTextSubject: Bool = false

    /// What the editor holds, until `saveTextSubjectEdit` commits it.
    var textSubjectEditText: String = ""

    /// The text Subject this Phase would edit, and its text.
    ///
    /// Editing is a **text Subject** capability, not a Clipboard one: a
    /// Clipboard Item, OCR Text and a transform's output are all the same thing
    /// to edit. This used to be gated on `phase == .browsingClipboard`, so only
    /// the first of the three could be.
    ///
    /// While the Clipboard is being browsed the Subject has not been chosen
    /// yet, so the selected entry stands in for it. An image has no text and is
    /// refused in every branch.
    ///
    /// In Subject search the Query itself is the text: ⌘E is how a Query
    /// becomes a text Subject at all, whether or not it matched an app, and a
    /// path Query too — the user asked for text. See
    /// `docs/adr/0012-files-in-subject-search-text-mode-is-cmd-e.md`.
    private var editableTextSubject: (subject: Subject, text: String)? {
        if phase == .browsingClipboard {
            guard let item = currentClipboardItem, !item.isImage else { return nil }
            return (clipboardSubject(for: item), item.content)
        }
        if phase == .searchingSubject {
            if let standing = standingSubject { return Self.editableText(of: standing) }
            if isTextMode { return Self.editableText(of: subjectVM.results[subjectVM.selectedIndex]) }
            let query = subjectVM.searchText
            if !query.isEmpty { return (Subject(text: query), query) }
        }
        guard let subject = selectedSubject else { return nil }
        return Self.editableText(of: subject)
    }

    private static func editableText(of subject: Subject) -> (subject: Subject, text: String)? {
        switch subject.kind {
        case .text(let rawText):
            return (subject, rawText)
        case .clipboard(let item):
            return item.isImage ? nil : (subject, item.content)
        default:
            return nil
        }
    }

    /// Ctrl+E / Cmd+E: opens the editor, or saves the one that is open.
    func toggleTextSubjectEdit() {
        if isEditingTextSubject {
            saveTextSubjectEdit()
            focusTrigger.toggle()
            return
        }
        guard let editable = editableTextSubject else { return }
        selectedSubject = editable.subject
        textSubjectEditText = editable.text
        isEditingTextSubject = true
    }

    /// Commits the editor. The Subject stays a text Subject, and its Actions
    /// are reloaded because the text they were built for has changed — "Open
    /// URL" comes and goes with it.
    func saveTextSubjectEdit() {
        guard isEditingTextSubject else { return }
        isEditingTextSubject = false

        let edited = textSubjectEditText
        let newSubject: Subject

        // A Clipboard Item is written through to history, because that is where
        // it lives and Editing must not fork a copy of it. Anything else — OCR
        // Text, a transform's output — is a text Subject with nowhere else to
        // be. Clipboard History gains nothing new here: `PasteboardWatcher` is
        // still its only writer, and OCR Text reaches it only if the user
        // Copies or Pastes it.
        if let item = selectedSubject?.clipboardItem ?? currentClipboardItem {
            // Editing replaces the entry with a new one, so the Subject is
            // read back from the history: one detached from it could not be
            // moved to the top on Paste, nor stand as the Last Subject.
            let index = history.index(of: item)
            history.updateText(for: item, text: edited)
            clipboardVM.load()
            newSubject = clipboardSubject(for: index.map { history.items[$0] } ?? ClipboardItem(content: edited))
            if lastSubject?.clipboardItem?.id == item.id { lastSubject = newSubject }
        } else {
            newSubject = Subject(text: edited)
            // Saved from Subject search, the text stands where the Query was,
            // so Enter and Tab find it there.
            if phase == .searchingSubject { subjectVM.standAsText(newSubject) }
        }

        selectedSubject = newSubject
        actionVM.loadActions(for: newSubject)
    }

    /// Tab out of the editor: save, then go on to the Actions.
    func saveTextSubjectEditAndAdvance() {
        saveTextSubjectEdit()
        guard selectedSubject != nil else { return }
        phase = .pickingAction
        onPhaseChange?()
    }

    var currentClipboardItem: ClipboardItem? {
        guard phase == .browsingClipboard else { return nil }
        let vm = clipboardVM
        guard vm.selectedIndex < vm.filteredItems.count else { return nil }
        return vm.filteredItems[vm.selectedIndex]
    }

    /// The scope the current phase searches in. `.showingResult` searches
    /// nothing, so it has no scope.
    var currentScope: SearchScope? {
        switch phase {
        case .searchingSubject: subjectVM
        case .browsingClipboard: clipboardVM
        case .browsingEmoji: emojiVM
        case .pickingAction: actionVM
        case .pickingTarget: targetVM
        case .showingResult: nil
        }
    }

    var currentSearchText: String {
        get { currentScope?.searchText ?? "" }
        set { currentScope?.searchText = newValue }
    }

    var currentResults: [ResultDisplayItem] {
        currentScope?.displayResults ?? []
    }

    /// Whether a search the current Mode cannot have finished yet is running,
    /// which is what "Searching…" is for.
    ///
    /// Only Target search can be in this state: it shells out to `mdfind` and
    /// says so. Every other Mode matches against something already in memory,
    /// so by the time anything reads this it has its answer.
    var isSearchInFlight: Bool {
        phase == .pickingTarget && targetVM.isSearching
    }

    /// Whether OCR is running.
    ///
    /// A sibling of `isSearchInFlight` and deliberately not folded into it:
    /// that flag belongs to Target search, it means "Searching…", and OCR is
    /// not a search. This one means "Reading text…", and it is also the gate on
    /// a second Enter — two OCR runs racing to retarget the same Subject would
    /// have the loser overwrite the winner. See
    /// `docs/adr/0007-async-action-behind-the-effect-seam.md`.
    private(set) var isOCRInFlight = false

    /// Whether the last OCR run found no text at all.
    ///
    /// The state the Panel shakes about, the same way it shakes about a Query
    /// that matched nothing. Cleared as a run starts, so two barren images in a
    /// row shake twice instead of once.
    private(set) var ocrFoundNoText = false

    /// Image work returns across the Effect seam. Generation IDs prevent a
    /// completion from an earlier Panel session from changing a newer Subject.
    private(set) var isImageActionInFlight = false
    private(set) var imageActionFailed = false
    private var imageActionGeneration = 0
    private var pendingImageSubjectID: UUID?

    /// Whether zero Results means "nothing matched" rather than "not answered
    /// yet".
    ///
    /// Clipboard, Emoji and Action search all match in memory: zero matches is
    /// the truth the instant the key lands, and the message must not be
    /// delayed. Subject search is the exception — it matches against the app
    /// Index, and until the first scan lands there is nothing to match against
    /// and no honest way to say "No results"; and below the apps it has a
    /// second list, which answers each Query a moment after the keystroke. It
    /// says "No results" only when both have answered this Query
    /// (`SubjectSearchVM.hasAnswered`). Target search is answering out of
    /// process, so it reports `isSearchInFlight` instead. OCR is not a search
    /// at all, but while it runs the Slab is showing "Reading text…" and must
    /// not be able to claim anything about Results either.
    var canReportNoResults: Bool {
        if isSearchInFlight { return false }
        if isOCRInFlight { return false }
        if phase == .searchingSubject { return subjectVM.hasAnswered }
        return true
    }

    /// Whether the Query was put to Subject search and matched nothing. The
    /// state the Panel shakes about.
    var hasNoSubjectMatch: Bool {
        phase == .searchingSubject && subjectVM.hasNoMatch
    }

    var currentSelectedIndex: Int {
        get { currentScope?.selectedIndex ?? 0 }
        set { currentScope?.selectedIndex = newValue }
    }

    var currentQuery: String { currentSearchText }

    /// What the search field shows. Not always the query — see `QueryBuffer`.
    var displayedQuery: String { queryBuffer.display }

    /// Accepts what the search field now contains and decides what the query
    /// becomes.
    ///
    /// Once a subject search has settled, the next characters start a *new*
    /// query instead of extending the old one: type "saf" to land on Safari,
    /// then "n", and the search is "n" — not "safn". A Query standing as text
    /// is no exception: its text was written in the editor, not here.
    ///
    /// The first keystroke also ends a standing Last Subject, which stays on
    /// the Card until the new Query has something to show.
    /// - Returns: the text the field should now show, which differs from what
    ///   was typed whenever a settled query has just been replaced.
    @discardableResult
    func acceptTypedText(_ typed: String) -> String {
        // Typing is a new question; the preview was of the old answer.
        passagePreview = nil
        let startsNewQuery = phase == .searchingSubject && subjectVM.isSearchCommitted
        if let standing = standingSubject { subjectVM.holdOnCard(standing) }
        if phase == .searchingSubject { isLastSubjectStanding = false }

        currentSearchText = queryBuffer.accept(typed, startsNewQuery: startsNewQuery)
        return queryBuffer.display
    }

    /// Points the field at the current phase's query. Called when the phase
    /// changes or focus returns, so the field shows what it is now editing.
    func syncQueryDisplay() {
        queryBuffer.set(currentSearchText)
    }

    // MARK: - Navigation

    /// Returns true if Escape was consumed (phase retreated or editor closed).
    /// Returns false if caller should dismiss the panel entirely.
    func handleEscape() -> Bool {
        // Escape stops a Transcribe and leaves the Panel on the file's
        // Actions; the next one dismisses as it always does.
        if isTranscriptionInFlight {
            cancelTranscription()
            return true
        }

        if isRenaming {
            cancelRename()
            return true
        }

        if passagePreview != nil {
            passagePreview = nil
            return true
        }

        if isEditingTextSubject {
            isEditingTextSubject = false
            focusTrigger.toggle()
            return true
        }

        if emojiVM.isTonePickerOpen {
            emojiVM.closeTonePicker()
            return true
        }

        switch phase {
        case .pickingTarget:
            retreatPhase()
            return true
        // Undoes ⌘E: back to what the Query matched.
        case .searchingSubject where isTextMode:
            subjectVM.withdrawText()
            focusTrigger.toggle()
            return true
        // Emoji Mode dismisses outright rather than falling back to Subject
        // search: it is a Mode the user arrived in on purpose, usually from its
        // own hotkey, and dropping them into an empty Subject search is not a
        // step back from it.
        case .showingResult, .pickingAction, .browsingClipboard, .browsingEmoji, .searchingSubject:
            return false
        }
    }

    /// Up and down move one row. In a list that is one Result; in the Emoji
    /// grid it is a whole row of cells, which is why the grid's own model owns
    /// the arithmetic.
    func moveUp() {
        if phase == .browsingEmoji {
            emojiVM.moveRow(-1)
            return
        }
        if currentSelectedIndex > 0 {
            currentSelectedIndex -= 1
            if phase == .browsingClipboard { selectedSubject = nil }
        }
    }

    func moveDown() {
        if phase == .browsingEmoji {
            emojiVM.moveRow(1)
            return
        }
        let count = currentResults.count
        if currentSelectedIndex < count - 1 {
            currentSelectedIndex += 1
            if phase == .browsingClipboard { selectedSubject = nil }
        }
    }

    /// Left and right move one cell, and mean nothing outside a grid.
    ///
    /// - Returns: whether the key was consumed, so the field can pass it on to
    ///   ordinary text editing in every other Mode.
    @discardableResult
    func moveLeft() -> Bool {
        guard phase == .browsingEmoji else { return false }
        if emojiVM.isTonePickerOpen {
            emojiVM.moveTone(-1)
        } else {
            emojiVM.moveCell(-1)
        }
        return true
    }

    @discardableResult
    func moveRight() -> Bool {
        guard phase == .browsingEmoji else { return false }
        if emojiVM.isTonePickerOpen {
            emojiVM.moveTone(1)
        } else {
            emojiVM.moveCell(1)
        }
        return true
    }

    /// ⌥Enter: the six-tone override for the selected Emoji, where tones apply.
    ///
    /// - Returns: whether the key was consumed. It isn't when the Emoji takes
    ///   no tones, so ⌥Enter falls through to an ordinary submit.
    @discardableResult
    func toggleSkinTonePicker() -> Bool {
        guard phase == .browsingEmoji else { return false }
        if emojiVM.isTonePickerOpen {
            emojiVM.closeTonePicker()
            return true
        }
        return emojiVM.openTonePicker()
    }

    func advancePhase() {
        switch phase {
        case .searchingSubject:
            if let standing = standingSubject {
                selectedSubject = standing
                actionVM.loadActions(for: standing)
                phase = .pickingAction
                onPhaseChange?()
                return
            }
            let results = subjectVM.results
            guard subjectVM.selectedIndex < results.count,
                  let subject = chosen(results[subjectVM.selectedIndex]) else { return }
            selectedSubject = subject

            if case .builtIn(.clipboard) = subject.kind {
                clipboardVM.load()
                phase = .browsingClipboard
                onPhaseChange?()
                return
            }

            if case .builtIn(.emoji) = subject.kind {
                enterEmojiMode()
                return
            }

            actionVM.loadActions(for: subject)
            phase = .pickingAction
            isSubjectFromSearch = true
            onPhaseChange?()

        case .browsingEmoji:
            guard let emoji = emojiVM.resolvedSelection else { return }
            let subject = Subject(emoji: emoji)
            selectedSubject = subject
            actionVM.loadActions(for: subject)
            phase = .pickingAction
            onPhaseChange?()

        case .browsingClipboard:
            guard clipboardVM.selectedIndex < clipboardVM.filteredItems.count else { return }
            let subject = clipboardSubject(for: clipboardVM.filteredItems[clipboardVM.selectedIndex])
            selectedSubject = subject
            actionVM.loadActions(for: subject)
            phase = .pickingAction
            onPhaseChange?()

        case .pickingAction:
            guard let subject = selectedSubject,
                  actionVM.selectedIndex < actionVM.filteredActions.count else { return }
            let action = actionVM.filteredActions[actionVM.selectedIndex]
            if !action.isFinal {
                selectedAction = action
                loadTargets(for: subject, action: action)
                phase = .pickingTarget
                onPhaseChange?()
            }

        case .pickingTarget, .showingResult:
            break
        }
    }

    func retreatPhase() {
        switch phase {
        case .searchingSubject:
            break
        case .browsingClipboard, .browsingEmoji:
            phase = .searchingSubject
            onPhaseChange?()
        case .pickingAction:
            if isLastSubjectStanding || isSubjectFromSearch {
                phase = .searchingSubject
            } else if selectedClipboardItem != nil {
                phase = .browsingClipboard
            } else if selectedSubject?.emoji != nil {
                phase = .browsingEmoji
            } else {
                phase = .searchingSubject
            }
            onPhaseChange?()
        case .pickingTarget:
            phase = .pickingAction
            onPhaseChange?()
        case .showingResult:
            if selectedClipboardItem != nil {
                phase = .browsingClipboard
            } else {
                phase = .pickingAction
            }
            onPhaseChange?()
        }
    }

    /// Cmd+Backspace on a Clipboard Item: deletes it from Clipboard History on
    /// the spot, without asking, the way Finder's Cmd+Delete trashes a file.
    /// The Panel, the Mode and the Query all stay.
    ///
    /// Only ever a Clipboard History entry, never a file: `currentClipboardItem`
    /// exists only in Clipboard Mode.
    ///
    /// - Returns: whether there was a Clipboard Item to delete. When there was
    ///   not, the key means `retreatPhase()`, as it does everywhere else.
    @discardableResult
    func deleteSelectedClipboardItem() -> Bool {
        // The item under an open editor is not the one to delete out from under it.
        guard !isEditingTextSubject, let item = currentClipboardItem else { return false }
        removeFromHistory(item)
        return true
    }

    /// The one way the user removes a Clipboard Item, by key or by the Delete
    /// from History Action. Its stored image goes with it, and the browser comes
    /// back on the same Query with the row that took its place selected.
    private func removeFromHistory(_ item: ClipboardItem) {
        history.remove(item)
        if lastSubject?.clipboardItem?.id == item.id { lastSubject = nil }
        clipboardVM.reload()
        selectedSubject = nil
        phase = .browsingClipboard
        onPhaseChange?()
    }

    /// Fills the Target Phase for a non-Final Action.
    ///
    /// Share's Targets come from the *Payload* rather than the Subject, and
    /// resolving a Payload is this object's job: a Clipboard Image shares as
    /// its stored PNG, which only the history can name. Going through
    /// `sharePayload(for:)` here is also what keeps the list the user picks
    /// from and the item the service is handed the same thing. Move To… and
    /// Copy To… are the other two: their folders come from the Sources and
    /// the recent destinations, which are this object's too.
    private func loadTargets(for subject: Subject, action: SubjectAction) {
        if case .share = action.handler, let payload = sharePayload(for: subject) {
            targetVM.loadShareTargets(for: payload)
            return
        }
        switch action.handler {
        case .moveTo, .copyTo:
            targetVM.loadFolderTargets(destinationFolders())
        default:
            targetVM.loadTargets(for: subject, action: action)
        }
    }

    // MARK: - Moving, copying, renaming, compressing

    /// Folders a Move or Copy went to in this run of the app, latest first. In
    /// memory only, like the Last Subject.
    private var recentDestinations: [URL] = []

    /// What Move To… and Copy To… offer before anything is typed: where the
    /// last ones went, the folder Sources, then Desktop, Documents, Downloads
    /// and Home. Each once, and only if it is still a folder.
    func destinationFolders() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let common = ["Desktop", "Documents", "Downloads"].map {
            home.appendingPathComponent($0, isDirectory: true)
        } + [home]
        let candidates = recentDestinations
            + sources.folders.compactMap(\.folderPath).map { URL(fileURLWithPath: $0, isDirectory: true) }
            + common

        var seen = Set<String>()
        return candidates.filter { url in
            let path = url.standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
            return seen.insert(path).inserted
        }
    }

    /// Whether a Move, Copy, Rename or Compress is on disk being done. Gates a
    /// second Enter the way `isImageActionInFlight` does.
    private(set) var isFileOperationInFlight = false

    /// What the last one that failed said, for the Subject Card's corner, and
    /// what the Panel shakes about. Cleared as the next one starts and as the
    /// Phase moves on.
    private(set) var fileOperationFailure: String?

    private var fileOperationGeneration = 0
    private var pendingFileOperation: FileOperation?
    private var pendingFileSubjectID: UUID?

    /// What the Subject Card's corner says about file work: under way, or why
    /// it did not happen.
    var fileOperationNote: String? {
        if isFileOperationInFlight { return pendingFileOperation?.progressNote }
        return fileOperationFailure
    }

    /// The file or folder on disk behind a Subject, and nothing else. A
    /// Clipboard Item's `url` is the file it was copied *from* — a name and
    /// nothing more — and no Action moves, renames or zips that.
    private func fileOnDisk(_ subject: Subject) -> URL? {
        switch subject.kind {
        case .file, .folder: subject.url
        default: nil
        }
    }

    private func beginFileOperation(_ operation: FileOperation, on subject: Subject) -> [Effect] {
        fileOperationGeneration += 1
        isFileOperationInFlight = true
        fileOperationFailure = nil
        pendingFileOperation = operation
        pendingFileSubjectID = subject.id
        return [.fileOperation(operation, generation: fileOperationGeneration)]
    }

    /// Where a Move, Copy, Rename or Compress landed, handed back by the
    /// runner. The Subject follows it there — the moved file, the copy, the
    /// renamed file, the zip — and the Panel stays on the Action Phase with
    /// that Subject's Actions, as it does after Rotate or "Use as Subject".
    ///
    /// A failure leaves everything where it was, Rename's editor included, so
    /// a taken name can be changed and tried again.
    func receiveFileOperation(_ result: Result<URL, FileOperation.Failure>, generation: Int) {
        guard isFileOperationInFlight, generation == fileOperationGeneration else { return }
        isFileOperationInFlight = false
        let operation = pendingFileOperation
        let expectedSubjectID = pendingFileSubjectID
        pendingFileOperation = nil
        pendingFileSubjectID = nil
        guard phase == .pickingAction || phase == .pickingTarget,
              selectedSubject?.id == expectedSubjectID,
              let operation else { return }

        let landed: Subject
        switch result {
        case .failure(let failure):
            fileOperationFailure = operation.failureNote(failure)
            return
        case .success(let url):
            guard let subject = PathSubject.subject(for: url) else {
                fileOperationFailure = operation.failureNote(.failed)
                return
            }
            landed = subject
        }

        switch operation {
        case .move(_, let folder), .copy(_, let folder):
            recentDestinations.removeAll { $0.standardizedFileURL.path == folder.standardizedFileURL.path }
            recentDestinations.insert(folder, at: 0)
            recentDestinations = Array(recentDestinations.prefix(Self.recentDestinationLimit))
        case .rename:
            isRenaming = false
            focusTrigger.toggle()
        case .compress:
            break
        }

        selectedSubject = landed
        selectedAction = nil
        actionVM.loadActions(for: landed)
        phase = .pickingAction
        onPhaseChange?()
    }

    private static let recentDestinationLimit = 5

    // MARK: - Renaming

    /// Whether the Subject Card is holding a file's name for editing. Not
    /// Editing (`GLOSSARY.md`), which is a text Subject's text.
    private(set) var isRenaming = false

    /// What the name editor holds, until `commitRename` acts on it.
    var renameText = ""

    /// Opens the name editor on the Subject Card, holding the current name.
    private func beginRename(_ subject: Subject) {
        guard let url = fileOnDisk(subject) else { return }
        fileOperationFailure = nil
        renameText = url.lastPathComponent
        isRenaming = true
    }

    /// The part of the name the editor selects as it opens: the name without
    /// its extension, as Finder does. A folder's whole name.
    var renameSelectedRange: Range<String.Index> {
        let isFolder = if case .folder? = selectedSubject?.kind { true } else { false }
        return FileOperation.baseNameRange(in: renameText, isFolder: isFolder)
    }

    /// Enter or ⌘E in the name editor. An unchanged name just closes it. Any
    /// other goes to disk, and the editor stays open until the answer: a
    /// taken name leaves it open to try another.
    @discardableResult
    func commitRename() -> [Effect] {
        guard isRenaming, !isFileOperationInFlight,
              let subject = selectedSubject, let url = fileOnDisk(subject) else { return [] }
        guard renameText != url.lastPathComponent else {
            cancelRename()
            return []
        }
        let effects = beginFileOperation(.rename(url, to: renameText), on: subject)
        runner.run(effects)
        return effects
    }

    /// Escape in the name editor: the name stays what it was.
    func cancelRename() {
        guard isRenaming else { return }
        isRenaming = false
        fileOperationFailure = nil
        focusTrigger.toggle()
    }

    /// Advances the machine and hands the resulting effects to the runner.
    /// The effects are returned too, so tests can assert on them directly.
    @discardableResult
    func submit() -> [Effect] {
        // A second Enter while OCR is running must do nothing at all. Not a
        // debounce and not a delay: the run either is or is not in flight, and
        // while it is, the answer it will bring back owns the Subject.
        guard !isOCRInFlight, !isImageActionInFlight, !isFileOperationInFlight,
              !isTranscriptionInFlight, !isMomentOpenInFlight else { return [] }
        let effects = submitEffects()
        runner.run(effects)
        return effects
    }

    private func submitEffects() -> [Effect] {
        switch phase {
        case .searchingSubject:
            // Enter on the Last Subject does what Enter did when it was chosen:
            // paste the Clipboard Item, insert the Emoji.
            if let standing = standingSubject {
                selectedSubject = standing
                remember(actedOn: standing)
                return defaultEffects(for: standing)
            }
            let results = subjectVM.results
            guard subjectVM.selectedIndex < results.count,
                  let subject = chosen(results[subjectVM.selectedIndex]) else { return [] }
            if case .builtIn(.clipboard) = subject.kind {
                selectedSubject = subject
                clipboardVM.load()
                phase = .browsingClipboard
                onPhaseChange?()
                return []
            }
            if case .builtIn(.emoji) = subject.kind {
                selectedSubject = subject
                enterEmojiMode()
                return []
            }
            // An Emoji from the list below the apps is used as Emoji Mode uses
            // one: Enter inserts it and it becomes recent.
            if let base = subjectVM.sourceResult(for: results[subjectVM.selectedIndex])?.emojiBase {
                emojiVM.recents.record(base)
            }
            remember(actedOn: subject)
            return defaultEffects(for: subject)

        case .browsingEmoji:
            guard let emoji = emojiVM.resolvedSelection else { return [] }
            emojiVM.recordSelectionUse()
            emojiVM.closeTonePicker()
            let subject = Subject(emoji: emoji)
            selectedSubject = subject
            remember(actedOn: subject)
            return defaultEffects(for: subject)

        case .browsingClipboard:
            guard clipboardVM.selectedIndex < clipboardVM.filteredItems.count else { return [] }
            let subject = clipboardSubject(for: clipboardVM.filteredItems[clipboardVM.selectedIndex])
            selectedSubject = subject
            remember(actedOn: subject)
            return defaultEffects(for: subject)

        case .pickingAction:
            guard actionVM.selectedIndex < actionVM.filteredActions.count else { return [] }
            let action = actionVM.filteredActions[actionVM.selectedIndex]
            guard let subject = selectedSubject else { return [] }
            guard action.isFinal else {
                selectedAction = action
                loadTargets(for: subject, action: action)
                phase = .pickingTarget
                onPhaseChange?()
                return []
            }
            let effects = effects(for: action, on: subject)
            // What the Action left as the Subject: a transformed Clipboard
            // Item is a new entry, and a deleted one is none.
            remember(actedOn: selectedSubject ?? subject)
            return effects

        case .pickingTarget:
            guard let subject = selectedSubject,
                  let action = selectedAction,
                  targetVM.selectedIndex < targetVM.filteredTargets.count else { return [] }
            let target = targetVM.filteredTargets[targetVM.selectedIndex]
            let effects = effects(for: action, on: subject, with: target)
            // Use as Subject chooses a Subject; it does not act on one.
            if case .useAsSubject = action.handler { return effects }
            remember(actedOn: subject)
            return effects

        case .showingResult(let result):
            // Copying a count acts on text.
            lastSubject = nil
            return [.copy(.text(result)), .hide]
        }
    }

    /// Replaces the Subject with a text one holding `result` and reloads its
    /// Actions, staying in the current Phase.
    ///
    /// - Parameter writingTheQuery: whether `result` also becomes the Subject
    ///   Query, standing there as text so Shift+Tab finds it. A transform's
    ///   output is the same length as its input, so it
    ///   survives a one-line bar; OCR Text is a page of prose and
    ///   `PanelLayout.queryFieldHeight` is a bar, not a row. Split into a
    ///   parameter rather than written and then cleared, because a Query that
    ///   is briefly a page long is still a Query that is a page long.
    private func retarget(at result: String, writingTheQuery: Bool) {
        let newSubject = Subject(text: result)
        selectedSubject = newSubject
        if writingTheQuery {
            subjectVM.searchText = result
            subjectVM.standAsText(newSubject)
        }
        actionVM.loadActions(for: newSubject)
        syncQueryDisplay()
        onPhaseChange?()
    }

    /// The OCR Text, handed back by the runner.
    ///
    /// The other half of the Effect seam: `submit` returned `.ocr(url)` and
    /// nothing else, and this is where the answer arrives. A test calls it
    /// directly with a canned string, which is why Vision never runs under
    /// test — see `docs/adr/0007-async-action-behind-the-effect-seam.md`.
    ///
    /// An image with no readable text produces **no** OCR Text, so no empty
    /// text Subject is ever created: the Subject is left exactly as it was —
    /// a Clipboard Image is still an image, still in history — and the Panel
    /// shakes instead.
    func receiveOCRText(_ text: String?) {
        guard isOCRInFlight else { return }
        isOCRInFlight = false

        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ocrFoundNoText = true
            return
        }

        retarget(at: text, writingTheQuery: false)
    }

    /// QR bytes returning from the runner become a new Clipboard Item and the
    /// current Subject in one move. No pasteboard write occurs on this path.
    func receiveQRCode(_ data: Data?, generation: Int) {
        guard isImageActionInFlight, generation == imageActionGeneration else { return }
        isImageActionInFlight = false
        let expectedSubjectID = pendingImageSubjectID
        pendingImageSubjectID = nil
        guard phase == .pickingAction, selectedSubject?.id == expectedSubjectID else { return }
        guard let data, let item = history.recordGeneratedImage(data) else {
            imageActionFailed = true
            return
        }

        clipboardVM.load()
        let subject = clipboardSubject(for: item)
        selectedSubject = subject
        selectedAction = nil
        actionVM.loadActions(for: subject)
        phase = .pickingAction
        syncQueryDisplay()
        onPhaseChange?()
    }

    /// Rotation completion changes no model identity or history position. A
    /// fresh Subject value is what tells the Subject Card the pixels changed:
    /// the Card keys its thumbnail on the Subject, so a new one checks the file
    /// again and finds it rewritten.
    func receiveImageRotation(succeeded: Bool, generation: Int) {
        guard isImageActionInFlight, generation == imageActionGeneration else { return }
        isImageActionInFlight = false
        let expectedSubjectID = pendingImageSubjectID
        pendingImageSubjectID = nil
        guard phase == .pickingAction, selectedSubject?.id == expectedSubjectID else { return }
        guard succeeded, let subject = selectedSubject else {
            imageActionFailed = true
            return
        }

        if let item = subject.clipboardItem {
            selectedSubject = clipboardSubject(for: item)
        } else {
            selectedSubject = Subject(
                displayName: subject.displayName,
                path: subject.path,
                url: subject.url,
                icon: subject.icon,
                kind: subject.kind,
                thumbnailURL: subject.thumbnailURL
            )
        }
        onPhaseChange?()
    }

    // MARK: - Transcribing

    /// Whether Codictate is transcribing the Subject. Gates a second Enter the
    /// way `isOCRInFlight` does, and says "Transcribing…" in the Subject
    /// Card's corner: a long recording takes a while (11.5 minutes of audio
    /// took ~27 s), and the command reports no progress to show.
    private(set) var isTranscriptionInFlight = false

    /// Why the last Transcribe gave no text Subject, for the Subject Card's
    /// corner, and what the Panel shakes about. Cleared as the next one starts
    /// and as the Phase moves on.
    private(set) var transcriptionFailure: Transcription.Failure?

    private var transcriptionGeneration = 0
    private var pendingTranscriptionSubjectID: UUID?

    /// What the Subject Card's corner says about Transcribe: under way, or why
    /// it came to nothing.
    var transcriptionNote: String? {
        if isTranscriptionInFlight { return "Transcribing…" }
        return transcriptionFailure?.note
    }

    /// Transcribe on Enter. Without a Codictate to run, the first Enter says
    /// so and the next one opens Codictate's website, so a missing Codictate
    /// is never a silent failure and never a dead end.
    private func transcribeEffects(for subject: Subject) -> [Effect] {
        guard let url = fileOnDisk(subject) else { return [] }
        if transcriptionFailure?.offersDownload == true {
            return [.hide, .open(Transcription.downloadURL)]
        }
        transcriptionGeneration += 1
        isTranscriptionInFlight = true
        transcriptionFailure = nil
        pendingTranscriptionSubjectID = subject.id
        // **No `.hide`.** The transcript lands *in* the Panel, as OCR Text does.
        return [.transcribe(url, generation: transcriptionGeneration)]
    }

    /// The transcript, handed back by the runner.
    ///
    /// It becomes a text Subject in place of the file, exactly as OCR Text
    /// replaces an image, so Copy, Paste, Share, Editing and the transforms
    /// all work on it. Silence produces no text Subject at all, never an empty
    /// one: the file stays the Subject and the Panel shakes.
    func receiveTranscription(_ result: Result<String, Transcription.Failure>, generation: Int) {
        guard isTranscriptionInFlight, generation == transcriptionGeneration else { return }
        isTranscriptionInFlight = false
        let expectedSubjectID = pendingTranscriptionSubjectID
        pendingTranscriptionSubjectID = nil
        guard phase == .pickingAction, selectedSubject?.id == expectedSubjectID else { return }

        switch result {
        case .failure(let failure):
            transcriptionFailure = failure
        case .success(let transcript):
            // A Speech Engine's text often opens with a space.
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                transcriptionFailure = .noSpeech
                return
            }
            retarget(at: text, writingTheQuery: false)
        }
    }

    /// Stops the Transcribe under way, if there is one. Its answer is dropped
    /// by the generation. Called on Escape, on leaving the file's Actions, and
    /// by `PanelController` as the Panel goes away: a hidden Panel has nowhere
    /// to put a transcript, and the next one starts afresh.
    func cancelTranscription() {
        guard isTranscriptionInFlight else { return }
        transcriptionGeneration += 1
        isTranscriptionInFlight = false
        pendingTranscriptionSubjectID = nil
        runner.run([.cancelTranscription])
    }

    /// Asks that the next `reset` open straight into Emoji Mode.
    ///
    /// The panel resets itself as it appears, so the hotkey cannot simply set
    /// the phase first — it would be wiped. It leaves this instead, and reset
    /// honours it once.
    func requestEmojiMode() {
        wantsEmojiMode = true
    }

    private var wantsEmojiMode = false

    /// Emoji Mode with an empty Query, Recents on top, ready to type.
    func enterEmojiMode() {
        selectedSubject = Subject.emojiBuiltIn
        emojiVM.load()
        phase = .browsingEmoji
        syncQueryDisplay()
        onPhaseChange?()
    }

    func reset() {
        phase = .searchingSubject
        selectedSubject = nil
        selectedAction = nil
        isEditingTextSubject = false
        textSubjectEditText = ""
        isOCRInFlight = false
        ocrFoundNoText = false
        imageActionGeneration += 1
        isImageActionInFlight = false
        imageActionFailed = false
        pendingImageSubjectID = nil
        fileOperationGeneration += 1
        isFileOperationInFlight = false
        fileOperationFailure = nil
        pendingFileOperation = nil
        pendingFileSubjectID = nil
        cancelTranscription()
        transcriptionFailure = nil
        isRenaming = false
        renameText = ""
        passagePreview = nil
        momentOpenGeneration += 1
        isMomentOpenInFlight = false
        momentOpenFailed = false
        pendingMoment = nil
        isSubjectFromSearch = false
        subjectVM.isSearchCommitted = true
        subjectVM.forgetPick()
        actionVM.reset()
        targetVM.reset()
        clipboardVM.reset()
        emojiVM.reset()
        standLastSubject()

        if wantsEmojiMode {
            wantsEmojiMode = false
            enterEmojiMode()
        }

        syncQueryDisplay()
        focusTrigger.toggle()
    }

    /// Shift+Space. The Quick Look Action is the same thing on Enter, so both
    /// go through `quickLookEffects()`.
    func triggerQuickLook() {
        runner.run(quickLookEffects())
    }

    /// Quick Look, or the Panel's own preview where a File Result matched
    /// inside the file — which opens, or closes if it is open, and is no
    /// Effect: it is drawn in the Panel, as the rename editor is, and changes
    /// nothing outside it.
    private func quickLookEffects() -> [Effect] {
        if passagePreview != nil {
            passagePreview = nil
            return []
        }
        if let preview = passagePreviewContext() {
            passagePreview = preview
            return []
        }
        return quickLookContext().map { [.quickLook($0)] } ?? []
    }

    // MARK: - The Panel's own preview

    /// What the Results Slab has given way to: a File Result's file, open at
    /// its Passage. See `PassagePreview`.
    private(set) var passagePreview: PassagePreview?

    /// Closes the preview, as the Panel goes away: a video in it must not go
    /// on playing behind a hidden Panel.
    func closePassagePreview() {
        passagePreview = nil
    }

    /// The preview Shift+Space opens in this Phase, if the Subject it is about
    /// matched inside its file: the selected Result in Subject search, the
    /// chosen Subject in the Action Phase.
    private func passagePreviewContext() -> PassagePreview? {
        let subject: Subject?
        switch phase {
        case .searchingSubject:
            let results = subjectVM.results
            subject = standingSubject == nil && subjectVM.selectedIndex < results.count
                ? results[subjectVM.selectedIndex] : nil
        case .pickingAction:
            subject = selectedSubject
        default:
            subject = nil
        }
        guard let subject, let passage = subject.passage, let url = subject.url,
              case .file(let contentType) = subject.kind else { return nil }
        return PassagePreview(url: url, title: subject.displayName, contentType: contentType, passage: passage)
    }

    // MARK: - Opening a recording at its moment

    /// Whether QuickTime is being asked to open a file at its moment. Gates a
    /// second Enter.
    private(set) var isMomentOpenInFlight = false

    /// Whether QuickTime could not, and the file was opened from the start.
    private(set) var momentOpenFailed = false

    private var momentOpenGeneration = 0
    private var pendingMoment: (url: URL, label: String)?

    /// What the Subject Card's corner says about it.
    var momentOpenNote: String? {
        if isMomentOpenInFlight, let label = pendingMoment?.label { return "Opening \(label)…" }
        return momentOpenFailed ? "Opened from the start" : nil
    }

    /// Enter on a recording or a video that matched at a moment: QuickTime,
    /// there. Anything else, or a Subject with no moment, opens as files do.
    private func openEffects(for subject: Subject, url: URL) -> [Effect] {
        guard let passage = subject.passage, let seconds = passage.seconds, let label = passage.momentLabel,
              PassagePreview.isRecording(url) else { return [.hide, .open(url)] }
        momentOpenGeneration += 1
        isMomentOpenInFlight = true
        momentOpenFailed = false
        pendingMoment = (url, label)
        return [.openAtMoment(url, seconds: seconds, generation: momentOpenGeneration)]
    }

    /// QuickTime's answer, handed back by the runner. Opened: the Panel goes,
    /// if QuickTime coming forward has not already sent it. Not — the user
    /// said no, or QuickTime could not open it: the file opens the ordinary
    /// way, from the start, and the Card's corner says so.
    func receiveMomentOpen(succeeded: Bool, generation: Int) {
        guard isMomentOpenInFlight, generation == momentOpenGeneration, let moment = pendingMoment else { return }
        isMomentOpenInFlight = false
        pendingMoment = nil
        if succeeded {
            runner.run([.hide])
        } else {
            momentOpenFailed = true
            runner.run([.open(moment.url)])
        }
    }

    /// What Quick Look shows in this Phase: the one thing the Phase is about,
    /// and arrowing inside Quick Look moves the selection and asks again.
    ///
    /// In Subject search that is the selected Result, or the standing Last
    /// Subject. Every row with a file has a preview: a File Result, a Path
    /// Subject, an app (Quick Look shows its info, as for an app among
    /// Finder's Targets), and a Clipboard Item through its written-out preview.
    /// An Emoji, text and a Built-in have none, and Shift+Space does nothing
    /// on them. In the Action Phase it is the Subject chosen; in the Target
    /// Phase, the selected Target.
    func quickLookContext() -> QuickLookContext? {
        let item: QuickLookPreviewItem?
        switch phase {
        case .searchingSubject:
            if let standing = standingSubject {
                item = quickLookItem(for: standing)
            } else {
                let results = subjectVM.results
                guard subjectVM.selectedIndex < results.count else { return nil }
                item = quickLookItem(for: results[subjectVM.selectedIndex])
            }

        case .pickingAction:
            item = selectedSubject.flatMap(quickLookItem(for:))

        case .pickingTarget:
            let targets = targetVM.filteredTargets
            guard targetVM.selectedIndex < targets.count,
                  let url = targets[targetVM.selectedIndex].url else { return nil }
            item = quickLookItem(url, title: targets[targetVM.selectedIndex].name)

        case .browsingClipboard:
            item = currentClipboardItem.flatMap(quickLookItem(for:))

        case .browsingEmoji, .showingResult:
            item = nil
        }
        return item.map { QuickLookContext(items: [$0], selectedIndex: 0) }
    }

    private func quickLookItem(for subject: Subject) -> QuickLookPreviewItem? {
        switch subject.kind {
        case .clipboard(let clipboardItem):
            return quickLookItem(for: clipboardItem)
        case .app, .file, .folder:
            return subject.url.map { quickLookItem($0, title: subject.displayName) }
        case .text, .emoji, .builtIn:
            return nil
        }
    }

    /// A Clipboard Item's snapshot, never the file it was copied from
    /// (`ClipboardHistory.previewURL(for:)`).
    private func quickLookItem(for clipboardItem: ClipboardItem) -> QuickLookPreviewItem? {
        history.previewURL(for: clipboardItem).map { quickLookItem($0, title: clipboardItem.displayName) }
    }

    private func quickLookItem(_ url: URL, title: String) -> QuickLookPreviewItem {
        QuickLookPreviewItem(url: url, title: title, textCopies: history.fileTextPreviewsDirectory)
    }

    // MARK: - Execution

    /// What this subject puts on the pasteboard or hands to a share service.
    private func payload(for subject: Subject) -> Payload? {
        switch subject.kind {
        case .clipboard(let item):
            if item.isImage, let imageData = history.imageData(for: item) {
                return .image(imageData)
            }
            return .text(item.content)
        case .text(let rawText):
            return .text(rawText)
        case .emoji(let emoji):
            return .text(emoji.string)
        default:
            return subject.url.map { .fileURL($0) }
        }
    }

    /// What this subject hands to a sharing service.
    ///
    /// The same Payload as the pasteboard gets, with one difference: a
    /// Clipboard Image shares as its **stored PNG's file URL** rather than as
    /// image bytes, so the file arriving on the other machine keeps the name it
    /// had here. Paste and Copy must still put pixels on the pasteboard — a
    /// file URL there pastes a file reference into a document — which is why
    /// this is a second method and not a change to `payload(for:)`.
    private func sharePayload(for subject: Subject) -> Payload? {
        if case .clipboard(let item) = subject.kind,
           item.isImage,
           let imageURL = history.imageURL(for: item) {
            return .fileURL(imageURL)
        }
        return payload(for: subject)
    }

    /// The plain text behind a subject, where it has any.
    private func plainText(for subject: Subject) -> String? {
        switch subject.kind {
        case .clipboard(let item): item.isImage ? nil : item.content
        case .text(let rawText): rawText
        case .emoji(let emoji): emoji.string
        default: nil
        }
    }

    /// A Clipboard Item as a Subject, carrying its stored PNG for the
    /// thumbnail. Every Clipboard Subject is made here, because only the
    /// history knows where that PNG is.
    private func clipboardSubject(for item: ClipboardItem) -> Subject {
        Subject(clipboardItem: item, imageURL: history.imageURL(for: item))
    }

    /// The file a subject points at: its own URL, or the stored image for a
    /// clipboard entry.
    ///
    /// Never the file a Clipboard Item was copied *from*. A Clipboard Item is a
    /// snapshot (`GLOSSARY.md`, **Clipboard Item**), so Open in Preview, OCR,
    /// Copy Path and Share all see the pixels as they were at copy time; the
    /// original lends its name and nothing else.
    private func fileURL(for subject: Subject, target: ActionTarget? = nil) -> URL? {
        if let targetURL = target?.url { return targetURL }
        if case .clipboard(let item) = subject.kind {
            return history.imageURL(for: item)
        }
        return subject.url
    }

    private func defaultEffects(for subject: Subject) -> [Effect] {
        switch subject.kind {
        case .app, .folder:
            guard let url = subject.url else { return [.hide] }
            return [.hide, .open(url)]
        case .file:
            guard let url = subject.url else { return [.hide] }
            return openEffects(for: subject, url: url)
        case .text(let rawText):
            return [.hide, .copy(.text(rawText))]
        case .clipboard:
            return effects(for: .init(
                name: "Paste", icon: .sfSymbol("doc.on.clipboard"), isFinal: true, handler: .paste
            ), on: subject)
        case .emoji(let emoji):
            // The Clipboard paste path, unchanged: write, dismiss, hand
            // activation back, then synthesise Cmd+V.
            return [.paste(.text(emoji.string))]
        case .builtIn(.settings):
            return [.hide, .showSettings]
        case .builtIn(.clipboard), .builtIn(.emoji):
            return []
        }
    }

    /// The one execution table. Every subject kind and every action goes
    /// through here; each case returns the complete list of effects, including
    /// whether the panel dismisses.
    private func effects(
        for action: SubjectAction,
        on subject: Subject,
        with target: ActionTarget? = nil
    ) -> [Effect] {
        switch action.handler {

        // MARK: Applications

        case .openApp:
            guard let url = subject.url else { return [.hide] }
            return [.hide, .open(url)]

        case .quitApp:
            guard case .app(let bundleId, _) = subject.kind, let bundleId else { return [.hide] }
            return [.hide, .terminate(bundleIdentifier: bundleId)]

        case .hideApp:
            guard case .app(let bundleId, _) = subject.kind, let bundleId else { return [.hide] }
            return [.hide, .hideApplication(bundleIdentifier: bundleId)]

        // MARK: Files

        case .openFile:
            guard let url = fileURL(for: subject, target: target) else { return [.hide] }
            // Open on the Subject is Enter on it, at its moment where it has one.
            return target == nil ? openEffects(for: subject, url: url) : [.hide, .open(url)]

        case .openWith:
            guard let appURL = target?.url, let url = subject.url else { return [.hide] }
            return [.hide, .openWith(file: url, application: appURL)]

        case .showInFinder, .revealInFinder:
            guard let url = fileURL(for: subject, target: target) else { return [.hide] }
            return [.hide, .revealInFinder(url)]

        case .moveToTrash:
            guard let url = fileURL(for: subject, target: target) else { return [.hide] }
            return [.hide, .moveToTrash(url)]

        case .copyPath:
            guard let path = target?.url?.path ?? fileURL(for: subject)?.path ?? subject.path else {
                return [.hide]
            }
            return [.hide, .copy(.text(path))]

        case .copyFile:
            // The file itself, not its path: Finder and Mail paste the file.
            guard let url = fileOnDisk(subject) else { return [.hide] }
            return [.hide, .copy(.fileURL(url))]

        case .moveTo:
            guard let url = fileOnDisk(subject), let folder = target?.url else { return [] }
            return beginFileOperation(.move(url, into: folder), on: subject)

        case .copyTo:
            guard let url = fileOnDisk(subject), let folder = target?.url else { return [] }
            return beginFileOperation(.copy(url, into: folder), on: subject)

        case .rename:
            // Nothing on disk yet: the name editor opens, and its Enter is
            // `commitRename`.
            beginRename(subject)
            return []

        case .compress:
            // **No `.hide`.** The Subject becomes the zip, in the Panel, so
            // Share and Reveal in Finder are one Enter away.
            guard let url = fileOnDisk(subject) else { return [] }
            return beginFileOperation(.compress(url), on: subject)

        case .quickLook:
            // Exactly Shift+Space. This only runs in the Action Phase, on the
            // Subject, or the Target Phase, on the selected Target — what
            // `quickLookContext()` already reads.
            return quickLookEffects()

        // MARK: Images

        case .ocr:
            // A URL crosses the seam, never image bytes — and `fileURL` already
            // resolves one for both an image file and a Clipboard Image. No
            // Vision here, and no `await`: this method returns Effects, and
            // that is the whole reason it is reachable from a test.
            guard let url = fileURL(for: subject, target: target) else { return [] }
            isOCRInFlight = true
            ocrFoundNoText = false
            // **No `.hide`.** The OCR Text lands *in* the Panel, so the Panel
            // has to still be there when it arrives. See
            // `docs/adr/0007-async-action-behind-the-effect-seam.md`.
            return [.ocr(url)]

        case .qrCode:
            guard case .emoji = subject.kind else {
                guard let text = plainText(for: subject),
                      ImageActions.canGenerateQRCode(for: text) else { return [] }
                return beginImageAction(for: subject) { generation in
                    .generateQRCode(text, generation: generation)
                }
            }
            return []

        case .rotate(let direction):
            guard let url = fileURL(for: subject, target: target) else { return [] }
            return beginImageAction(for: subject) { generation in
                .rotateImage(url, direction: direction, generation: generation)
            }

        case .openInPreview:
            guard let url = fileURL(for: subject, target: target) else { return [.hide] }
            return [.hide, .openInPreview(url)]

        // MARK: Audio and video

        case .transcribe:
            return transcribeEffects(for: subject)

        // MARK: Promotion

        case .useAsSubject:
            // One rule: any Target with a URL becomes the Subject, and what it
            // *is* comes from the same resolver a typed path goes through. The
            // Phase lands on Actions rather than executing anything, and the
            // Card row goes from three Cards to two — which `cardCount`
            // already animates.
            guard let url = target?.url, let promoted = PathSubject.subject(for: url) else {
                return []
            }
            selectedSubject = promoted
            selectedAction = nil
            actionVM.loadActions(for: promoted)
            phase = .pickingAction
            onPhaseChange?()
            return []

        // MARK: Payloads

        case .copy:
            guard let payload = payload(for: subject) else { return [.hide] }
            return [.hide, .copy(payload)]

        case .paste:
            guard let payload = payload(for: subject) else { return [.hide] }
            // A pasted entry becomes the most recent one.
            if case .clipboard(let item) = subject.kind {
                history.moveToTop(item)
            }
            return [.paste(payload)]

        case .pastePlain:
            guard let text = plainText(for: subject) else { return [.hide] }
            return [.paste(.text(text))]

        case .typeText:
            guard let text = plainText(for: subject) else { return [.hide] }
            return [.typeText(text)]

        case .runScript:
            guard let text = plainText(for: subject) else { return [.hide] }
            return [.runAppleScript(text), .hide]

        case .saveAs:
            return saveEffects(for: subject)

        case .share:
            guard let service = target?.sharingService,
                  let payload = sharePayload(for: subject) else {
                return [.hide]
            }
            return [.hide, .share(payload, via: service)]

        // MARK: Text results

        case .transform(let transform):
            guard let text = plainText(for: subject) else { return [.hide] }
            return transformEffects(transform, on: subject, text: text)

        case .count(let countType):
            guard let text = plainText(for: subject) else { return [.hide] }
            phase = .showingResult(countType.count(text))
            onPhaseChange?()
            return []

        case .searchWeb:
            guard let text = plainText(for: subject),
                  let url = Self.webSearchURL(for: text) else { return [.hide] }
            return [.hide, .open(url)]

        case .openURL:
            guard let text = plainText(for: subject),
                  let url = URL(string: text) else { return [.hide] }
            return [.hide, .open(url)]

        case .openEmail:
            guard let text = plainText(for: subject),
                  let url = Self.mailtoURL(body: text) else { return [.hide] }
            return [.hide, .open(url)]

        // MARK: Clipboard history

        case .deleteFromHistory:
            guard let item = subject.clipboardItem else { return [.hide] }
            removeFromHistory(item)
            return []

        // MARK: Codiclens

        case .openSettings:
            return [.hide, .showSettings]

        case .service:
            return []
        }
    }

    private func beginImageAction(
        for subject: Subject,
        effect: (Int) -> Effect
    ) -> [Effect] {
        imageActionGeneration += 1
        isImageActionInFlight = true
        imageActionFailed = false
        pendingImageSubjectID = subject.id
        return [effect(imageActionGeneration)]
    }

    private func saveEffects(for subject: Subject) -> [Effect] {
        if case .clipboard(let item) = subject.kind, item.isImage {
            guard let imageData = history.imageData(for: item) else { return [.hide] }
            return [.savePanel(
                data: imageData,
                fileName: item.imageFileName ?? "image.png",
                contentType: .png
            )]
        }
        guard let text = plainText(for: subject),
              let textData = text.data(using: .utf8) else { return [.hide] }
        return [.savePanel(data: textData, fileName: "untitled.txt", contentType: .plainText)]
    }

    /// Transforming a clipboard entry rewrites it in history and stays in the
    /// browser; transforming a text subject feeds the result back in so
    /// transforms can be chained.
    ///
    /// **OCR does not come through here, and must not.** It has the same shape
    /// — an Action on a Subject that produces text — which is exactly why this
    /// note is here: the clipboard branch below rewrites the Clipboard Item
    /// *in place*, and a Clipboard Image rewritten as its own OCR Text is an
    /// image that is gone. OCR always retargets: the Subject becomes the OCR
    /// Text and the Clipboard Image stays exactly as it was, in history, still
    /// an image. That asymmetry is the whole difference between transforming a
    /// thing and reading something out of it, and it is what someone will try
    /// to unify.
    private func transformEffects(
        _ transform: TextTransform,
        on subject: Subject,
        text: String
    ) -> [Effect] {
        let result = transform.apply(text)

        guard let item = subject.clipboardItem else {
            retarget(at: result, writingTheQuery: true)
            return []
        }

        if let index = history.index(of: item) {
            history.updateText(at: index, text: result)
            clipboardVM.load()
            clipboardVM.selectedIndex = min(index, clipboardVM.filteredItems.count - 1)
            if let updated = history.items.indices.contains(index) ? history.items[index] : nil {
                selectedSubject = clipboardSubject(for: updated)
            }
        }
        phase = .browsingClipboard
        onPhaseChange?()
        return []
    }

    // MARK: - URLs

    /// `.urlQueryAllowed` permits the characters that *separate* query
    /// parameters — `&`, `+`, `=`, `#` — so encoding a value with it silently
    /// truncates anything after an ampersand. A value needs a stricter set.
    private static let queryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return allowed
    }()

    private static func encodeQueryValue(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? text
    }

    static func webSearchURL(for text: String) -> URL? {
        URL(string: "https://www.google.com/search?q=\(encodeQueryValue(text))")
    }

    static func mailtoURL(body: String) -> URL? {
        URL(string: "mailto:?body=\(encodeQueryValue(body))")
    }
}
