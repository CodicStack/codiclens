import AppKit
import Quartz
import SwiftUI

class PanelController {
    private let cardPanel: FloatingPanel
    private let resultsPanel: FloatingPanel
    private var settingsWindow: NSWindow?
    let coordinator: CommandCoordinator
    private var clickMonitor: Any?
    private var deactivationObserver: Any?
    private var resultsObservation: Any?
    private let quickLookHelper = QuickLookHelper()
    private(set) var quickLookActive = false
    private var showResultsWork: DispatchWorkItem?
    private var animatingTargetWidth: CGFloat?
    private var animatingTargetOriginX: CGFloat?

    private let cardWidth: CGFloat = 260
    private let cardHeight: CGFloat = 240

    init() {
        let initialWidth: CGFloat = 280
        coordinator = CommandCoordinator()
        cardPanel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: 240))
        resultsPanel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: 300))

        coordinator.onHide = { [weak self] in
            self?.hidePanel()
        }

        coordinator.onPhaseChange = { [weak self] in
            self?.animateCardCount()
        }

        coordinator.onShowSettings = { [weak self] in
            self?.showSettings()
        }

        quickLookHelper.onDismiss = { [weak self] in
            self?.quickLookDidClose()
        }

        quickLookHelper.onMoveUp = { [weak self] in
            guard let self else { return nil }
            self.coordinator.moveUp()
            return self.coordinator.quickLookContext()
        }

        quickLookHelper.onMoveDown = { [weak self] in
            guard let self else { return nil }
            self.coordinator.moveDown()
            return self.coordinator.quickLookContext()
        }

        coordinator.onQuickLook = { [weak self] context in
            guard let self else { return }
            if self.quickLookActive && self.quickLookHelper.isVisible {
                self.dismissQuickLook()
                return
            }
            self.showQuickLook(context: context)
        }

        cardPanel.onCancel = { [weak self] in
            self?.hidePanel()
        }

        resultsPanel.onCancel = { [weak self] in
            self?.hidePanel()
        }

        cardPanel.setContent(CardContainerView(coordinator: coordinator), withBackground: false)
        resultsPanel.setContent(ResultsListView(coordinator: coordinator))

        resultsPanel.level = .floating

        observeResults()
    }

    private func widthForCardCount(_ count: Int) -> CGFloat {
        CGFloat(count) * cardWidth + 20
    }

    private func observeResults() {
        resultsObservation = withObservationTracking {
            _ = coordinator.currentResults
            _ = coordinator.currentQuery
            _ = coordinator.currentSelectedIndex
            _ = coordinator.targetVM.isSearching
            return ()
        } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.updateResultsVisibility()
                self?.updateQuickLookSelection()
                self?.observeResults()
            }
        }
    }

    private func updateResultsVisibility() {
        let results = coordinator.currentResults
        let hasQuery = !coordinator.currentQuery.isEmpty
        let isSearching = coordinator.targetVM.isSearching
        let hasContent = !results.isEmpty || hasQuery || isSearching

        guard hasContent, cardPanel.isVisible else {
            showResultsWork?.cancel()
            showResultsWork = nil
            resultsPanel.orderOut(nil)
            return
        }

        if resultsPanel.isVisible {
            positionResultsPanel()
        } else {
            showResultsWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.cardPanel.isVisible else { return }
                self.positionResultsPanel()
                self.resultsPanel.orderFront(nil)
            }
            showResultsWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func updateQuickLookSelection() {
        guard quickLookActive else { return }

        guard quickLookHelper.isVisible else {
            if !quickLookHelper.isTransitioning {
                quickLookDidClose()
            }
            return
        }

        guard let context = coordinator.quickLookContext() else { return }
        quickLookHelper.update(context: context)
    }

    private func animateCardCount() {
        let newWidth = widthForCardCount(coordinator.cardCount)
        let currentFrame = cardPanel.frame
        let deltaW = newWidth - currentFrame.width
        let newX = currentFrame.origin.x - deltaW / 2

        animatingTargetWidth = newWidth
        animatingTargetOriginX = newX

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.cardPanel.animator().setFrame(
                NSRect(x: newX, y: currentFrame.origin.y, width: newWidth, height: self.cardHeight),
                display: false
            )
        } completionHandler: { [weak self] in
            self?.animatingTargetWidth = nil
            self?.animatingTargetOriginX = nil
        }

        positionResultsPanel(overrideWidth: newWidth, originX: newX)
    }

    func toggle() {
        if cardPanel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        coordinator.reset()
        centerOnScreen()
        cardPanel.orderFront(nil)
        cardPanel.makeKey()

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if self.quickLookActive {
                self.dismissQuickLook()
            } else {
                self.hidePanel()
            }
        }

        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: cardPanel,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.quickLookActive else { return }
            self.hidePanel()
        }
    }

    func configurePreviewPanel(_ panel: QLPreviewPanel) {
        panel.dataSource = quickLookHelper
        panel.delegate = quickLookHelper
    }

    func unconfigurePreviewPanel(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    private func showQuickLook(context: QuickLookContext) {
        quickLookActive = true
        if !quickLookHelper.show(context: context) {
            quickLookActive = false
        }
    }

    private func dismissQuickLook() {
        let wasActive = quickLookActive
        quickLookActive = false
        quickLookHelper.dismiss()
        if wasActive {
            restoreFocusAfterQuickLook()
        }
    }

    private func quickLookDidClose() {
        guard quickLookActive else { return }
        quickLookActive = false
        restoreFocusAfterQuickLook()
    }

    private func restoreFocusAfterQuickLook() {
        cardPanel.makeKey()
        coordinator.returningFromQuickLook = true
        coordinator.focusTrigger.toggle()
    }

    func hidePanel() {
        showResultsWork?.cancel()
        showResultsWork = nil
        dismissQuickLook()
        resultsPanel.orderOut(nil)
        cardPanel.orderOut(nil)

        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }

        if let observer = deactivationObserver {
            NotificationCenter.default.removeObserver(observer)
            deactivationObserver = nil
        }
    }

    private func centerOnScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        let screenFrame = screen.visibleFrame
        let w = widthForCardCount(1)
        let h = cardHeight
        let x = screenFrame.midX - w / 2
        let y = screenFrame.midY

        cardPanel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
    }

    func showSettings() {
        hidePanel()

        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Codiclens Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let rowHeight: CGFloat = 46
    private let headerHeight: CGFloat = 34
    private let statusHeight: CGFloat = 40
    private let maxResultsHeight: CGFloat = 300

    private func resultsHeight() -> CGFloat {
        let results = coordinator.currentResults
        let hasQuery = !coordinator.currentQuery.isEmpty
        let isSearching = coordinator.targetVM.isSearching

        if !results.isEmpty {
            let listHeight = CGFloat(results.count) * rowHeight + 6
            let total = headerHeight + min(listHeight, 260) + 1
            return min(total, maxResultsHeight)
        }
        if isSearching || hasQuery {
            return statusHeight
        }
        return 0
    }

    private func positionResultsPanel(overrideWidth: CGFloat? = nil, originX: CGFloat? = nil) {
        let cardFrame = cardPanel.frame
        let w = overrideWidth ?? animatingTargetWidth ?? cardFrame.width
        let h = resultsHeight()
        let x = originX ?? animatingTargetOriginX ?? cardFrame.origin.x
        let y = cardFrame.origin.y - h - 8

        resultsPanel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
    }
}
