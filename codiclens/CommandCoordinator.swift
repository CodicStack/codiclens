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

    var phase: Phase = .searchingSubject
    var focusTrigger: Bool = false

    private(set) var selectedSubject: Subject?
    private(set) var selectedAction: SubjectAction?

    /// The clipboard entry being acted on, when the selected subject is one.
    var selectedClipboardItem: ClipboardItem? { selectedSubject?.clipboardItem }

    let subjectVM: SubjectSearchVM
    let actionVM = ActionSearchVM()
    let targetVM = TargetSearchVM()
    let clipboardVM: ClipboardSearchVM
    let emojiVM: EmojiSearchVM
    let queryBuffer = QueryBuffer()

    /// Layout only — the card panel resizes when the phase changes.
    var onPhaseChange: (() -> Void)?

    private let runner: EffectRunner
    private let history: ClipboardHistory

    /// - Parameters:
    ///   - emojiVM: injected so tests get their own Recents and preferences
    ///     instead of the ones in Application Support.
    ///   - index: the app Index Subject search matches against. Tests pass an
    ///     Index over no directories, so no test scans `/Applications` or
    ///     starts an FSEvents stream.
    init(
        runner: EffectRunner,
        history: ClipboardHistory,
        emojiVM: EmojiSearchVM = EmojiSearchVM(),
        index: AppIndex = .shared
    ) {
        self.runner = runner
        self.history = history
        self.clipboardVM = ClipboardSearchVM(history: history)
        self.emojiVM = emojiVM
        self.subjectVM = SubjectSearchVM(index: index)
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

    var isTextMode: Bool {
        let results = subjectVM.results
        guard subjectVM.selectedIndex < results.count else { return false }
        if case .text = results[subjectVM.selectedIndex].kind { return true }
        return false
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

    var isEditingClipboardItem: Bool = false
    var clipboardEditText: String = ""

    func toggleClipboardEdit() {
        guard phase == .browsingClipboard else { return }
        if isEditingClipboardItem {
            saveClipboardEdit()
            focusTrigger.toggle()
        } else {
            let item = currentClipboardItem
            guard let item, !item.isImage else { return }
            selectedSubject = Subject(clipboardItem: item)
            clipboardEditText = item.content
            isEditingClipboardItem = true
        }
    }

    func saveClipboardEdit() {
        guard isEditingClipboardItem else { return }
        if let item = selectedClipboardItem ?? currentClipboardItem {
            history.updateText(for: item, text: clipboardEditText)
        }
        isEditingClipboardItem = false
        selectedSubject = Subject(clipboardItem: ClipboardItem(content: clipboardEditText))
        clipboardVM.load()
    }

    func saveClipboardEditAndAdvance() {
        saveClipboardEdit()
        guard let subject = selectedSubject else { return }
        actionVM.loadActions(for: subject)
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
        guard phase == .searchingSubject else { return currentScope?.displayResults ?? [] }
        // Same visibility gate `SubjectSearchVM` applies to its own results.
        return subjectVM.isResultsVisible ? subjectVM.results.map { ResultDisplayItem(from: $0) } : []
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
    /// then "n", and the search is "n" — not "safn". Text mode is exempt,
    /// because there the query is the content being edited rather than a way
    /// of finding something.
    /// - Returns: the text the field should now show, which differs from what
    ///   was typed whenever a settled query has just been replaced.
    @discardableResult
    func acceptTypedText(_ typed: String) -> String {
        let startsNewQuery = phase == .searchingSubject
            && subjectVM.isSearchCommitted
            && !isTextMode

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
        if isEditingClipboardItem {
            isEditingClipboardItem = false
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
        case .searchingSubject where isTextMode:
            subjectVM.reset()
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
            let results = subjectVM.results
            guard subjectVM.selectedIndex < results.count else { return }
            let subject = results[subjectVM.selectedIndex]
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
            let subject = Subject(clipboardItem: clipboardVM.filteredItems[clipboardVM.selectedIndex])
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
                targetVM.loadTargets(for: subject, action: action)
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
            if selectedClipboardItem != nil {
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

    /// Advances the machine and hands the resulting effects to the runner.
    /// The effects are returned too, so tests can assert on them directly.
    @discardableResult
    func submit() -> [Effect] {
        let effects = submitEffects()
        runner.run(effects)
        return effects
    }

    private func submitEffects() -> [Effect] {
        switch phase {
        case .searchingSubject:
            let results = subjectVM.results
            guard subjectVM.selectedIndex < results.count else { return [] }
            let subject = results[subjectVM.selectedIndex]
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
            return defaultEffects(for: subject)

        case .browsingEmoji:
            guard let emoji = emojiVM.resolvedSelection else { return [] }
            emojiVM.recordSelectionUse()
            emojiVM.closeTonePicker()
            let subject = Subject(emoji: emoji)
            selectedSubject = subject
            return defaultEffects(for: subject)

        case .browsingClipboard:
            guard clipboardVM.selectedIndex < clipboardVM.filteredItems.count else { return [] }
            let subject = Subject(clipboardItem: clipboardVM.filteredItems[clipboardVM.selectedIndex])
            selectedSubject = subject
            return defaultEffects(for: subject)

        case .pickingAction:
            guard actionVM.selectedIndex < actionVM.filteredActions.count else { return [] }
            let action = actionVM.filteredActions[actionVM.selectedIndex]
            guard let subject = selectedSubject else { return [] }
            guard action.isFinal else {
                selectedAction = action
                targetVM.loadTargets(for: subject, action: action)
                phase = .pickingTarget
                onPhaseChange?()
                return []
            }
            return effects(for: action, on: subject)

        case .pickingTarget:
            guard let subject = selectedSubject,
                  let action = selectedAction,
                  targetVM.selectedIndex < targetVM.filteredTargets.count else { return [] }
            let target = targetVM.filteredTargets[targetVM.selectedIndex]
            return effects(for: action, on: subject, with: target)

        case .showingResult(let result):
            return [.copy(.text(result)), .hide]
        }
    }

    /// Replaces the subject with transformed text and reloads its actions.
    private func retarget(at result: String) {
        let newSubject = Subject(text: result)
        selectedSubject = newSubject
        subjectVM.searchText = result
        actionVM.loadActions(for: newSubject)
        syncQueryDisplay()
        onPhaseChange?()
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
        isEditingClipboardItem = false
        clipboardEditText = ""
        subjectVM.isSearchCommitted = true
        actionVM.reset()
        targetVM.reset()
        clipboardVM.reset()
        emojiVM.reset()

        if wantsEmojiMode {
            wantsEmojiMode = false
            enterEmojiMode()
        }

        syncQueryDisplay()
        focusTrigger.toggle()
    }

    func triggerQuickLook() {
        guard let context = quickLookContext() else { return }
        runner.run([.quickLook(context)])
    }

    func quickLookContext() -> QuickLookContext? {
        switch phase {
        case .pickingTarget:
            let targets = targetVM.filteredTargets
            guard targetVM.selectedIndex < targets.count,
                  let url = targets[targetVM.selectedIndex].url else { return nil }
            let item = QuickLookPreviewItem(url: url, title: targets[targetVM.selectedIndex].name)
            return QuickLookContext(items: [item], selectedIndex: 0)

        case .browsingClipboard:
            let items = clipboardVM.filteredItems
            guard clipboardVM.selectedIndex < items.count,
                  let url = history.previewURL(for: items[clipboardVM.selectedIndex]) else { return nil }
            let item = QuickLookPreviewItem(url: url, title: items[clipboardVM.selectedIndex].displayName)
            return QuickLookContext(items: [item], selectedIndex: 0)

        default:
            return nil
        }
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

    /// The plain text behind a subject, where it has any.
    private func plainText(for subject: Subject) -> String? {
        switch subject.kind {
        case .clipboard(let item): item.isImage ? nil : item.content
        case .text(let rawText): rawText
        case .emoji(let emoji): emoji.string
        default: nil
        }
    }

    /// The file a subject points at: its own URL, or the stored image for a
    /// clipboard entry.
    private func fileURL(for subject: Subject, target: ActionTarget? = nil) -> URL? {
        if let targetURL = target?.url { return targetURL }
        if case .clipboard(let item) = subject.kind {
            return history.imageURL(for: item) ?? item.originalFileURL
        }
        return subject.url
    }

    private func defaultEffects(for subject: Subject) -> [Effect] {
        switch subject.kind {
        case .app, .file, .folder:
            guard let url = subject.url else { return [.hide] }
            return [.hide, .open(url)]
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
            return [.hide, .open(url)]

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

        case .quickLook:
            guard let url = quickLookURL(for: subject, target: target) else { return [] }
            return [.quickLook(QuickLookContext(
                items: [QuickLookPreviewItem(url: url, title: subject.displayName)],
                selectedIndex: 0
            ))]

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
            guard let service = target?.sharingService, let payload = payload(for: subject) else {
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
            history.remove(item)
            clipboardVM.load()
            selectedSubject = nil
            phase = .browsingClipboard
            onPhaseChange?()
            return []

        // MARK: Codiclens

        case .openSettings:
            return [.hide, .showSettings]

        case .service:
            return []
        }
    }

    private func quickLookURL(for subject: Subject, target: ActionTarget?) -> URL? {
        if let targetURL = target?.url { return targetURL }
        if case .clipboard(let item) = subject.kind {
            return history.previewURL(for: item)
        }
        return subject.url
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
    private func transformEffects(
        _ transform: TextTransform,
        on subject: Subject,
        text: String
    ) -> [Effect] {
        let result = transform.apply(text)

        guard let item = subject.clipboardItem else {
            retarget(at: result)
            return []
        }

        if let index = history.index(of: item) {
            history.updateText(at: index, text: result)
            clipboardVM.load()
            clipboardVM.selectedIndex = min(index, clipboardVM.filteredItems.count - 1)
            if let updated = history.items.indices.contains(index) ? history.items[index] : nil {
                selectedSubject = Subject(clipboardItem: updated)
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
