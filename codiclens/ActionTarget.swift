import AppKit

struct ActionTarget: Identifiable {
    let id = UUID()
    let name: String
    let icon: NSImage
    let subtitle: String
    let url: URL?
    let sharingService: NSSharingService?

    init(name: String, icon: NSImage, subtitle: String = "", url: URL?, sharingService: NSSharingService?) {
        self.name = name
        self.icon = icon
        self.subtitle = subtitle
        self.url = url
        self.sharingService = sharingService
    }

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
    
    static func shareTargets(for subject: Subject) -> [ActionTarget] {
        let items: [Any]
        switch subject.kind {
        case .text(let rawText):
            items = [rawText as NSString]
        default:
            guard let url = subject.url else { return [] }
            items = [url]
        }

        return NSSharingService.sharingServices(forItems: items).map { service in
            let icon = service.image ?? NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil) ?? NSImage()
            icon.size = NSSize(width: 32, height: 32)
            return ActionTarget(name: service.title, icon: icon, url: nil, sharingService: service)
        }
    }
}


