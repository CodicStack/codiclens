import AppKit

enum BuiltInType {
    case settings
    case clipboard
}

enum SubjectKind {
    case app(bundleIdentifier: String?, isRunning: Bool)
    case file(contentType: String)
    case folder
    case text(rawText: String)
    case builtIn(BuiltInType)
}

struct Subject: Identifiable {
    let id = UUID()
    let displayName: String
    let path: String?
    let url: URL?
    let icon: NSImage
    let kind: SubjectKind

    var subtitle: String {
        switch kind {
        case .text:
            return "Text"
        case .builtIn(.settings):
            return "Codiclens"
        case .builtIn(.clipboard):
            return "Clipboard History"
        default:
            guard let path else { return "" }
            let home = FileManager.default.homeDirectoryForCurrentUser.path()
            if path.hasPrefix(home) {
                return "~" + path.dropFirst(home.count)
            }
            return path
        }
    }
}
