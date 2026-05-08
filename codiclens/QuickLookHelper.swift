import Quartz

class QuickLookPreviewItem: NSObject, QLPreviewItem {
    let url: URL
    let title: String?

    init(url: URL, title: String? = nil) {
        self.url = url
        self.title = title
    }

    var previewItemURL: URL! { url }
    var previewItemTitle: String! { title }
}

struct QuickLookContext {
    let items: [QuickLookPreviewItem]
    let selectedIndex: Int

    var isEmpty: Bool {
        items.isEmpty
    }

    var clampedSelectedIndex: Int {
        guard !items.isEmpty else { return 0 }
        return min(max(selectedIndex, 0), items.count - 1)
    }
}

class QuickLookHelper: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var context = QuickLookContext(items: [], selectedIndex: 0)
    private var isDismissing = false
    private var reloadGeneration = 0
    var onDismiss: (() -> Void)?
    var onMoveUp: (() -> QuickLookContext?)?
    var onMoveDown: (() -> QuickLookContext?)?

    var isVisible: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared() else { return false }
        return panel.isVisible
    }

    var isTransitioning: Bool {
        isDismissing
    }

    @discardableResult
    func show(context: QuickLookContext) -> Bool {
        guard !context.isEmpty,
              let panel = QLPreviewPanel.shared() else {
            self.context = QuickLookContext(items: [], selectedIndex: 0)
            return false
        }

        showFresh(context: context, panel: panel)
        return true
    }

    func update(context: QuickLookContext) {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible else { return }

        let oldSelectedURL = selectedURL(in: self.context)
        let newSelectedURL = selectedURL(in: context)

        if oldSelectedURL != newSelectedURL {
            showFresh(context: context, panel: panel)
        } else {
            self.context = context
            panel.currentPreviewItemIndex = context.clampedSelectedIndex
        }
    }

    func dismiss() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared() else { return }
        isDismissing = true
        clearPanel(panel)
        panel.close()
        isDismissing = false
    }

    // MARK: - Data Source

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        context.items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard context.items.indices.contains(index) else { return nil }
        return context.items[index]
    }

    // MARK: - Delegate

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 53 {
            onDismiss?()
            return true
        }
        if event.keyCode == 49 && event.modifierFlags.contains(.control) {
            onDismiss?()
            return true
        }
        if event.keyCode == 126 || (event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "k") {
            if let context = onMoveUp?() {
                update(context: context)
            }
            return true
        }
        if event.keyCode == 125 || (event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "j") {
            if let context = onMoveDown?() {
                update(context: context)
            }
            return true
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard !isDismissing else { return }
        context = QuickLookContext(items: [], selectedIndex: 0)
        onDismiss?()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isDismissing else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.isDismissing,
                  !self.isVisible else { return }
            self.context = QuickLookContext(items: [], selectedIndex: 0)
            self.onDismiss?()
        }
    }

    private func selectedURL(in context: QuickLookContext) -> URL? {
        guard context.items.indices.contains(context.clampedSelectedIndex) else { return nil }
        return context.items[context.clampedSelectedIndex].url
    }

    private func showFresh(context: QuickLookContext, panel: QLPreviewPanel) {
        reloadGeneration += 1
        let generation = reloadGeneration

        isDismissing = true
        clearPanel(panel)
        panel.close()

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  generation == self.reloadGeneration,
                  let panel = QLPreviewPanel.shared() else {
                self?.isDismissing = false
                return
            }

            self.context = context
            panel.updateController()
            panel.displayState = nil
            panel.reloadData()
            panel.currentPreviewItemIndex = context.clampedSelectedIndex
            panel.makeKeyAndOrderFront(nil)
            self.isDismissing = false
        }
    }

    private func clearPanel(_ panel: QLPreviewPanel) {
        context = QuickLookContext(items: [], selectedIndex: 0)
        panel.displayState = nil
        panel.reloadData()
        panel.currentPreviewItemIndex = NSNotFound
    }
}
