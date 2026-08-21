import AppKit
import SwiftUI

class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

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
        // content's job, not the window's.
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

    func setContent<V: View>(_ view: V, withBackground: Bool = true) {
        let hostingView: NSHostingView<AnyView>
        if withBackground {
            hostingView = NSHostingView(
                rootView: AnyView(
                    ThemeWrapper {
                        view
                            .slabSurface()
                    }
                )
            )
        } else {
            hostingView = NSHostingView(rootView: AnyView(ThemeWrapper { view }))
        }
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]

        let container = NSView()
        container.addSubview(hostingView)
        contentView = container
        hostingView.frame = container.bounds
    }
}
