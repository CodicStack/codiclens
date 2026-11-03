import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// Owns the one Panel and everything visible in it.
///
/// One window, fixed size, never resized — see
/// `docs/adr/0001-single-panel-two-slabs.md`. The Card row and the Results Slab
/// are SwiftUI views inside it, so there is one animation clock instead of two
/// windows disagreeing about where they are.
///
/// What is left here is the AppKit half: where the window sits, when it appears
/// and disappears, who has activation, and which clicks count as "outside".
class PanelController {
    private let panel: FloatingPanel
    private let presentation = PanelPresentation()
    private var settingsWindow: NSWindow?
    let coordinator: CommandCoordinator
    private let effectRunner: SystemEffectRunner
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var deactivationObserver: Any?
    private var appSwitchObserver: Any?
    private let quickLookHelper = QuickLookHelper()
    private(set) var quickLookActive = false
    private var savePanelActive = false
    private let focus = FocusHandoff()
    /// Where an Incoming Subject came from, when Codiclens has already been
    /// activated by the time it arrives.
    private let lastActiveApp: LastActiveApp
    /// Setup, for the Shortcuts, Open at login and Show Setup… rows in
    /// Settings → General.
    private let setupController: SetupController
    /// For the Check for Updates Built-in and Settings → General → Updates.
    private let updater: any Updater
    /// Search by meaning's query encoder, held while the Panel is up.
    private let queryEncoder = QueryEncoderHold.fileIndex
    private var isTornDown = false

    /// Whether the Panel is up as far as this controller is concerned.
    ///
    /// Deliberately not `panel.isVisible`: the exit animation runs while the
    /// window is still on screen, and during it the Panel is already gone as far
    /// as the user and the hotkey are concerned.
    private var isShowing = false

    /// Bumped on every show, so a pending exit-animation completion can tell
    /// whether it is still the current one before it orders the window out.
    private var showGeneration = 0

    init(lastActiveApp: LastActiveApp, setupController: SetupController, updater: any Updater) {
        self.lastActiveApp = lastActiveApp
        self.setupController = setupController
        self.updater = updater
        let runner = SystemEffectRunner(pasteboard: .general)
        effectRunner = runner
        coordinator = CommandCoordinator(
            runner: runner,
            updater: updater,
            history: .shared,
            emojiVM: EmojiSearchVM(recents: .shared, preferences: .shared),
            index: .shared,
            sources: .shared,
            searchFiles: FileIndex.shared.searcher,
            searchSettled: FileIndex.shared.settledSearcher
        )
        panel = FloatingPanel(
            contentRect: NSRect(
                x: 0, y: 0,
                width: PanelLayout.panelWidth,
                height: PanelLayout.panelHeight
            )
        )

        // The runner performs the OS side of every effect; these closures give
        // it the panel-owned steps it deliberately doesn't own.
        runner.onHide = { [weak self] in
            self?.hidePanel()
        }

        runner.onPasteAndHide = { [weak self] simulateAction in
            self?.pasteAndHide(simulateAction: simulateAction)
        }

        runner.onShowSettings = { [weak self] in
            self?.showSettings()
        }

        // After `.hide`: the Panel is already on its way out when Sparkle's
        // dialog comes up.
        runner.onUpdateRequest = { [weak updater] request in
            updater?.request(request)
        }

        runner.onSavePanel = { [weak self] (data: Data, name: String, type: UTType) in
            self?.showSavePanel(data: data, fileName: name, contentType: type)
        }

        // The OCR Text coming back the other way across the seam. Nothing here
        // is panel-owned — no dismissal, no activation handoff — because the
        // result lands *in* the Panel; this closure exists only because the
        // coordinator must not import Vision.
        runner.onOCRText = { [weak self] text in
            self?.coordinator.receiveOCRText(text)
        }

        runner.onQRCode = { [weak self] generation, data in
            self?.coordinator.receiveQRCode(data, generation: generation)
        }

        runner.onImageRotation = { [weak self] generation, succeeded in
            self?.coordinator.receiveImageRotation(succeeded: succeeded, generation: generation)
        }

        runner.onFileOperation = { [weak self] generation, result in
            self?.coordinator.receiveFileOperation(result, generation: generation)
        }

        runner.onTranscription = { [weak self] generation, result in
            self?.coordinator.receiveTranscription(result, generation: generation)
        }
        runner.onTranscriptionProgress = { [weak self] generation, progress in
            self?.coordinator.receiveTranscriptionProgress(progress, generation: generation)
        }

        runner.onMomentOpen = { [weak self] generation, opened in
            self?.coordinator.receiveMomentOpen(succeeded: opened, generation: generation)
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

        runner.onQuickLook = { [weak self] context in
            guard let self else { return }
            if self.quickLookActive && (self.quickLookHelper.isVisible || self.quickLookHelper.isTransitioning) {
                self.dismissQuickLook()
                return
            }
            self.showQuickLook(context: context)
        }

        panel.onCancel = { [weak self] in
            self?.hidePanel()
        }

        // The Panel's empty space is not part of the UI. The layout reports
        // where the surfaces are; everything else is desktop.
        //
        // `isShowing` is in the guard so that a Panel which is logically gone
        // hit-tests as nothing at all. The exit animation orders the window out
        // from a completion handler, and if that handler ever failed to arrive
        // the window would sit there invisible; this makes such a window
        // harmless — transparent to clicks — rather than a trap that eats them.
        panel.acceptsClick = { [weak self] point in
            guard let self, self.isShowing else { return false }
            return self.presentation.hitRegions.accepts(
                windowPoint: point,
                panelHeight: PanelLayout.panelHeight
            )
        }

        panel.setContent(
            PanelView(coordinator: coordinator, presentation: presentation)
        )

        updatePanelAppearance()
        observeResults()
    }

    private func updatePanelAppearance() {
        let theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "system") ?? .system
        let appearance: NSAppearance?
        switch theme {
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        case .system: appearance = nil
        }
        panel.appearance = appearance
        settingsWindow?.appearance = appearance
    }

