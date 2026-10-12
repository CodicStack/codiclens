import AVKit
import PDFKit
import SwiftUI

/// The keys the Panel's own preview answers while it is open. The hidden
/// field keeps the keyboard (`CardContainerView`), and sends these here; the
/// document on screen does what they mean for it.
@MainActor
protocol PassagePreviewKeys: AnyObject {
    /// Up and Down: a few lines.
    func scroll(by lines: Int)
    /// Left and Right: a PDF's page, a recording's few seconds.
    func step(by steps: Int)
    /// Space: play or pause, or a screenful down.
    func space()
}

/// Where the hidden field's keys reach the preview. One per Panel, made by
/// `PanelView` and handed to both; the document view on screen registers
/// itself as it is made.
final class PassagePreviewDriver {
    weak var target: PassagePreviewKeys?

    func scroll(by lines: Int) { target?.scroll(by: lines) }
    func step(by steps: Int) { target?.step(by: steps) }
    func space() { target?.space() }
}

/// The Panel's own preview of a File Result, in place of the Results Slab:
/// the file at its Passage (`PassagePreview`). Its name and where it matched
/// along the top, and the document under them.
///
/// **In the Panel, so nothing changes hands.** The Panel is non-activating
/// and the keyboard stays in the hidden field: no document view here can
/// become first responder, so a click scrolls or plays and never takes the
/// keys. Quick Look is a window of its own and has to activate the app; this
/// does not, so there is nothing for `FocusHandoff` to give back.
struct PassagePreviewView: View {
    let preview: PassagePreview
    let driver: PassagePreviewDriver

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(preview.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let location = preview.locationLabel {
                    Text(location)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                KeyHintChip(keys: "⇧Space")
            }
            .padding(.horizontal, Style.padding)
            .frame(height: PanelLayout.resultsHeaderHeight)

            document
                .padding([.horizontal, .bottom], Style.previewInset)
        }
    }

    @ViewBuilder
    private var document: some View {
        switch preview.kind {
        case .pdf:
            PassagePDF(preview: preview, driver: driver)
        case .text(let monospaced):
            PassageText(preview: preview, monospaced: monospaced, driver: driver)
        case .media(let seconds, _):
            PassagePlayer(url: preview.url, seconds: seconds, driver: driver)
        }
    }
}

// MARK: - PDF

private struct PassagePDF: NSViewRepresentable {
    let preview: PassagePreview
    let driver: PassagePreviewDriver

    func makeNSView(context: Context) -> PassagePDFView {
        let view = PassagePDFView()
        view.show(preview.url, at: preview.passage)
        driver.target = view
        return view
    }

    func updateNSView(_ view: PassagePDFView, context: Context) {
        driver.target = view
    }
}

/// `PDFView` at the Passage's page, its matched words highlighted and
/// scrolled to.
final class PassagePDFView: PDFView, PassagePreviewKeys {
    /// Where to scroll once the view has a size to scroll in: `go(to:)`
    /// before the first layout lands on a page laid out at no size.
    private var pending: (page: PDFPage, focus: PDFSelection?)?

    /// The matched words, as `highlightedSelections` holds them.
    private(set) var marks: [PDFSelection] = []

    override var acceptsFirstResponder: Bool { false }

    func show(_ url: URL, at passage: SubjectPassage) {
        autoScales = true
        displayMode = .singlePageContinuous
        displaysPageBreaks = true
        backgroundColor = .clear
        wantsLayer = true
        layer?.cornerRadius = Style.previewDocumentRadius
        layer?.masksToBounds = true

        guard let document = PDFDocument(url: url) else { return }
        self.document = document
        guard let found = PassageFind.selections(in: document, for: passage) else { return }
        for mark in found.marks { mark.color = Style.passageHighlight }
        marks = found.marks
        highlightedSelections = found.marks
        pending = (found.page, found.focus)
    }

    override func layout() {
        super.layout()
        guard let target = pending, !bounds.isEmpty else { return }
        pending = nil
        if let focus = target.focus {
            go(to: focus)
        } else {
            go(to: target.page)
        }
    }

    func scroll(by lines: Int) {
        documentView?.enclosingScrollView?.scrollDocument(by: CGFloat(lines) * Self.lineStep)
    }

    func step(by steps: Int) {
        steps < 0 ? goToPreviousPage(nil) : goToNextPage(nil)
    }

    func space() {
        guard let scrollView = documentView?.enclosingScrollView else { return }
        scrollView.scrollDocument(by: scrollView.contentView.bounds.height * 0.9)
    }

    static let lineStep: CGFloat = 48
}

// MARK: - Text

private struct PassageText: NSViewRepresentable {
    let preview: PassagePreview
    let monospaced: Bool
    let driver: PassagePreviewDriver

    func makeNSView(context: Context) -> PassageTextView {
        let view = PassageTextView(monospaced: monospaced)
        view.show(preview.url, at: preview.passage)
        driver.target = view
        return view
    }

    func updateNSView(_ view: PassageTextView, context: Context) {
        driver.target = view
    }
}

