import AppKit

/// An Incoming Subject on its way in: files and folders from Finder, or text
/// selected in another app. See `docs/adr/0014-incoming-subjects-and-the-wider-last-subject.md`.
///
/// Two doors lead here. Finder's Open With ▸ Codiclens arrives as
/// `application(_:open:)`, from the document types in `codiclens-Info.plist`.
/// Everything Open With cannot reach — selected text, a `.app`, a type known
/// only as data — comes through the "Open in Codiclens" Service, whose message
/// is `IncomingService.openInCodiclens`. Why the document types are what they
/// are: AGENTS.md, "Incoming Subjects".
enum Incoming {
    case urls([URL])
    case text(String)

    /// What a Service request carries. Files win over text: Finder writes its
    /// selection as file URLs, and a requester that also wrote a string meant
    /// the files.
    init?(pasteboard: NSPasteboard) {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if !urls.isEmpty {
            self = .urls(urls)
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            self = .text(text)
        } else {
            return nil
        }
    }
}

/// The "Open in Codiclens" Service's provider, registered as
/// `NSApp.servicesProvider`.
///
/// One Service, not one for files and one for text: its entry in
/// `codiclens-Info.plist` sends both file types and plain text, so there is one
/// "Open in Codiclens" wherever either is selected, and never two side by side
/// where a requester offers both.
final class IncomingService: NSObject {
    var onIncoming: ((Incoming) -> Void)?

    /// `NSMessage` in the Service's plist entry. AppKit finds it by the selector
    /// `openInCodiclens:userData:error:`.
    @objc func openInCodiclens(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let incoming = Incoming(pasteboard: pasteboard) else {
            error.pointee = "Nothing to open in Codiclens." as NSString
            return
        }
        onIncoming?(incoming)
    }
}

/// The last app other than Codiclens to have activation: the one an Incoming
/// Subject came from, and the one the Panel hands activation back to.
///
/// Open With and the Service both activate Codiclens. LaunchServices activates
/// the app it sends an open-documents event to, and a Service's provider is
/// activated as its message is delivered, so by then `frontmostApplication`
/// may already be Codiclens and `FocusHandoff` would have nothing to give
/// activation back to. The app the user right-clicked in, Finder or wherever
/// the text was selected, is the one before it, and this remembers it.
///
/// Started in `applicationWillFinishLaunching`, before a cold launch from Open
/// With has activated Codiclens: at that point the frontmost app is still the
/// one the user was in, and by `applicationDidFinishLaunching` it no longer is.
final class LastActiveApp {
    private(set) var app: NSRunningApplication?
    private var observer: Any?

    func start() {
        note(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.note(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    /// The frontmost app, unless that is Codiclens, in which case the last app
    /// before it.
    var source: NSRunningApplication? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier else { return frontmost }
        return app.flatMap { $0.isTerminated ? nil : $0 }
    }

    private func note(_ activated: NSRunningApplication?) {
        guard let activated, activated.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        app = activated
    }
}
