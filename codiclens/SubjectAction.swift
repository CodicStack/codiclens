import AppKit

enum ActionIcon {
    case sfSymbol(String)
    case appIcon(NSImage)
}

enum TextTransform: CaseIterable {
    case uppercase, lowercase, camelCase, pascalCase, snakeCase
    case constantCase, dotCase, headerCase, kebabCase, kebabUpperCase, titleCase
    case trimWhitespace, collapseWhitespace, removeBlankLines
    case urlEncode, urlDecode, base64Encode, base64Decode
    case escapeHTML, unescapeHTML
    case reverseText, reverseLines

    var name: String {
        switch self {
        case .uppercase: "UPPERCASE"
        case .lowercase: "lowercase"
        case .camelCase: "camelCase"
        case .pascalCase: "PascalCase"
        case .snakeCase: "snake_case"
        case .constantCase: "CONSTANT_CASE"
        case .dotCase: "dot.case"
        case .headerCase: "Header Case"
        case .kebabCase: "kebab-case"
        case .kebabUpperCase: "KEBAB-UPPER"
        case .titleCase: "Title Case"
        case .trimWhitespace: "Trim Whitespace"
        case .collapseWhitespace: "Collapse Whitespace"
        case .removeBlankLines: "Remove Blank Lines"
        case .urlEncode: "URL Encode"
        case .urlDecode: "URL Decode"
        case .base64Encode: "Base64 Encode"
        case .base64Decode: "Base64 Decode"
        case .escapeHTML: "Escape HTML"
        case .unescapeHTML: "Unescape HTML"
        case .reverseText: "Reverse Text"
        case .reverseLines: "Reverse Lines"
        }
    }

    var iconName: String {
        switch self {
        case .uppercase, .lowercase, .camelCase, .pascalCase, .snakeCase,
             .constantCase, .dotCase, .headerCase, .kebabCase, .kebabUpperCase, .titleCase:
            "textformat.abc"
        case .trimWhitespace, .collapseWhitespace, .removeBlankLines:
            "text.badge.minus"
        case .urlEncode, .urlDecode, .base64Encode, .base64Decode:
            "curlybraces"
        case .escapeHTML, .unescapeHTML:
            "chevron.left.forwardslash.chevron.right"
        case .reverseText, .reverseLines:
            "arrow.left.arrow.right"
        }
    }

    func apply(_ text: String) -> String {
        switch self {
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .camelCase:
            let words = Self.splitWords(text)
            guard let first = words.first else { return text }
            return first.lowercased() + words.dropFirst().map { $0.capitalized }.joined()
        case .pascalCase:
            return Self.splitWords(text).map { $0.capitalized }.joined()
        case .snakeCase:
            return Self.splitWords(text).map { $0.lowercased() }.joined(separator: "_")
        case .constantCase:
            return Self.splitWords(text).map { $0.uppercased() }.joined(separator: "_")
        case .dotCase:
            return Self.splitWords(text).map { $0.lowercased() }.joined(separator: ".")
        case .headerCase:
            return Self.splitWords(text).map { $0.capitalized }.joined(separator: " ")
        case .kebabCase:
            return Self.splitWords(text).map { $0.lowercased() }.joined(separator: "-")
        case .kebabUpperCase:
            return Self.splitWords(text).map { $0.uppercased() }.joined(separator: "-")
        case .titleCase:
            return Self.splitWords(text).map { $0.capitalized }.joined(separator: " ")
        case .trimWhitespace:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .collapseWhitespace:
            return text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        case .removeBlankLines:
            return text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
        case .urlEncode:
            return text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        case .urlDecode:
            return text.removingPercentEncoding ?? text
        case .base64Encode:
            return Data(text.utf8).base64EncodedString()
        case .base64Decode:
            if let data = Data(base64Encoded: text), let decoded = String(data: data, encoding: .utf8) {
                return decoded
            }
            return text
        case .escapeHTML:
            return text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        case .unescapeHTML:
            return text
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
        case .reverseText:
            return String(text.reversed())
        case .reverseLines:
            return text.components(separatedBy: .newlines).reversed().joined(separator: "\n")
        }
    }