    /// Re-arms itself on every change, because `withObservationTracking` fires
    /// its `onChange` exactly once.
    ///
    /// There is nothing to hold on to: `withObservationTracking(_:onChange:)`
    /// returns the *tracked* closure's value, which here is `Void`. Storing that
    /// and nilling it in `tearDown()` cancelled nothing and read as if it did.
    /// `isTornDown` is what actually stops the loop.
    ///
    /// Only Quick Look needs this now. Whether the Results Slab is showing, and
    /// how big it is, is the SwiftUI layout's business.
    private func observeResults() {
        withObservationTracking {
            _ = coordinator.currentResults
            _ = coordinator.currentSelectedIndex
            return ()
        } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                self.updateQuickLookSelection()
                self.observeResults()
            }
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

    func toggle() {
        if isShowing {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        show(handingBackTo: NSWorkspace.shared.frontmostApplication)
    }

    /// Opens the Panel on files or folders sent from Finder, or stands them in
    /// the Panel already up. The coordinator drops whatever command was under
    /// way; the first URL is the Subject and the rest are counted.
    func showIncoming(urls: [URL]) {
        guard !urls.isEmpty else { return }
        receiveIncoming { $0.receiveIncoming(urls: urls) }
    }

    /// Opens the Panel on text selected in another app, or stands it in the
    /// Panel already up.
    func showIncoming(text: String) {
        receiveIncoming { $0.receiveIncoming(text: text) }
    }

    /// An Incoming Subject is stood after `reset()` and before the Panel's
    /// first render, so the entrance animates the Subject that was sent rather
    /// than the Last Subject it replaces.
    ///
    /// The app activation goes back to is `LastActiveApp.source`, not the
    /// frontmost app: Open With and the Service both activate Codiclens, and by
    /// now Codiclens may be frontmost. With the Panel already up, its
    /// `FocusHandoff` already holds the app from when it opened.
    private func receiveIncoming(_ receive: (CommandCoordinator) -> Void) {
        guard isShowing else {
            return show(handingBackTo: lastActiveApp.source, standing: receive)
        }
        receive(coordinator)
    }

    private func show(
        handingBackTo previousApp: NSRunningApplication?,
        standing stand: (CommandCoordinator) -> Void = { _ in }
    ) {
        guard !isTornDown else { return }
        showGeneration += 1
        isShowing = true

        coordinator.reset()
        stand(coordinator)
        queryEncoder.panelShown()
        updatePanelAppearance()
        focus.capture(frontmost: previousApp)
        centerOnScreen()

        // The Panel arrives out of `Motion.entrance`, so it has to be rendered
        // once in its pre-arrival state for the animation to have anything to
        // animate from. `layoutSubtreeIfNeeded` does that synchronously — no
        // delay, nothing waited on.
        presentation.visible = false
        panel.orderFront(nil)
        panel.makeKey()
        panel.contentView?.layoutSubtreeIfNeeded()

        withAnimation(Motion.entrance) { presentation.visible = true }
        setupObservers()
    }

    /// Releases everything the controller holds outside its own memory:
    /// observers, the observation tracking loop, and the window itself.
    /// Called from `applicationWillTerminate`.
    func tearDown() {
        isTornDown = true
        removeObservers()
        quickLookHelper.dismiss()
        hideImmediately()
        settingsWindow?.close()
        settingsWindow = nil
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
        NSApp.activate(ignoringOtherApps: true)
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
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        coordinator.focusTrigger.toggle()
    }

    /// Dismisses with the exit animation.
    ///
    /// Everything the next action depends on happens now — activation goes back,
    /// the observers come off, Quick Look closes. Only `orderOut` waits for the
    /// animation, and only on this path: see `pasteAndHide`.
    func hidePanel() {
        guard isShowing else { return }
        isShowing = false
        let generation = showGeneration
        coordinator.cancelTranscription()
        coordinator.closePassagePreview()
        queryEncoder.panelHidden()

        dismissQuickLook()
        removeObservers()
        focus.restore()

        withAnimation(Motion.entrance, completionCriteria: .logicallyComplete) {
            presentation.visible = false
        } completion: { [weak self] in
            guard let self, !self.isShowing, self.showGeneration == generation else { return }
            self.panel.orderOut(nil)
        }
    }

    /// Dismisses this instant, with no animation at all.
    ///
    /// The paste path needs this: it hands activation back and then synthesises
    /// Cmd+V, and a Panel still on screen — even mid-fade — is a Panel that can
    /// take the keystroke. Correctness beats the exit curve every time.
    private func hideImmediately() {
        isShowing = false
        showGeneration += 1
        coordinator.cancelTranscription()
        coordinator.closePassagePreview()
        queryEncoder.panelHidden()
        presentation.visible = false
        panel.orderOut(nil)
    }

    /// Dismisses, hands activation back to whatever was frontmost, and only
    /// then fires the paste — otherwise the keystroke lands on codiclens.
    private func pasteAndHide(simulateAction: @escaping () -> Void) {
        dismissQuickLook()
        removeObservers()
        hideImmediately()

        focus.yield(then: simulateAction)
    }

    private func setupObservers() {
        // Clicks that go to another app. The Panel is non-activating, so this is
        // the ordinary case: the click never reaches us at all.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if self.quickLookActive {
                self.dismissQuickLook()
            } else {
                self.hidePanel()
            }
        }

