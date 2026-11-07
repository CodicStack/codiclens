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
    /// Where `subtitle` is a Passage, its matched words
    /// (`ResultDisplayItem.subtitleMarks`).
    let subtitleMarks: [Range<Int>]?
    let url: URL?
    let sharingService: NSSharingService?

    init(
        name: String,
        icon: NSImage,
        thumbnailURL: URL? = nil,
        subtitle: String = "",
        subtitleMarks: [Range<Int>]? = nil,
        url: URL?,
        sharingService: NSSharingService?
    ) {
        self.name = name
        self.icon = icon
        self.thumbnailURL = thumbnailURL
        self.subtitle = subtitle
        self.subtitleMarks = subtitleMarks
        self.url = url
        self.sharingService = sharingService
    }

    /// A folder as a Move To…, Copy To… or Save To… destination: Finder's name for it
    /// ("Desktop", not "Desktop" spelled from the path, in any language) and
    /// where it is. From any thread; the File Index's folders are made off the
    /// main one.
    static func folder(at url: URL) -> ActionTarget {
        let path = url.standardizedFileURL.path
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let isInHome = path == home || path.hasPrefix(home + "/")
        let subtitle = isInHome ? "~" + path.dropFirst(home.count) : path
        return ActionTarget(
            name: FileManager.default.displayName(atPath: path),
            icon: icon,
            subtitle: subtitle,
            url: url.standardizedFileURL,
            sharingService: nil
        )
    }

    /// Every app that opens the Subject's file, except Codiclens: it claims
    /// nearly every type for Finder's Open With (ADR 0014), and picking it here
    /// would only send the file back in as an Incoming Subject.
    @MainActor
    static func openWithTargets(for subject: Subject) -> [ActionTarget] {
        guard let subjectURL = subject.url else { return [] }
        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: subjectURL).filter {
            Bundle(url: $0)?.bundleIdentifier != Bundle.main.bundleIdentifier
        }
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


