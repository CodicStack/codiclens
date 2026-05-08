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
    let clipboardVM = ClipboardSearchVM()

    var onHide: (() -> Void)?
    var onPhaseChange: (() -> Void)?
    var onQuickLook: ((QuickLookContext) -> Void)?
    var onShowSettings: (() -> Void)?

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
        if let item = selectedClipboardItem ?? currentClipboardItem,
           let idx = ClipboardManager.shared.items.firstIndex(where: { $0.id == item.id }) {
            ClipboardManager.shared.updateText(at: idx, text: clipboardEditText)
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

    var currentSearchText: String {
        get {
            switch phase {
            case .searchingSubject: subjectVM.searchText
            case .browsingClipboard: clipboardVM.searchText
            case .pickingAction: actionVM.searchText
            case .pickingTarget: targetVM.searchText
            case .showingResult: ""
            }
        }
        set {
            switch phase {
            case .searchingSubject: subjectVM.searchText = newValue
            case .browsingClipboard: clipboardVM.searchText = newValue
            case .pickingAction: actionVM.searchText = newValue
            case .pickingTarget: targetVM.searchText = newValue
            case .showingResult: break
            }
        }
    }

    var currentResults: [ResultDisplayItem] {
        switch phase {
        case .searchingSubject:
            subjectVM.isResultsVisible
                ? subjectVM.results.map { ResultDisplayItem(from: $0) }
                : []
        case .browsingClipboard:
            clipboardVM.filteredItems.map { ResultDisplayItem(from: $0) }
        case .pickingAction:
            actionVM.filteredActions.map { ResultDisplayItem(from: $0) }
        case .pickingTarget:
            targetVM.filteredTargets.map { ResultDisplayItem(from: $0) }
        case .showingResult:
            []
        }
    }

    var currentSelectedIndex: Int {
        get {
            switch phase {
            case .searchingSubject: subjectVM.selectedIndex
            case .browsingClipboard: clipboardVM.selectedIndex
            case .pickingAction: actionVM.selectedIndex
            case .pickingTarget: targetVM.selectedIndex
            case .showingResult: 0
            }
        }
        set {
            switch phase {
            case .searchingSubject: subjectVM.selectedIndex = newValue
            case .browsingClipboard: clipboardVM.selectedIndex = newValue
            case .pickingAction: actionVM.selectedIndex = newValue
            case .pickingTarget: targetVM.selectedIndex = newValue
            case .showingResult: break
            }
        }
    }

    var currentQuery: String {
        switch phase {
        case .searchingSubject: subjectVM.searchText
        case .browsingClipboard: clipboardVM.searchText
        case .pickingAction: actionVM.searchText
        case .pickingTarget: targetVM.searchText
        case .showingResult: ""
        }
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

        switch phase {
        case .pickingTarget:
            retreatPhase()
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

    func submit() {
        switch phase {
        case .searchingSubject:
            guard subjectVM.selectedIndex < subjectVM.results.count else { return }
            let subject = subjectVM.results[subjectVM.selectedIndex]
            if case .builtIn(.clipboard) = subject.kind {
                selectedSubject = subject
                clipboardVM.load()
                phase = .browsingClipboard
                onPhaseChange?()
            } else {
                executeDefaultAction(for: subject)
                onHide?()
            }

        case .browsingClipboard:
            guard clipboardVM.selectedIndex < clipboardVM.filteredItems.count else { return }
            let item = clipboardVM.filteredItems[clipboardVM.selectedIndex]
            pasteClipboardItem(item)
            onHide?()

        case .pickingAction:
            guard actionVM.selectedIndex < actionVM.filteredActions.count else { return }
            let action = actionVM.filteredActions[actionVM.selectedIndex]

            if let clipItem = selectedClipboardItem {
                executeClipboardAction(action, on: clipItem)
                return
            }

            guard let subject = selectedSubject else { return }
            if action.isFinal {
                if case .transform(let t) = action.handler, case .text(let rawText) = subject.kind {
                    let result = t.apply(rawText)
                    phase = .showingResult(result)
                    onPhaseChange?()
                } else {
                    executeAction(action, on: subject)
                    onHide?()
                }
            } else {
                selectedAction = action
                targetVM.loadTargets(for: subject, action: action)
                phase = .pickingTarget
                onPhaseChange?()
            }

        case .pickingTarget:
            guard let subject = selectedSubject,
                  let action = selectedAction,
                  targetVM.selectedIndex < targetVM.filteredTargets.count else { return }
            let target = targetVM.filteredTargets[targetVM.selectedIndex]
            executeAction(action, on: subject, with: target)
            onHide?()

        case .showingResult(let result):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result, forType: .string)
            onHide?()
        }
    }

    func reset() {
        phase = .searchingSubject
        selectedSubject = nil
        selectedAction = nil
        selectedClipboardItem = nil
        isEditingClipboardItem = false
        clipboardEditText = ""
        subjectVM.isResultsVisible = false
        subjectVM.isSearchCommitted = false
        actionVM.reset()
        targetVM.reset()
        clipboardVM.reset()
        focusTrigger.toggle()
    }

    func triggerQuickLook() {
        guard let context = quickLookContext() else { return }
        onQuickLook?(context)
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
                  let url = ClipboardManager.shared.previewURL(for: items[clipboardVM.selectedIndex]) else { return nil }
            let item = QuickLookPreviewItem(url: url, title: items[clipboardVM.selectedIndex].displayName)
            return QuickLookContext(items: [item], selectedIndex: 0)

        default:
            return nil
        }
    }

    // MARK: - Clipboard Actions

    private func pasteClipboardItem(_ item: ClipboardItem) {
        NSPasteboard.general.clearContents()
        if item.isImage, let imageData = ClipboardManager.shared.imageData(for: item) {
            NSPasteboard.general.setData(imageData, forType: .png)
        } else {
            NSPasteboard.general.setString(item.content, forType: .string)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Self.simulatePaste()
        }
    }

    private func executeClipboardAction(_ action: SubjectAction, on item: ClipboardItem) {
        switch action.handler {
        case .clipboardPaste:
            pasteClipboardItem(item)
            onHide?()

        case .clipboardCopy:
            NSPasteboard.general.clearContents()
            if item.isImage, let imageData = ClipboardManager.shared.imageData(for: item) {
                NSPasteboard.general.setData(imageData, forType: .png)
            } else {
                NSPasteboard.general.setString(item.content, forType: .string)
            }
            onHide?()

        case .clipboardPastePlain:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.content, forType: .string)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                Self.simulatePaste()
            }
            onHide?()

        case .clipboardTypeText:
            onHide?()
            let text = item.content
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                Self.simulateTyping(text)
            }

        case .clipboardRunScript:
            let script = NSAppleScript(source: item.content)
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            onHide?()

        case .clipboardOpenEmail:
            let encoded = item.content.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.content
            if let url = URL(string: "mailto:?body=\(encoded)") {
                NSWorkspace.shared.open(url)
            }
            onHide?()

        case .clipboardDelete:
            if let idx = ClipboardManager.shared.items.firstIndex(where: { $0.id == item.id }) {
                ClipboardManager.shared.remove(at: idx)
            }
            clipboardVM.load()
            phase = .browsingClipboard
            onPhaseChange?()

        case .clipboardOpenPreview:
            if let fileName = item.imageFileName {
                let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                let url = dir.appendingPathComponent("codiclens/images/\(fileName)")
                NSWorkspace.shared.open(url)
            }
            onHide?()

        case .clipboardCopyPath:
            if let path = item.originalFilePath {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            } else if let fileName = item.imageFileName {
                let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                let url = dir.appendingPathComponent("codiclens/images/\(fileName)")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
            onHide?()

        case .clipboardSaveImage:
            guard let imageData = ClipboardManager.shared.imageData(for: item) else { onHide?(); return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = item.imageFileName ?? "image.png"
            panel.canCreateDirectories = true
            if panel.runModal() == .OK, let url = panel.url {
                try? imageData.write(to: url, options: .atomic)
            }
            onHide?()

        case .clipboardTransform(let transform):
            guard !item.isImage else { onHide?(); return }
            let result = transform.apply(item.content)
            if let idx = ClipboardManager.shared.items.firstIndex(where: { $0.id == item.id }) {
                ClipboardManager.shared.updateText(at: idx, text: result)
                clipboardVM.load()
                clipboardVM.selectedIndex = min(idx, clipboardVM.filteredItems.count - 1)
            }
            selectedClipboardItem = ClipboardItem(content: result)
            phase = .browsingClipboard
            onPhaseChange?()

        case .clipboardCount(let countType):
            guard !item.isImage else { onHide?(); return }
            let result = countType.count(item.content)
            phase = .showingResult(result)
            onPhaseChange?()

        case .searchWeb:
            let encoded = item.content.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.content
            if let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
                NSWorkspace.shared.open(url)
            }
            onHide?()

        case .share:
            if !action.isFinal {
                selectedAction = action
                // Create share targets
                let items: [Any] = item.isImage
                    ? (ClipboardManager.shared.imageData(for: item).map { [NSImage(data: $0) as Any] } ?? [])
                    : [item.content as NSString]
                let targets = NSSharingService.sharingServices(forItems: items).map { service in
                    let icon = service.image ?? NSImage()
                    icon.size = NSSize(width: 32, height: 32)
                    return ActionTarget(name: service.title, icon: icon, url: nil, sharingService: service)
                }
                targetVM.allTargets = targets
                targetVM.filteredTargets = targets
                targetVM.selectedIndex = 0
                phase = .pickingTarget
                onPhaseChange?()
            }

        case .quickLook:
            if let url = ClipboardManager.shared.previewURL(for: item) {
                onQuickLook?(QuickLookContext(
                    items: [QuickLookPreviewItem(url: url, title: item.displayName)],
                    selectedIndex: 0
                ))
            }

        default:
            onHide?()
        }
    }

    // MARK: - Standard Execution

    private func executeDefaultAction(for subject: Subject) {
        switch subject.kind {
        case .app, .file, .folder:
            if let url = subject.url {
                NSWorkspace.shared.open(url)
            }
        case .text(let rawText):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rawText, forType: .string)
        case .builtIn(.settings):
            onShowSettings?()
        case .builtIn(.clipboard):
            break
        }
    }

    private func executeAction(_ action: SubjectAction, on subject: Subject, with target: ActionTarget? = nil) {
        switch action.handler {
        case .openApp:
            if let url = subject.url { NSWorkspace.shared.open(url) }

        case .openFile:
            if let url = target?.url ?? subject.url { NSWorkspace.shared.open(url) }

        case .quitApp:
            if case .app(let bundleId, _) = subject.kind, let bundleId {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.terminate()
            }

        case .hideApp:
            if case .app(let bundleId, _) = subject.kind, let bundleId {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.hide()
            }

        case .showInFinder, .revealInFinder:
            if let url = target?.url ?? subject.url {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }

        case .copyPath:
            if let path = target?.url?.path ?? subject.path {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }

        case .openWith:
            if let target, let appURL = target.url, let fileURL = subject.url {
                let config = NSWorkspace.OpenConfiguration()
                Task { try? await NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: config) }
            }

        case .moveToTrash:
            if let url = target?.url ?? subject.url {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }

        case .quickLook:
            if let url = target?.url ?? subject.url {
                onQuickLook?(QuickLookContext(
                    items: [QuickLookPreviewItem(url: url, title: url.lastPathComponent)],
                    selectedIndex: 0
                ))
            }

        case .copyText:
            if case .text(let rawText) = subject.kind {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rawText, forType: .string)
            }

        case .transform(let t):
            if case .text(let rawText) = subject.kind {
                let result = t.apply(rawText)
                phase = .showingResult(result)
                onPhaseChange?()
                return
            }

        case .searchWeb:
            if case .text(let rawText) = subject.kind {
                let encoded = rawText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rawText
                if let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
                    NSWorkspace.shared.open(url)
                }
            }

        case .openURL:
            if case .text(let rawText) = subject.kind, let url = URL(string: rawText) {
                NSWorkspace.shared.open(url)
            }

        case .share:
            if let target, let service = target.sharingService {
                switch subject.kind {
                case .text(let rawText):
                    service.perform(withItems: [rawText as NSString])
                default:
                    if let url = subject.url { service.perform(withItems: [url]) }
                }
            }

        case .service:
            break

        case .openSettings:
            onShowSettings?()

        default:
            break
        }
    }

    // MARK: - Input Simulation

    static func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = CGEventFlags.maskCommand
        keyUp?.flags = CGEventFlags.maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }

    private static func simulateTyping(_ text: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let source = CGEventSource(stateID: .combinedSessionState)
            for char in text {
                var utf16 = Array(String(char).utf16)
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { continue }
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                event.post(tap: .cgSessionEventTap)
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                up?.post(tap: .cgSessionEventTap)
                usleep(10_000)
            }
        }
    }
}
