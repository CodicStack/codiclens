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

    var onDismiss: (() -> Void)?
    var onMoveUp: (() -> QuickLookContext?)?
    var onMoveDown: (() -> QuickLookContext?)?

    var isVisible: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared() else { return false }
        return panel.isVisible
    }

    var isTransitioning: Bool { false }

    // MARK: - Public API

    @discardableResult
    func show(context: QuickLookContext) -> Bool {
        guard !context.isEmpty,
              let panel = QLPreviewPanel.shared() else { return false }

        self.context = context
        panel.updateController()
        panel.reloadData()
        panel.currentPreviewItemIndex = context.clampedSelectedIndex
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    func update(context: QuickLookContext) {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible else { return }

        self.context = context
        panel.reloadData()
        panel.currentPreviewItemIndex = context.clampedSelectedIndex
    }

    func dismiss() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared() else { return }
        panel.close()
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
        context = QuickLookContext(items: [], selectedIndex: 0)
        onDismiss?()
    }
}