/// The text the File Index read from the file, read-only, scrolled so the
/// Passage is in the middle, its matched words highlighted.
///
/// Not selectable: a selectable text view takes first responder on a click,
/// and the keyboard belongs to the hidden field.
final class PassageTextView: NSScrollView, PassagePreviewKeys {
    let textView = NSTextView()
    private let font: NSFont
    /// The Passage, to scroll to once there is text and a size to scroll in.
    private var pending: NSRange?
    /// The matched words, as the text holds them.
    private(set) var marks: [NSRange] = []
    private var reading: Task<Void, Never>?

    init(monospaced: Bool) {
        font = monospaced
            ? .monospacedSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 13)
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        wantsLayer = true
        layer?.cornerRadius = Style.previewDocumentRadius
        layer?.masksToBounds = true

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 10)
        // Apple's recipe for a text view in a scroll view: as tall as its
        // text, as wide as the scroll view.
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        documentView = textView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { reading?.cancel() }

    func show(_ url: URL, at passage: SubjectPassage) {
        reading = Task { [weak self] in
            let read = await Self.read(url, passage)
            guard !Task.isCancelled, let self, let read else { return }
            self.present(read.text, found: read.found)
        }
    }

    /// The file's text and the Passage in it, off the main thread: a note
    /// can be 10 MB.
    @concurrent
    nonisolated private static func read(_ url: URL, _ passage: SubjectPassage)
        async -> (text: String, found: (focus: NSRange, marks: [NSRange])?)? {
        guard let text = PassageTextReader.read(url) else { return nil }
        let found = PassageFind.find(passage, in: text).map {
            (NSRange($0.focus, in: text), $0.marks.map { NSRange($0, in: text) })
        }
        return (text, found)
    }

    func present(_ text: String, found: (focus: NSRange, marks: [NSRange])?) {
        let storage = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
        for mark in found?.marks ?? [] {
            storage.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .backgroundColor: Style.passageHighlight,
                .foregroundColor: NSColor.black
            ], range: mark)
        }
        marks = found?.marks ?? []
        textView.textStorage?.setAttributedString(storage)
        pending = found?.focus
        revealIfLaidOut()
    }

    override func layout() {
        super.layout()
        revealIfLaidOut()
    }

    private func revealIfLaidOut() {
        guard let range = pending, !contentView.bounds.isEmpty else { return }
        pending = nil
        textView.scrollRangeToVisible(range)
        guard let rect = textRect(range) else { return }
        // Into the middle, not onto the edge `scrollRangeToVisible` stops at.
        scrollDocument(by: rect.midY - contentView.bounds.midY)
    }

    /// Where `range` is drawn, in the text view.
    private func textRect(_ range: NSRange) -> CGRect? {
        guard let layout = textView.textLayoutManager,
              let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return nil }
        layout.ensureLayout(for: textRange)
        var rect = CGRect.null
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            rect = rect.union(frame)
            return true
        }
        guard !rect.isNull else { return nil }
        let origin = textView.textContainerOrigin
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    func scroll(by lines: Int) {
        scrollDocument(by: CGFloat(lines) * (font.boundingRectForFont.height * 3))
    }

    func step(by steps: Int) {}

    func space() {
        scrollDocument(by: contentView.bounds.height * 0.9)
    }
}

// MARK: - Video and audio

private struct PassagePlayer: NSViewRepresentable {
    let url: URL
    let seconds: Double
    let driver: PassagePreviewDriver

    func makeNSView(context: Context) -> PassagePlayerView {
        let view = PassagePlayerView()
        view.start(url, at: seconds)
        driver.target = view
        return view
    }

    func updateNSView(_ view: PassagePlayerView, context: Context) {
        driver.target = view
    }

    /// The preview closing, or the Panel going: nothing plays on behind it.
    static func dismantleNSView(_ view: PassagePlayerView, coordinator: ()) {
        view.stop()
    }
}

/// `AVPlayerView` playing from the Passage's second.
final class PassagePlayerView: AVPlayerView, PassagePreviewKeys {
    override var acceptsFirstResponder: Bool { false }

    func start(_ url: URL, at seconds: Double) {
        controlsStyle = .inline
        wantsLayer = true
        layer?.cornerRadius = Style.previewDocumentRadius
        layer?.masksToBounds = true
        let player = AVPlayer(url: url)
        self.player = player
        // Exact, unlike the Card's frame: playing from a keyframe before it
        // would start on words the Passage is not.
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            guard finished else { return }
            DispatchQueue.main.async { player.play() }
        }
    }

    func stop() {
        player?.pause()
        player = nil
    }

    func scroll(by lines: Int) {}

    /// A few seconds back or on.
    func step(by steps: Int) {
        guard let player else { return }
        let time = player.currentTime().seconds + Double(steps) * Self.skip
        player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600))
    }

    func space() {
        guard let player else { return }
        player.timeControlStatus == .paused ? player.play() : player.pause()
    }

    static let skip: Double = 5
}

// MARK: -

extension NSScrollView {
    /// Scrolls the document by `points`, down for a positive amount, clamped
    /// to its ends.
    func scrollDocument(by points: CGFloat) {
        guard let documentView else { return }
        let clip = contentView
        let maxY = max(0, documentView.frame.height - clip.bounds.height)
        var origin = clip.bounds.origin
        let distance = documentView.isFlipped ? points : -points
        origin.y = min(max(origin.y + distance, 0), maxY)
        clip.scroll(to: origin)
        reflectScrolledClipView(clip)
    }
}
