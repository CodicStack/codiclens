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
    /// An entry from clipboard history, acted on exactly like any other subject.
    case clipboard(ClipboardItem)
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
        case .clipboard(let item):
            return item.isImage ? "Clipboard Image" : "Clipboard Text"
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

    /// The clipboard entry behind this subject, if it is one.
    var clipboardItem: ClipboardItem? {
        if case .clipboard(let item) = kind { return item }
        return nil
    }

    init(displayName: String, path: String?, url: URL?, icon: NSImage, kind: SubjectKind) {
        self.displayName = displayName
        self.path = path
        self.url = url
        self.icon = icon
        self.kind = kind
    }

    init(clipboardItem item: ClipboardItem) {
        let symbol = item.isImage ? "photo" : "text.alignleft"
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        icon.size = NSSize(width: 32, height: 32)
        self.init(
            displayName: item.displayName,
            path: item.originalFilePath,
            url: item.originalFileURL,
            icon: icon,
            kind: .clipboard(item)
        )
    }

    /// A text subject, the shape transforms produce.
    init(text: String) {
        let icon = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil) ?? NSImage()
        icon.size = NSSize(width: 32, height: 32)
        self.init(displayName: text, path: nil, url: nil, icon: icon, kind: .text(rawText: text))
    }
}
