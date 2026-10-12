import AppKit

/// What a Payload becomes when it is handed to a sharing service.
///
/// One conversion, used both to *list* the Targets a Payload has
/// (`ActionTarget.shareTargets(for:)`) and to perform the Share
/// (`SystemEffectRunner`), so the list the user picks from can never disagree
/// with what the service is actually given.
enum SharePayloadItems {

    /// The single item a sharing service is offered for a Payload.
    static func item(for payload: Payload) -> Any {
        switch payload {
        case .text(let text): textItem(for: text)
        case .image(let data): NSImage(data: data) ?? NSImage()
        case .fileURL(let url): url as NSURL
        }
    }

    /// Text as something every sharing service will take.
    ///
    /// Text that is a URL is shared as a link, not as text (`GLOSSARY.md`,
    /// **Share**). Everything else is written to a `.txt` and the *file* is
    /// shared, because **AirDrop refuses a string**: `canPerform` is false for
    /// an `NSString`, so AirDrop drops out of the list entirely and the one
    /// Target the user wanted for a note is the one Target missing (verified
    /// 2026-09-11, macOS 26). It accepts a file, an image and an `https` URL,
    /// so text becomes a file.
    static func textItem(for text: String) -> Any {
        if let link = linkURL(for: text) { return link as NSURL }
        if let file = writeTemporaryFile(text) { return file as NSURL }
        return text as NSString
    }

    /// The link a text Subject *is*, or nil if it is prose.
    ///
    /// A single `http`/`https` URL and nothing else: whitespace anywhere means
    /// the text is a sentence that happens to contain a link, and sharing a
    /// sentence as a link would drop the rest of it.
    static func linkURL(for text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    /// What the shared `.txt` is called: the text's first non-empty line, so
    /// the file landing on the other machine says what it is instead of
    /// arriving as `Untitled`.
    static func fileName(for text: String) -> String {
        let firstLine = text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let collapsed = firstLine
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // `/` and `:` are the two characters a macOS file name cannot carry —
        // the Finder shows one as the other — and NUL ends the C string the
        // filesystem sees.
        let cleaned = collapsed.filter { $0 != "/" && $0 != ":" && $0 != "\0" }
        let name = String(cleaned.prefix(maximumFileNameLength))
        return (name.isEmpty ? "Text" : name) + ".txt"
    }

    private static let maximumFileNameLength = 40

    /// Writes the text where a sharing service can reach it.
    ///
    /// A directory of its own per Share: the name comes from the text's first
    /// line, so two Shares of two notes that open the same way would otherwise
    /// be the same path and the second would overwrite the first while the
    /// first was still being sent.
    private static func writeTemporaryFile(_ text: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent(fileName(for: text))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