        // Clicks that land on the Panel's own empty space — the margin, or the
        // gap between the Slabs. The window covers them, so the global monitor
        // above never sees them, but they are still clicks *outside* the UI and
        // have to dismiss. `PanelHitRegions` is what says where the UI is.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            guard !self.presentation.hitRegions.accepts(
                windowPoint: event.locationInWindow,
                panelHeight: PanelLayout.panelHeight
            ) else { return event }

            if self.quickLookActive {
                self.dismissQuickLook()
            } else {
                self.hidePanel()
            }
            return nil
        }

        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.quickLookActive, !self.savePanelActive else { return }
            self.hidePanel()
        }

        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, !self.savePanelActive,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self.hidePanel()
        }
    }

    private func removeObservers() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }

        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }

        if let observer = deactivationObserver {
            NotificationCenter.default.removeObserver(observer)
            deactivationObserver = nil
        }

        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appSwitchObserver = nil
        }
    }

    /// Puts the Panel on the screen the mouse is on.
    ///
    /// The window is one fixed size, so centring is about the *Card row* rather
    /// than the window: it lands horizontally centred with its bottom edge on
    /// the screen's vertical midpoint, exactly where it sat when the Cards had a
    /// window of their own.
    private func centerOnScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - PanelLayout.panelWidth / 2
        let y = screenFrame.midY - PanelLayout.cardRowBottomInset

        panel.setFrame(
            NSRect(x: x, y: y, width: PanelLayout.panelWidth, height: PanelLayout.panelHeight),
            display: false
        )
    }

    func showSettings() {
        // Instant, not animated: the settings window is about to take
        // activation, and a Panel fading out on top of it looks like a glitch.
        removeObservers()
        quickLookHelper.dismiss()
        quickLookActive = false
        hideImmediately()
        focus.restore()

        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "Codiclens Settings"
            let setupController = setupController
            let updater = updater
            window.contentView = NSHostingView(rootView: ThemeWrapper {
                SettingsView(setupController: setupController, updater: updater)
            })
            window.center()
            settingsWindow = window
        }

        updatePanelAppearance()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSavePanel(data: Data, fileName: String, contentType: UTType) {
        savePanelActive = true
        hideImmediately()
        removeObservers()
        NSApp.activate(ignoringOtherApps: true)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [contentType]
        savePanel.nameFieldStringValue = fileName
        savePanel.canCreateDirectories = true

        let response = savePanel.runModal()
        savePanelActive = false

        if response == .OK, let url = savePanel.url {
            try? data.write(to: url, options: .atomic)
            dismissQuickLook()
            focus.restore()
        } else {
            // Cancelled: put the Panel back exactly as it was, and re-arm the
            // dismissal observers only once it is key again — arming them any
            // earlier dismisses it on the way in.
            NSApp.activate(ignoringOtherApps: true)
            isShowing = true
            showGeneration += 1
            queryEncoder.panelShown()
            presentation.visible = true
            panel.makeKeyAndOrderFront(nil)
            coordinator.focusTrigger.toggle()

            var keyObserver: Any?
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                if let obs = keyObserver {
                    NotificationCenter.default.removeObserver(obs)
                }
                self?.setupObservers()
            }
        }
    }
}
