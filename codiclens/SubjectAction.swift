import AppKit
import UniformTypeIdentifiers

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

/// What an action does. One set of handlers covers every subject kind —
/// clipboard entries included — so a change to Copy or Share lands once.
enum ActionHandler {
    // Applications and files
    case openApp, quitApp, hideApp, showInFinder
    case openFile, openWith, revealInFinder, moveToTrash
    case copyPath, quickLook

    /// Reading the text out of an image Subject.
    ///
    /// Final in the sense that it takes no Target, and the one Final Action
    /// that does not dismiss the Panel: the OCR Text lands in it. See
    /// `docs/adr/0007-async-action-behind-the-effect-seam.md`.
    case ocr
    case qrCode
    case rotate(ImageActions.RotationDirection)
    case openInPreview

    /// Promoting a Target into the Subject, so a thing found while looking for
    /// something else can be acted on in its own right. Never executes
    /// anything; always lands on the Action Phase. See
    /// `docs/adr/0008-a-file-can-be-a-subject.md`.
    case useAsSubject

    // Payloads: text subjects and clipboard entries alike
    case copy, paste, pastePlain, typeText
    case transform(TextTransform)
    case count(CountType)
    case searchWeb, openURL, openEmail, runScript, saveAs, share

    // Clipboard history
    case deleteFromHistory

    case service(String)
    case openSettings
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

    /// Reading the text out of an image.
    ///
    /// Named for the acronym deliberately, against Apple's "Recognize Text" —
    /// it is the word the user reaches for. See `CONTEXT.md`.
    private static let ocr = SubjectAction(
        name: "OCR",
        icon: .sfSymbol("text.viewfinder"),
        isFinal: true,
        handler: .ocr
    )

    private static let rotateLeft = SubjectAction(
        name: "Rotate Left",
        icon: .sfSymbol("rotate.left"),
        isFinal: true,
        handler: .rotate(.left)
    )

    private static let rotateRight = SubjectAction(
        name: "Rotate Right",
        icon: .sfSymbol("rotate.right"),
        isFinal: true,
        handler: .rotate(.right)
    )

    private static let openInPreview = SubjectAction(
        name: "Open in Preview",
        icon: .sfSymbol("eye"),
        isFinal: true,
        handler: .openInPreview
    )

    /// Handing a Subject's content to a macOS sharing service.
    ///
    /// Not Final: the service is the Target. Every Subject that *has* content
    /// carries it — text, Emoji, a Clipboard Item, a file, a folder
    /// (`CONTEXT.md`, **Share**). The Finder Subject deliberately does not: the
    /// grammar gives an Action one Target, and Finder's is the file, so a file
    /// found there is shared by making it the Subject first ("Use as Subject").
    private static let share = SubjectAction(
        name: "Share…",
        icon: .sfSymbol("square.and.arrow.up"),
        isFinal: false,
        handler: .share
    )

    /// Promoting a Target into the Subject.
    ///
    /// Not Final: it needs a Target, and the Target is the whole point. Offered
    /// wherever the Targets are files or apps — the Finder Subject, whose
    /// Targets come out of `mdfind`, and a file or folder Subject. Not a Finder
    /// special case; see `docs/adr/0008-a-file-can-be-a-subject.md`.
    private static let useAsSubject = SubjectAction(
        name: "Use as Subject",
        icon: .sfSymbol("arrow.turn.up.left"),
        isFinal: false,
        handler: .useAsSubject
    )

