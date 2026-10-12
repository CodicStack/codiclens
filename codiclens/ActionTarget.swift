import AppKit

/// `nonisolated` because Finder's Target list builds its Targets off the main
/// thread (`FileTargetSearch`).
nonisolated struct ActionTarget: Identifiable {
    let id = UUID()
    let name: String
    let icon: NSImage
    /// The file whose thumbnail replaces `icon` once Quick Look has drawn it —
    /// a file found through Finder. `nil` for an app or a sharing service.
    let thumbnailURL: URL?
    let subtitle: String
    let url: URL?
    let sharingService: NSSharingService?

    init(
        name: String,
        icon: NSImage,
        thumbnailURL: URL? = nil,
        subtitle: String = "",
        url: URL?,
        sharingService: NSSharingService?
    ) {
        self.name = name
        self.icon = icon
        self.thumbnailURL = thumbnailURL
        self.subtitle = subtitle
        self.url = url
        self.sharingService = sharingService
    }

    @MainActor
    static func openWithTargets(for subject: Subject) -> [ActionTarget] {
        guard let subjectURL = subject.url else { return [] }
        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: subjectURL)
        return appURLs.compactMap { appURL in
            let name = (appURL.lastPathComponent as NSString).deletingPathExtension
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 32, height: 32)
            return ActionTarget(name: name, icon: icon, url: appURL, sharingService: nil)
        }
    }
    
    /// Share targets the system offers for a payload. Clipboard Items and
    /// Subjects both arrive here — `CommandCoordinator` resolves the Payload
    /// for either — so the two paths can't drift apart. The Payload is turned
    /// into an item by `SharePayloadItems`, the same conversion the Share
    /// Effect performs with, so the list can't disagree with the send.
    @MainActor
    static func shareTargets(for payload: Payload) -> [ActionTarget] {
        let items = [SharePayloadItems.item(for: payload)]

        return NSSharingService.sharingServices(forItems: items).map { service in
            let icon = service.image
            icon.size = NSSize(width: 32, height: 32)
            return ActionTarget(name: service.title, icon: icon, url: nil, sharingService: service)
        }
    }
}