    private static func splitWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        let chars = Array(text)
        for i in 0..<chars.count {
            let c = chars[i]
            if c == " " || c == "_" || c == "-" || c == "." {
                if !current.isEmpty { words.append(current); current = "" }
            } else if i > 0 && c.isUppercase && chars[i - 1].isLowercase {
                if !current.isEmpty { words.append(current); current = "" }
                current.append(c)
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

enum CountType: CaseIterable {
    case characters, words, lines

    var name: String {
        switch self {
        case .characters: "Count Characters"
        case .words: "Count Words"
        case .lines: "Count Lines"
        }
    }

    func count(_ text: String) -> String {
        switch self {
        case .characters: "\(text.count) characters"
        case .words: "\(text.split(separator: " ").count) words"
        case .lines: "\(text.components(separatedBy: .newlines).count) lines"
        }
    }
}

enum ActionHandler {
    case openApp, quitApp, hideApp, showInFinder, copyPath
    case openFile, openWith, revealInFinder, moveToTrash, quickLook
    case copyText, transform(TextTransform), searchWeb, openURL
    case share
    case service(String)
    case openSettings
    // Clipboard actions
    case clipboardPaste
    case clipboardCopy
    case clipboardPastePlain
    case clipboardTypeText
    case clipboardRunScript
    case clipboardOpenEmail
    case clipboardDelete
    case clipboardOpenPreview
    case clipboardCopyPath
    case clipboardTransform(TextTransform)
    case clipboardCount(CountType)
}

struct SubjectAction: Identifiable {
    let id = UUID()
    let name: String
    let icon: ActionIcon
    let isFinal: Bool
    let handler: ActionHandler

    static func actions(for subject: Subject) -> [SubjectAction] {
        var result = builtIn(for: subject)
        result.append(contentsOf: services(for: subject))
        return result
    }

    static func clipboardActions(for item: ClipboardItem) -> [SubjectAction] {
        var actions: [SubjectAction] = []

        actions.append(.init(name: "Paste", icon: .sfSymbol("doc.on.clipboard"), isFinal: true, handler: .clipboardPaste))
        actions.append(.init(name: "Copy", icon: .sfSymbol("doc.on.doc"), isFinal: true, handler: .clipboardCopy))
        actions.append(.init(name: "Paste as Plain Text", icon: .sfSymbol("text.alignleft"), isFinal: true, handler: .clipboardPastePlain))

        if !item.isImage {
            actions.append(.init(name: "Type Text", icon: .sfSymbol("keyboard"), isFinal: true, handler: .clipboardTypeText))
            actions.append(.init(name: "Run as AppleScript", icon: .sfSymbol("applescript"), isFinal: true, handler: .clipboardRunScript))
            actions.append(.init(name: "Open Email", icon: .sfSymbol("envelope"), isFinal: true, handler: .clipboardOpenEmail))
            actions.append(.init(name: "Search Web", icon: .sfSymbol("magnifyingglass"), isFinal: true, handler: .searchWeb))
            actions.append(.init(name: "Share…", icon: .sfSymbol("square.and.arrow.up"), isFinal: false, handler: .share))

            for t in TextTransform.allCases {
                actions.append(.init(name: t.name, icon: .sfSymbol(t.iconName), isFinal: true, handler: .clipboardTransform(t)))
            }

            for c in CountType.allCases {
                actions.append(.init(name: c.name, icon: .sfSymbol("number"), isFinal: true, handler: .clipboardCount(c)))
            }
        } else {
            actions.append(.init(name: "Open in Preview", icon: .sfSymbol("eye"), isFinal: true, handler: .clipboardOpenPreview))
            actions.append(.init(name: "Copy Path", icon: .sfSymbol("doc.on.clipboard"), isFinal: true, handler: .clipboardCopyPath))
        }

        actions.append(.init(name: "Delete from History", icon: .sfSymbol("trash"), isFinal: true, handler: .clipboardDelete))

        return actions
    }

    private static func builtIn(for subject: Subject) -> [SubjectAction] {
        if case .app(let bundleId, _) = subject.kind, bundleId == "com.apple.finder" {
            return [
                .init(name: "Open File", icon: .sfSymbol("doc"), isFinal: false, handler: .openFile),
                .init(name: "Reveal in Finder", icon: .sfSymbol("folder"), isFinal: false, handler: .revealInFinder),
                .init(name: "Copy Path", icon: .sfSymbol("doc.on.clipboard"), isFinal: false, handler: .copyPath),
                .init(name: "Quick Look", icon: .sfSymbol("eye"), isFinal: false, handler: .quickLook),
                .init(name: "Move to Trash", icon: .sfSymbol("trash"), isFinal: false, handler: .moveToTrash),
            ]
        }

        switch subject.kind {
        case .app:
            return [
                .init(name: "Open", icon: .sfSymbol("arrow.up.forward.app"), isFinal: true, handler: .openApp),
                .init(name: "Quit", icon: .sfSymbol("xmark.circle"), isFinal: true, handler: .quitApp),
                .init(name: "Hide", icon: .sfSymbol("eye.slash"), isFinal: true, handler: .hideApp),
                .init(name: "Show in Finder", icon: .sfSymbol("folder"), isFinal: true, handler: .showInFinder),
                .init(name: "Copy Path", icon: .sfSymbol("doc.on.clipboard"), isFinal: true, handler: .copyPath),
            ]
        case .file, .folder:
            return [
                .init(name: "Open", icon: .sfSymbol("doc"), isFinal: true, handler: .openFile),
                .init(name: "Open With…", icon: .sfSymbol("arrow.up.forward.app.fill"), isFinal: false, handler: .openWith),
                .init(name: "Reveal in Finder", icon: .sfSymbol("folder"), isFinal: true, handler: .revealInFinder),
                .init(name: "Copy Path", icon: .sfSymbol("doc.on.clipboard"), isFinal: true, handler: .copyPath),
                .init(name: "Move to Trash", icon: .sfSymbol("trash"), isFinal: true, handler: .moveToTrash),
                .init(name: "Quick Look", icon: .sfSymbol("eye"), isFinal: true, handler: .quickLook),
            ]
        case .builtIn(.settings):
            return [
                .init(name: "Open", icon: .sfSymbol("gear"), isFinal: true, handler: .openSettings),
            ]
        case .builtIn(.clipboard):
            return []
        case .text(let rawText):
            var actions: [SubjectAction] = [
                .init(name: "Copy", icon: .sfSymbol("doc.on.doc"), isFinal: true, handler: .copyText),
            ]
            for t in TextTransform.allCases {
                actions.append(.init(name: t.name, icon: .sfSymbol(t.iconName), isFinal: true, handler: .transform(t)))
            }
            actions.append(.init(name: "Search Web", icon: .sfSymbol("magnifyingglass"), isFinal: true, handler: .searchWeb))
            if URL(string: rawText) != nil && rawText.hasPrefix("http") {
                actions.append(.init(name: "Open URL", icon: .sfSymbol("link"), isFinal: true, handler: .openURL))
            }
            actions.append(.init(name: "Share…", icon: .sfSymbol("square.and.arrow.up"), isFinal: false, handler: .share))
            return actions
        }
    }

    private static func services(for subject: Subject) -> [SubjectAction] {
        []
    }
}