    private static func builtIn(for subject: Subject) -> [SubjectAction] {
        if case .app(let bundleId, _) = subject.kind, bundleId == "com.apple.finder" {
            return [
                .init(name: "Open File", icon: .sfSymbol("doc"), isFinal: false, handler: .openFile),
                .init(name: "Reveal in Finder", icon: .sfSymbol("folder"), isFinal: false, handler: .revealInFinder),
                .init(name: "Copy Path", icon: .sfSymbol("doc.on.clipboard"), isFinal: false, handler: .copyPath),
                .init(name: "Quick Look", icon: .sfSymbol("eye"), isFinal: false, handler: .quickLook),
                .init(name: "Move to Trash", icon: .sfSymbol("trash"), isFinal: false, handler: .moveToTrash),
                useAsSubject,
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

        // A file's content type decides whether it can be read, not its kind:
        // an image file has OCR, a `.txt` and a folder do not. PDF
        // deliberately does not conform to `.image` and is out of scope —
        // that `Thumbnails` draws a PDF's first page is a different question
        // and is not copied here.
        case .file(let contentType):
            return fileActions(includingOCR: contentType.conforms(to: .image))

        case .folder:
            return fileActions(includingOCR: false)

        case .builtIn(.settings):
            return [
                .init(name: "Open", icon: .sfSymbol("gear"), isFinal: true, handler: .openSettings),
            ]

        case .builtIn(.clipboard), .builtIn(.emoji):
            return []

        case .emoji:
            // An Emoji shares as its text, through the same rule as any other
            // text Subject.
            return [
                .init(name: "Paste", icon: .sfSymbol("doc.on.clipboard"), isFinal: true, handler: .paste),
                .init(name: "Copy", icon: .sfSymbol("doc.on.doc"), isFinal: true, handler: .copy),
                share,
            ]

        case .text(let rawText):
            var actions: [SubjectAction] = [
                .init(name: "Paste", icon: .sfSymbol("doc.on.clipboard"), isFinal: true, handler: .paste),
                .init(name: "Copy", icon: .sfSymbol("doc.on.doc"), isFinal: true, handler: .copy),
            ]
            actions.append(contentsOf: transforms())
            actions.append(.init(name: "Search Web", icon: .sfSymbol("magnifyingglass"), isFinal: true, handler: .searchWeb))
            if ImageActions.canGenerateQRCode(for: rawText) {
                actions.append(.init(
                    name: "QR Code",
                    icon: .sfSymbol("qrcode"),
                    isFinal: true,
                    handler: .qrCode
                ))
            }
            if URL(string: rawText) != nil && rawText.hasPrefix("http") {
                actions.append(.init(name: "Open URL", icon: .sfSymbol("link"), isFinal: true, handler: .openURL))
            }
            actions.append(share)
            return actions

        case .clipboard(let item):
            return clipboardActions(for: item)
        }
    }

    /// What a file or a folder can have done to it.
    ///
    /// Reachable for the first time: `.file` and `.folder` were dead branches
    /// until a Path Subject and "Use as Subject" started constructing them —
    /// see `docs/adr/0008-a-file-can-be-a-subject.md`.
    private static func fileActions(includingOCR: Bool) -> [SubjectAction] {
        var actions: [SubjectAction] = [
            .init(name: "Open", icon: .sfSymbol("doc"), isFinal: true, handler: .openFile),
        ]
        if includingOCR {
            actions.append(ocr)
            actions.append(rotateLeft)
            actions.append(rotateRight)
        }
        actions.append(.init(
            name: "Open With…",
            icon: .sfSymbol("arrow.up.forward.app.fill"),
            isFinal: false,
            handler: .openWith
        ))
        if includingOCR { actions.append(openInPreview) }
        actions.append(contentsOf: [
            .init(name: "Reveal in Finder", icon: .sfSymbol("folder"), isFinal: true, handler: .revealInFinder),
            .init(name: "Copy Path", icon: .sfSymbol("doc.on.clipboard"), isFinal: true, handler: .copyPath),
            share,
            .init(name: "Move to Trash", icon: .sfSymbol("trash"), isFinal: true, handler: .moveToTrash),
            .init(name: "Quick Look", icon: .sfSymbol("eye"), isFinal: true, handler: .quickLook),
            useAsSubject,
        ])
        return actions
    }

    private static func clipboardActions(for item: ClipboardItem) -> [SubjectAction] {
        var actions: [SubjectAction] = [
            .init(name: "Paste", icon: .sfSymbol("doc.on.clipboard"), isFinal: true, handler: .paste),
            .init(name: "Copy", icon: .sfSymbol("doc.on.doc"), isFinal: true, handler: .copy),
            .init(name: "Paste as Plain Text", icon: .sfSymbol("text.alignleft"), isFinal: true, handler: .pastePlain),
        ]

        if item.isImage {
            actions.append(ocr)
            actions.append(.init(name: "Save Image…", icon: .sfSymbol("square.and.arrow.down"), isFinal: true, handler: .saveAs))
            actions.append(openInPreview)
            actions.append(rotateLeft)
            actions.append(rotateRight)
            actions.append(.init(name: "Copy Path", icon: .sfSymbol("doc.on.clipboard"), isFinal: true, handler: .copyPath))
            actions.append(share)
        } else {
            actions.append(.init(name: "Type Text", icon: .sfSymbol("keyboard"), isFinal: true, handler: .typeText))
            actions.append(.init(name: "Run as AppleScript", icon: .sfSymbol("applescript"), isFinal: true, handler: .runScript))
            actions.append(.init(name: "Open Email", icon: .sfSymbol("envelope"), isFinal: true, handler: .openEmail))
            actions.append(.init(name: "Save as File…", icon: .sfSymbol("square.and.arrow.down"), isFinal: true, handler: .saveAs))
            actions.append(.init(name: "Search Web", icon: .sfSymbol("magnifyingglass"), isFinal: true, handler: .searchWeb))
            if ImageActions.canGenerateQRCode(for: item.content) {
                actions.append(.init(
                    name: "QR Code",
                    icon: .sfSymbol("qrcode"),
                    isFinal: true,
                    handler: .qrCode
                ))
            }
            actions.append(share)
            actions.append(contentsOf: transforms())
            for c in CountType.allCases {
                actions.append(.init(name: c.name, icon: .sfSymbol("number"), isFinal: true, handler: .count(c)))
            }
        }

        actions.append(.init(name: "Quick Look", icon: .sfSymbol("eye"), isFinal: true, handler: .quickLook))
        actions.append(.init(name: "Delete from History", icon: .sfSymbol("trash"), isFinal: true, handler: .deleteFromHistory))

        return actions
    }

    private static func transforms() -> [SubjectAction] {
        TextTransform.allCases.map {
            .init(name: $0.name, icon: .sfSymbol($0.iconName), isFinal: true, handler: .transform($0))
        }
    }

    private static func services(for subject: Subject) -> [SubjectAction] {
        []
    }
}
