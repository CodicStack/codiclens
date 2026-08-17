import AppKit
import UniformTypeIdentifiers

@Observable
class CommandCoordinator {
    enum Phase: Equatable {
        case searchingSubject
        case browsingClipboard
        case pickingAction
        case pickingTarget
        case showingResult(String)
    }

    var phase: Phase = .searchingSubject
    var focusTrigger: Bool = false
    var returningFromQuickLook: Bool = false

    private(set) var selectedSubject: Subject?
    private(set) var selectedAction: SubjectAction?
    private(set) var selectedClipboardItem: ClipboardItem?

    let subjectVM = SubjectSearchVM()
    let actionVM = ActionSearchVM()
    let targetVM = TargetSearchVM()
    let clipboardVM: ClipboardSearchVM

    /// Layout only — the card panel resizes when the phase changes.
    var onPhaseChange: (() -> Void)?

    private let runner: EffectRunner
    private let history: ClipboardHistory

    init(runner: EffectRunner, history: ClipboardHistory) {
        self.runner = runner
        self.history = history
        self.clipboardVM = ClipboardSearchVM(history: history)
    }

    var cardCount: Int {
        switch phase {
        case .searchingSubject, .browsingClipboard: 1
        case .pickingAction, .showingResult: 2
        case .pickingTarget: 3
        }
    }

    var isClipboardBrowsing: Bool {
        phase == .browsingClipboard
    }

    var isTextMode: Bool {
        let vm = subjectVM
        guard vm.selectedIndex < vm.results.count else { return false }
        if case .text = vm.results[vm.selectedIndex].kind { return true }
        return false
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
            selectedClipboardItem = item
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
        selectedClipboardItem = ClipboardItem(content: clipboardEditText)
        clipboardVM.load()
    }

