import AppKit
import SwiftUI

/// The one Panel — borderless, transparent, and above all non-activating.
///
/// `.nonactivatingPanel` is the contract the app is built on: the Panel floats
/// over whatever is frontmost *without* taking macOS activation from it, which
/// is what lets a synthesised Cmd+V land in the app underneath. Nothing may
/// break that without handing activation back explicitly — see `FocusHandoff`.
///
/// It is sized once to `PanelLayout` and never resized. Most of it is empty
/// space, and clicks on that space must behave like clicks on bare desktop, so
/// the content view refuses to hit-test outside the surfaces themselves.
class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    /// Whether a point in window coordinates lands on something interactive.
    ///
    /// Set by `PanelController` from the layout the SwiftUI content reports.
    /// Nil means "all of it", which is only true before any content is set.
    var acceptsClick: ((NSPoint) -> Bool)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        // Never true. AppKit derives a window shadow from the content's alpha
        // mask, and this Panel's content is transparent glass with soft edges.
        // The result is a ragged wavy contour traced around the content plus a
        // ghost second outline — see docs/DESIGN-HANDOFF.md. Separation is the
        // content's job: each Slab and Card draws its own SwiftUI shadow, which
        // it can now that `PanelLayout.margin` leaves room for one.
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    func setContent<V: View>(_ view: V) {
        let hostingView = NSHostingView(rootView: AnyView(ThemeWrapper { view }))
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]

        let container = PanelContentView()
        container.acceptsClick = { [weak self] point in
            self?.acceptsClick?(point) ?? true
        }
        container.addSubview(hostingView)
        contentView = container
        hostingView.frame = container.bounds
    }
}

/// The Panel's content view, which declines to hit-test its own empty space.
///
/// Without this the SwiftUI hosting view swallows clicks on the margin and on
/// the gap between the Slabs, because it covers the whole Panel. Those clicks
/// have to reach `PanelController`'s dismissal path as "outside" — that is the
/// consequence ADR-0001 signed up for when it made the empty space part of the
/// window.
private final class PanelContentView: NSView {
    var acceptsClick: ((NSPoint) -> Bool)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the superview's coordinates.
        let local = superview.map { convert(point, from: $0) } ?? point
        guard acceptsClick?(local) ?? true else { return nil }
        return super.hitTest(point)
    }
}
