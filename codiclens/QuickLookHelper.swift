import Quartz
import UniformTypeIdentifiers

class QuickLookPreviewItem: NSObject, QLPreviewItem {
    /// The file this item is about. What Effects compare, and what Quick Look
    /// shows unless it cannot draw it (`QuickLookTextCopy`).
    let url: URL
    let title: String?

    /// Where a text copy of `url` may be written, or `nil` to always hand
    /// Quick Look `url` itself.
    private let textCopies: URL?

    /// - Parameter textCopies: where a text copy goes when Quick Look has no
    ///   previewer for `url` but it holds text.
    init(url: URL, title: String? = nil, textCopies: URL? = nil) {
        self.url = url
        self.title = title
        self.textCopies = textCopies
    }

    /// Resolved when Quick Look first asks, not when the item is made: only
    /// the item on screen is ever read or copied.
    private lazy var preview: (url: URL, title: String?) = {
        guard let textCopies, let text = QuickLookTextCopy.text(of: url) else { return (url, title) }
        // A folder of its own per item, so the copy can carry the original's
        // name and two items for the same file never share one.
        let folder = textCopies.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent + ".txt")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.string.write(to: copy, atomically: true, encoding: .utf8)
        } catch {
            return (url, title)
        }
        copyFolder = folder
        let name = title ?? url.lastPathComponent
        return (copy, text.isTruncated ? "\(name) (truncated)" : name)
    }()

    /// The folder holding the copy, once one is written.
    private var copyFolder: URL?

    var previewItemURL: URL! { preview.url }
    var previewItemTitle: String! { preview.title }

    /// The copy lives exactly as long as something can still show it.
    deinit {
        if let copyFolder { try? FileManager.default.removeItem(at: copyFolder) }
    }
}

/// Text Quick Look has no previewer for, shown as a `.txt` copy instead.
///
/// Quick Look picks a previewer by type, and a file the system has no text
/// type for gets nothing: `.vue`, `.svelte`, `.astro`, `.prisma`, `.go`,
/// `.rs`, `.env`, `.gitignore`, `Dockerfile` are dynamic types or plain
/// `public.data` on macOS 26, and `.ts` is declared as an MPEG-2 transport
/// stream, so a TypeScript file opens as a video that will not play. Such a
/// file is read, and if it is text — valid UTF-8, no NUL — Quick Look is shown
/// a copy it can draw. A real transport stream, like any audio or video, fails
/// that on its first bytes.
enum QuickLookTextCopy {
    /// How much of a file the copy holds. A log can run to gigabytes, and the
    /// first 256 KB is more than anyone reads in Quick Look.
    static let byteCap = 256 * 1024

    /// The text to show in place of `url`, or `nil` when Quick Look draws the
    /// file itself, it is not text, or it is not a regular file.
    static func text(of url: URL) -> (string: String, isTruncated: Bool)? {
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        if let type = values.contentType, drawsNatively(type) { return nil }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: byteCap + 1) ?? Data()
        } catch {
            return nil
        }
        let isTruncated = data.count > byteCap
        return decode(data.prefix(byteCap), isTruncated: isTruncated).map { ($0, isTruncated) }
    }

    /// Whether Quick Look has a previewer of its own for `type`.
    ///
    /// Anything text has one. A type the system made up for an unknown
    /// extension, or `public.data`, has none. Audio and video are asked about
    /// too, for `.ts`; every other declared type — images, PDF, documents — is
    /// left to Quick Look and never read, because a PDF can be all ASCII.
    static func drawsNatively(_ type: UTType) -> Bool {
        if type.conforms(to: .text) { return true }
        if type.isDynamic || type == .data { return false }
        return !type.conforms(to: .audiovisualContent)
    }

    /// `bytes` as UTF-8 text, or `nil` if they are not text.
    ///
    /// A cut at `byteCap` can land inside a character, so a truncated read may
    /// drop up to three trailing bytes of one.
    static func decode(_ bytes: Data, isTruncated: Bool) -> String? {
        guard !bytes.contains(0) else { return nil }
        for dropped in 0...(isTruncated ? 3 : 0) {
            if let text = String(validating: bytes.dropLast(dropped), as: UTF8.self) { return text }
        }
        return nil
    }
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

    /// Whether Quick Look has been asked to open or close and is waiting for
    /// Shift to come up first (`whenShiftIsUp`).
    var isTransitioning: Bool { afterShift != nil }

    /// What runs once Shift is up, and the monitors waiting for it.
    private var afterShift: (() -> Void)?
    private var shiftMonitors: [Any] = []

    // MARK: - Public API

    @discardableResult
    func show(context: QuickLookContext) -> Bool {
        guard !context.isEmpty,
              let panel = QLPreviewPanel.shared() else { return false }

        self.context = context
        whenShiftIsUp { [weak self] in
            guard let self else { return }
            panel.reloadData()
            panel.currentPreviewItemIndex = self.context.clampedSelectedIndex
            panel.makeKeyAndOrderFront(nil)
        }
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
        cancelShiftWait()
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared() else { return }
        panel.close()
    }

    /// Runs `action` now, or once Shift is released if it is held.
    ///
    /// AppKit plays a window's animations in slow motion while Shift is down,
    /// and Quick Look's fade is one of them. Shift+Space opens and closes it,
    /// so Shift is always down at that moment: the fade in took ~1.1 s instead
    /// of ~0.2 s, and the fade out with Shift held was still on screen after
    /// 2 s. AppKit reads Shift as the animation starts, so starting it on the
    /// release gets the normal speed.
    ///
    /// The release is a `flagsChanged` event: in this app while the Panel or
    /// Quick Look is the key window, which is always so for Shift+Space, and
    /// in another app's otherwise, which only the global monitor sees. Missing
    /// it would leave Quick Look never opening, so both listen.
    private func whenShiftIsUp(_ action: @escaping () -> Void) {
        cancelShiftWait()
        guard NSEvent.modifierFlags.contains(.shift) else {
            action()
            return
        }
        afterShift = action
        let released: (NSEvent) -> Void = { [weak self] event in
            guard !event.modifierFlags.contains(.shift), let self else { return }
            let action = self.afterShift
            self.cancelShiftWait()
            action?()
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            released(event)
            return event
        }) {
            shiftMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: released) {
            shiftMonitors.append(global)
        }
    }

    private func cancelShiftWait() {
        shiftMonitors.forEach(NSEvent.removeMonitor)
        shiftMonitors = []
        afterShift = nil
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
            return false
        }
        if event.keyCode == 49 && event.modifierFlags.contains(.shift) {
            whenShiftIsUp { panel.close() }
            return true
        }
        if event.keyCode == 126 || event.charactersIgnoringModifiers == "k" {
            if let context = onMoveUp?() {
                update(context: context)
            }
            return true
        }
        if event.keyCode == 125 || event.charactersIgnoringModifiers == "j" {
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