    func saveClipboardEditAndAdvance() {
        saveClipboardEdit()
        guard let item = selectedClipboardItem else { return }
        actionVM.loadClipboardActions(for: item)
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

    var currentSelectedIndex: Int {
        get { currentScope?.selectedIndex ?? 0 }
        set { currentScope?.selectedIndex = newValue }
    }

    var currentQuery: String { currentSearchText }

    // MARK: - Navigation

    /// Returns true if Escape was consumed (phase retreated or editor closed).
    /// Returns false if caller should dismiss the panel entirely.
    func handleEscape() -> Bool {
        if isEditingClipboardItem {
            isEditingClipboardItem = false
            focusTrigger.toggle()
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
        case .showingResult, .pickingAction, .browsingClipboard, .searchingSubject:
            return false
        }
    }

    func moveUp() {
        if currentSelectedIndex > 0 {
            currentSelectedIndex -= 1
            if phase == .browsingClipboard { selectedClipboardItem = nil }
        }
    }

    func moveDown() {
        let count = currentResults.count
        if currentSelectedIndex < count - 1 {
            currentSelectedIndex += 1
            if phase == .browsingClipboard { selectedClipboardItem = nil }
        }
    }

    func advancePhase() {
        switch phase {
        case .searchingSubject:
            guard subjectVM.selectedIndex < subjectVM.results.count else { return }
            let subject = subjectVM.results[subjectVM.selectedIndex]
            selectedSubject = subject

            if case .builtIn(.clipboard) = subject.kind {
                clipboardVM.load()
                phase = .browsingClipboard
                onPhaseChange?()
                return
            }

            actionVM.loadActions(for: subject)
            phase = .pickingAction
            onPhaseChange?()

        case .browsingClipboard:
            guard clipboardVM.selectedIndex < clipboardVM.filteredItems.count else { return }
            let item = clipboardVM.filteredItems[clipboardVM.selectedIndex]
            selectedClipboardItem = item
            actionVM.loadClipboardActions(for: item)
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
        case .browsingClipboard:
            phase = .searchingSubject
            onPhaseChange?()
        case .pickingAction:
            if selectedClipboardItem != nil {
                phase = .browsingClipboard
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
            guard subjectVM.selectedIndex < subjectVM.results.count else { return [] }
            let subject = subjectVM.results[subjectVM.selectedIndex]
            if case .builtIn(.clipboard) = subject.kind {
                selectedSubject = subject
                clipboardVM.load()
                phase = .browsingClipboard
                onPhaseChange?()
                return []
            }
            return [.hide] + defaultEffects(for: subject)

        case .browsingClipboard:
            guard clipboardVM.selectedIndex < clipboardVM.filteredItems.count else { return [] }
            return pasteEffects(for: clipboardVM.filteredItems[clipboardVM.selectedIndex])

        case .pickingAction:
            guard actionVM.selectedIndex < actionVM.filteredActions.count else { return [] }
            let action = actionVM.filteredActions[actionVM.selectedIndex]

            if let clipItem = selectedClipboardItem {
                return effects(for: action, on: clipItem)
            }

            guard let subject = selectedSubject else { return [] }
            guard action.isFinal else {
                selectedAction = action
                targetVM.loadTargets(for: subject, action: action)
                phase = .pickingTarget
                onPhaseChange?()
                return []
            }

            // Transforming text feeds the result back in as the new subject,
            // so transforms can be chained without leaving the panel.
            if case .transform(let t) = action.handler, case .text(let rawText) = subject.kind {
                retarget(at: t.apply(rawText))
                return []
            }
            return [.hide] + effects(for: action, on: subject)

        case .pickingTarget:
            guard let subject = selectedSubject,
                  let action = selectedAction,
                  targetVM.selectedIndex < targetVM.filteredTargets.count else { return [] }
            let target = targetVM.filteredTargets[targetVM.selectedIndex]
            return [.hide] + effects(for: action, on: subject, with: target)

        case .showingResult(let result):
            return [.copy(.text(result)), .hide]
        }
    }

    /// Replaces the subject with transformed text and reloads its actions.
    private func retarget(at result: String) {
        let textIcon = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil) ?? NSImage()
        textIcon.size = NSSize(width: 32, height: 32)
        let newSubject = Subject(
            displayName: result,
            path: nil,
            url: nil,
            icon: textIcon,
            kind: .text(rawText: result)
        )
        selectedSubject = newSubject
        subjectVM.searchText = result
        actionVM.loadActions(for: newSubject)
        onPhaseChange?()
    }

    func reset() {
        phase = .searchingSubject
        selectedSubject = nil
        selectedAction = nil
        selectedClipboardItem = nil
        isEditingClipboardItem = false
        clipboardEditText = ""
        subjectVM.isSearchCommitted = true
        actionVM.reset()
        targetVM.reset()
        clipboardVM.reset()
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

    // MARK: - Clipboard execution

    private func payload(for item: ClipboardItem) -> Payload {
        if item.isImage, let imageData = history.imageData(for: item) {
            return .image(imageData)
        }
        return .text(item.content)
    }

    private func pasteEffects(for item: ClipboardItem) -> [Effect] {
        history.moveToTop(item)
        return [.paste(payload(for: item))]
    }

    private func effects(for action: SubjectAction, on item: ClipboardItem) -> [Effect] {
        switch action.handler {
        case .clipboardPaste:
            return pasteEffects(for: item)

        case .clipboardCopy:
            return [.copy(payload(for: item)), .hide]

        case .clipboardPastePlain:
            return [.paste(.text(item.content))]

        case .clipboardTypeText:
            return [.typeText(item.content)]

        case .clipboardRunScript:
            return [.runAppleScript(item.content), .hide]

        case .clipboardOpenEmail:
            guard let url = Self.mailtoURL(body: item.content) else { return [.hide] }
            return [.open(url), .hide]

        case .clipboardDelete:
            history.remove(item)
            clipboardVM.load()
            phase = .browsingClipboard
            onPhaseChange?()
            return []

        case .clipboardOpenPreview:
            guard let url = history.imageURL(for: item) else { return [.hide] }
            return [.open(url), .hide]

        case .clipboardCopyPath:
            guard let path = item.originalFilePath ?? history.imageURL(for: item)?.path else {
                return [.hide]
            }
            return [.copy(.text(path)), .hide]

        case .clipboardSaveImage:
            guard let imageData = history.imageData(for: item) else { return [.hide] }
            return [.savePanel(
                data: imageData,
                fileName: item.imageFileName ?? "image.png",
                contentType: .png
            )]

        case .clipboardSaveFile:
            guard !item.isImage, let textData = item.content.data(using: .utf8) else { return [.hide] }
            return [.savePanel(data: textData, fileName: "untitled.txt", contentType: .plainText)]

        case .clipboardTransform(let transform):
            guard !item.isImage else { return [.hide] }
            applyToHistory(transform, on: item)
            return []

        case .clipboardCount(let countType):
            guard !item.isImage else { return [.hide] }
            phase = .showingResult(countType.count(item.content))
            onPhaseChange?()
            return []

        case .searchWeb:
            guard let url = Self.webSearchURL(for: item.content) else { return [.hide] }
            return [.open(url), .hide]

        case .share:
            guard !action.isFinal else { return [] }
            selectedAction = action
            targetVM.loadShareTargets(for: payload(for: item))
            phase = .pickingTarget
            onPhaseChange?()
            return []

        case .quickLook:
            guard let url = history.previewURL(for: item) else { return [] }
            return [.quickLook(QuickLookContext(
                items: [QuickLookPreviewItem(url: url, title: item.displayName)],
                selectedIndex: 0
            ))]

        default:
            return [.hide]
        }
    }

    /// Rewrites the item in history, then stays in the clipboard browser
    /// with the rewritten item selected.
    private func applyToHistory(_ transform: TextTransform, on item: ClipboardItem) {
        let result = transform.apply(item.content)
        if let index = history.index(of: item) {
            history.updateText(at: index, text: result)
            clipboardVM.load()
            clipboardVM.selectedIndex = min(index, clipboardVM.filteredItems.count - 1)
        }
        selectedClipboardItem = ClipboardItem(content: result)
        phase = .browsingClipboard
        onPhaseChange?()
    }

    // MARK: - Subject execution

    private func defaultEffects(for subject: Subject) -> [Effect] {
        switch subject.kind {
        case .app, .file, .folder:
            guard let url = subject.url else { return [] }
            return [.open(url)]
        case .text(let rawText):
            return [.copy(.text(rawText))]
        case .builtIn(.settings):
            return [.showSettings]
        case .builtIn(.clipboard):
            return []
        }
    }

    private func effects(
        for action: SubjectAction,
        on subject: Subject,
        with target: ActionTarget? = nil
    ) -> [Effect] {
        switch action.handler {
        case .openApp:
            guard let url = subject.url else { return [] }
            return [.open(url)]

        case .openFile:
            guard let url = target?.url ?? subject.url else { return [] }
            return [.open(url)]

        case .quitApp:
            guard case .app(let bundleId, _) = subject.kind, let bundleId else { return [] }
            return [.terminate(bundleIdentifier: bundleId)]

        case .hideApp:
            guard case .app(let bundleId, _) = subject.kind, let bundleId else { return [] }
            return [.hideApplication(bundleIdentifier: bundleId)]

        case .showInFinder, .revealInFinder:
            guard let url = target?.url ?? subject.url else { return [] }
            return [.revealInFinder(url)]

        case .copyPath:
            guard let path = target?.url?.path ?? subject.path else { return [] }
            return [.copy(.text(path))]

        case .openWith:
            guard let appURL = target?.url, let fileURL = subject.url else { return [] }
            return [.openWith(file: fileURL, application: appURL)]

        case .moveToTrash:
            guard let url = target?.url ?? subject.url else { return [] }
            return [.moveToTrash(url)]

        case .quickLook:
            guard let url = target?.url ?? subject.url else { return [] }
            return [.quickLook(QuickLookContext(
                items: [QuickLookPreviewItem(url: url, title: url.lastPathComponent)],
                selectedIndex: 0
            ))]

        case .pasteText:
            guard case .text(let rawText) = subject.kind else { return [] }
            return [.paste(.text(rawText))]

        case .copyText:
            guard case .text(let rawText) = subject.kind else { return [] }
            return [.copy(.text(rawText))]

        case .transform(let t):
            guard case .text(let rawText) = subject.kind else { return [] }
            phase = .showingResult(t.apply(rawText))
            onPhaseChange?()
            return []

        case .searchWeb:
            guard case .text(let rawText) = subject.kind,
                  let url = Self.webSearchURL(for: rawText) else { return [] }
            return [.open(url)]

        case .openURL:
            guard case .text(let rawText) = subject.kind,
                  let url = URL(string: rawText) else { return [] }
            return [.open(url)]

        case .share:
            guard let service = target?.sharingService else { return [] }
            if case .text(let rawText) = subject.kind {
                return [.share(.text(rawText), via: service)]
            }
            guard let url = subject.url else { return [] }
            return [.share(.fileURL(url), via: service)]

        case .openSettings:
            return [.showSettings]

        case .service:
            return []

        default:
            return []
        }
    }

    // MARK: - URLs

    static func webSearchURL(for text: String) -> URL? {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }

    static func mailtoURL(body: String) -> URL? {
        let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body
        return URL(string: "mailto:?body=\(encoded)")
    }
}
