// HTML stripping, the PDF page threshold and the step sizes adapted from DigUp's Extractors.swift and Model.swift
// (https://github.com/ARahim3/DigUp), MIT licence — see digup-license.txt.
import AppKit
import Compression
import PDFKit

/// Reads a file's Passages: a `FileContentJob` in, a `FileContentResult`
/// out, and nothing else touched — no database, no state. That is what lets
/// the reading move into a helper process later, and what tests call directly.
///
/// A long file is read a step at a time: the first `firstStep` pages or chunks
/// with the first pass, so every file is searchable sooner, and the rest in
/// `laterStep`s once the first pass is through. Nothing past `maxPassages` is
/// read; only machine-made files get that far.
nonisolated enum FileContentReader {
    static let firstStep = 40
    static let laterStep = 400
    /// ~8 million characters of text, or 5,000 pages.
    static let maxPassages = 5000
    /// Where a note or plain text file stops being read. A gigabyte of log is
    /// not read past its first 10 MB.
    static let maxTextBytes = 10 << 20
    /// Where code, and any file that is only text by sniffing, stops being
    /// read. Hand-written source rarely passes 1 MB; past it is a program's
    /// output — a dataset, a lockfile, a dump. On the dev machine this took
    /// the index from 3.0 GB to 2.5 GB (1.2 million Passages to 1.0).
    static let maxCodeBytes = 1 << 20
    /// How much of a file decides whether it is text.
    static let sniffBytes = 8192
    /// A PDF page with less text than this is a scan or a slide. Its words
    /// are not worth a Passage, and the meaning layer will read its picture.
    static let minPageText = 200

    static func read(_ job: FileContentJob) async -> FileContentResult {
        let step = job.readTo == 0 ? firstStep : laterStep
        let window = job.readTo..<min(job.readTo + step, maxPassages)
        let url = URL(fileURLWithPath: job.path)
        switch job.content {
        case .screenshot:
            guard let text = await OCR.text(in: url) else { return FileContentResult(job: job, readTo: 0, detail: "no text") }
            return chunked(text, kind: .ocr, job: job, window: window)
        case .pdf:
            guard let document = PDFDocument(url: url) else { return FileContentResult(job: job, readTo: 0, detail: "unreadable") }
            return pages(of: document, job: job, window: window)
        case .document:
            return document(url, job: job, window: window)
        case .text, .code:
            let isNote = job.content == .text
            guard let text = sniffedText(url, allowsLegacyEncoding: isNote, limit: isNote ? maxTextBytes : maxCodeBytes) else {
                return FileContentResult(job: job, readTo: 0, detail: "not text")
            }
            var result = chunked(text.text, kind: .chunk, job: job, window: window)
            if text.isTruncated, result.isComplete { result.detail = isNote ? "first 10 MB" : "first 1 MB" }
            return result
        case .image, .audio, .video:
            // No words: the writer never hands these out (`hasWords`).
            return FileContentResult(job: job, readTo: 0)
        }
    }

    // MARK: - Text

    /// The file's text, if it is text: a UTF-16 byte-order mark, or a first
    /// `sniffBytes` with no NUL that is valid UTF-8. The extension has no say.
    /// Notes saved in an older encoding — a `.txt` from Windows — are read as
    /// Windows-1252 when `allowsLegacyEncoding`.
    static func sniffedText(
        _ url: URL,
        allowsLegacyEncoding: Bool = false,
        limit: Int = maxTextBytes
    ) -> (text: String, isTruncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: sniffBytes), !head.isEmpty else { return ("", false) }
        let isUTF16 = head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF])
        let isUTF8 = !isUTF16 && !head.contains(0) && isValidUTF8(head, mayBeCut: head.count == sniffBytes)
        guard isUTF16 || isUTF8 || (allowsLegacyEncoding && !head.contains(0)) else { return nil }

        var data = head
        if head.count == sniffBytes, let rest = try? handle.read(upToCount: max(0, limit + 1 - head.count)) {
            data.append(rest)
        }
        let isTruncated = data.count > limit
        if isTruncated { data = data.prefix(limit) }

        if isUTF16 {
            if data.count % 2 == 1 { data = data.dropLast() }
            return String(data: data, encoding: .utf16).map { ($0, isTruncated) }
        }
        if isUTF8 {
            if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
            return (String(decoding: data, as: UTF8.self), isTruncated)
        }
        return String(data: data, encoding: .windowsCP1252).map { ($0, isTruncated) }
    }

    /// Valid UTF-8, allowing a character cut off at the end when `mayBeCut`.
    private static func isValidUTF8(_ bytes: Data, mayBeCut: Bool) -> Bool {
        for cut in 0...(mayBeCut ? 3 : 0) where bytes.count > cut {
            if String(validating: bytes.dropLast(cut), as: UTF8.self) != nil { return true }
        }
        return false
    }

    /// `text` cut into chunks, the ones in `window` read.
    static func chunked(_ text: String, kind: FilePassage.Kind, job: FileContentJob, window: Range<Int>) -> FileContentResult {
        let (chunks, total) = FileChunker.chunks(text, range: window, cap: maxPassages + 1)
        let readTo = min(window.upperBound, total)
        var result = FileContentResult(
            job: job,
            passages: chunks.map { FilePassage(kind: kind, location: kind == .ocr ? nil : Double($0.offset), text: $0.text) },
            readTo: readTo,
            isComplete: readTo >= min(total, maxPassages)
        )
        if total > maxPassages, result.isComplete { result.detail = "first \(maxPassages) chunks" }
        if total == 0 { result.detail = "no text" }
        return result
    }

    // MARK: - PDF

    /// A Passage per page with text, numbered from 1.
    static func pages(of document: PDFDocument, job: FileContentJob, window: Range<Int>) -> FileContentResult {
        if document.isLocked { return FileContentResult(job: job, readTo: 0, detail: "locked") }
        let total = min(document.pageCount, maxPassages)
        let range = window.clamped(to: 0..<total)
        var passages: [FilePassage] = []
        for index in range {
            autoreleasepool {
                guard let text = document.page(at: index)?.string else { return }
                let cleaned = FileChunker.clean(text)
                if cleaned.count >= minPageText {
                    passages.append(FilePassage(kind: .page, location: Double(index + 1), text: cleaned))
                }
            }
        }
        var result = FileContentResult(job: job, passages: passages, readTo: range.upperBound,
                                       isComplete: range.upperBound >= total)
        if document.pageCount > maxPassages, result.isComplete { result.detail = "first \(maxPassages) pages" }
        if job.readTo == 0, result.isComplete, passages.isEmpty { result.detail = "no text" }
        return result
    }

    // MARK: - Documents

    private static func document(_ url: URL, job: FileContentJob, window: Range<Int>) -> FileContentResult {
        let ext = url.pathExtension.lowercased()
        if ["pages", "key", "numbers"].contains(ext) {
            guard let preview = iWorkPreview(url) else { return FileContentResult(job: job, readTo: 0, detail: "no preview") }
            return pages(of: preview, job: job, window: window)
        }
        guard let text = documentText(url) else { return FileContentResult(job: job, readTo: 0, detail: "unreadable") }
        return chunked(text, kind: .chunk, job: job, window: window)
    }

    /// The text of a document that is not a PDF, by its extension.
    static func documentText(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "rtf": return attributedText(url, .rtf)
        case "rtfd": return attributedText(url, .rtfd)
        case "doc": return attributedText(url, .docFormat)
        case "docx": return attributedText(url, .officeOpenXML)
        case "odt": return attributedText(url, .openDocument)
        case "html", "htm", "xhtml":
            return sniffedText(url, allowsLegacyEncoding: true).map { plainText(fromHTML: $0.text) }
        case "webarchive": return webArchiveText(url)
        case "eml", "emlx": return (try? Data(contentsOf: url)).map { MailText.text(of: $0, isEmlx: ext == "emlx") }
        case "xlsx", "pptx", "ods", "odp", "epub": return ZipArchive(url: url).flatMap { zippedText($0, ext: ext) }
        default: return nil
        }
    }

    /// Through the Cocoa text system, which reads these without WebKit and
    /// so off the main thread. HTML is not read this way: its importer is
    /// WebKit, and main-thread only.
    private static func attributedText(_ url: URL, _ type: NSAttributedString.DocumentType) -> String? {
        try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
    }

    /// A Safari web archive's page: a property list holding the HTML.
    private static func webArchiveText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let archive = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let main = archive["WebMainResource"] as? [String: Any],
              let html = main["WebResourceData"] as? Data
        else { return nil }
        let encoding = (main["WebResourceTextEncodingName"] as? String).flatMap(MailText.encoding(named:)) ?? .utf8
        return plainText(fromHTML: String(data: html, encoding: encoding) ?? String(decoding: html, as: UTF8.self))
    }

    /// Office and OpenDocument files and ePubs are zips of XML: the parts
    /// that hold the words, tags stripped.
    private static func zippedText(_ zip: ZipArchive, ext: String) -> String? {
        let names: [String]
        switch ext {
        case "xlsx":
            names = ["xl/sharedStrings.xml"]
        case "pptx":
            // Slides in their order, not the archive's: slide10 after slide9.
            names = zip.names
                .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        case "ods", "odp":
            names = ["content.xml"]
        default:
            names = zip.names.filter { ["xhtml", "html", "htm"].contains(($0 as NSString).pathExtension.lowercased()) }
        }
        let parts = names.compactMap { zip.contents(of: $0) }.map { String(decoding: $0, as: UTF8.self) }
        guard !parts.isEmpty else { return nil }
        return parts.map { ext == "epub" ? plainText(fromHTML: $0) : plainText(fromXML: $0) }.joined(separator: "\n\n")
    }

    /// The PDF Pages, Keynote and Numbers keep of the document when "include
    /// preview" is on, inside the package or the single-file zip. Without
    /// one there is nothing to read without parsing iWork's own format.
    private static func iWorkPreview(_ url: URL) -> PDFDocument? {
        let inPackage = url.appendingPathComponent("QuickLook/Preview.pdf")
        if FileManager.default.fileExists(atPath: inPackage.path) { return PDFDocument(url: inPackage) }
        return ZipArchive(url: url)?.contents(of: "QuickLook/Preview.pdf").flatMap(PDFDocument.init(data:))
    }

    // MARK: - Markup

    /// Good enough for search: scripts, styles, comments and the head go,
    /// block ends become line breaks, the remaining tags go, entities are
    /// decoded.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        for pattern in [#"(?is)<script\b.*?</script\s*>"#, #"(?is)<style\b.*?</style\s*>"#, #"(?s)<!--.*?-->"#,
                        #"(?is)<head\b.*?</head\s*>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)\b[^>]*>"#,
                                         with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return decodingEntities(text)
    }

    /// Word-processor XML: a paragraph's runs are one word apart only where
    /// the text says so, so tags vanish rather than become spaces; paragraph
    /// ends, tabs and cells are breaks.
    static func plainText(fromXML xml: String) -> String {
        var text = xml.replacingOccurrences(of: #"</(w:p|a:p|text:p|text:h|si|table:table-row)>"#,
                                            with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<(w:tab|w:br|a:br|text:tab|text:line-break|text:s)\b[^>]*/>|</table:table-cell>"#,
                                         with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return decodingEntities(text)
    }

    private static let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                                   "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]

    private static func decodingEntities(_ text: String) -> String {
        var text = text
        for (entity, character) in entities where text.contains(entity) {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        guard text.contains("&#") else { return text }
        let pattern = /&#(x[0-9a-fA-F]+|[0-9]+);/
        return text.replacing(pattern) { match in
            let code = match.output.1
            let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? " "
        }
    }
}

// MARK: - Mail

/// The words of a message saved from Mail: who it was from and to, its
/// subject, and its body — the plain-text part where there is one, the HTML
/// part stripped where there is not. Headers are otherwise noise.
nonisolated enum MailText {
    static let keptHeaders: Set<String> = ["subject", "from", "to", "cc", "date"]

    static func text(of data: Data, isEmlx: Bool) -> String {
        var message = data
        // An .emlx is the message's length on a line of its own, the message,
        // then a property list of Mail's.
        if isEmlx, let newline = data.firstIndex(of: 0x0A),
           let length = Int(String(decoding: data[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)) {
            message = data[(newline + 1)...].prefix(length)
        }
        return part(Data(message), depth: 0)
    }

    /// One MIME part: its kept headers and its text.
    private static func part(_ data: Data, depth: Int) -> String {
        let (headers, body) = split(data)
        let type = headers["content-type"] ?? "text/plain"
        let lowerType = type.lowercased()
        var lines = depth == 0 ? headers.filter { keptHeaders.contains($0.key) }
            .sorted { $0.key < $1.key }.map { decodedWords($0.value) } : []

        if lowerType.hasPrefix("multipart/"), let boundary = parameter("boundary", in: type), depth < 8 {
            let parts = parts(of: body, boundary: boundary)
            let plain = parts.first { (split($0).headers["content-type"] ?? "text/plain").lowercased().hasPrefix("text/plain") }
            let alternatives = lowerType.hasPrefix("multipart/alternative") && plain != nil ? [plain!] : parts
            lines += alternatives.map { part($0, depth: depth + 1) }.filter { !$0.isEmpty }
        } else if lowerType.hasPrefix("text/") || lowerType.hasPrefix("message/") {
            let decoded = decodedBody(body, transfer: headers["content-transfer-encoding"]?.lowercased())
            let encoding = parameter("charset", in: type).flatMap(encoding(named:)) ?? .utf8
            let text = String(data: decoded, encoding: encoding) ?? String(decoding: decoded, as: UTF8.self)
            lines.append(lowerType.hasPrefix("text/html") ? FileContentReader.plainText(fromHTML: text) : text)
        }
        return lines.joined(separator: "\n")
    }

    /// Headers, unfolded and keyed lowercase, and the body after the blank line.
    private static func split(_ data: Data) -> (headers: [String: String], body: Data) {
        let crlf = data.firstRange(of: Data("\r\n\r\n".utf8))
        let lf = data.firstRange(of: Data("\n\n".utf8))
        let gap = [crlf, lf].compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
        let head = String(decoding: gap.map { data[..<$0.lowerBound] } ?? data, as: UTF8.self)
        let body = gap.map { Data(data[$0.upperBound...]) } ?? Data()
        var headers: [String: String] = [:]
        var current: String?
        for line in head.components(separatedBy: .newlines) where !line.isEmpty {
            if line.first == " " || line.first == "\t", let key = current {
                headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased()
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                current = key
            }
        }
        return (headers, body)
    }

    private static func parts(of body: Data, boundary: String) -> [Data] {
        let text = String(decoding: body, as: UTF8.self)
        return text.components(separatedBy: "--" + boundary).dropFirst()
            .filter { !$0.hasPrefix("--") }
            .map { Data($0.trimmingPrefix(while: \.isNewline).utf8) }
    }

    private static func parameter(_ name: String, in header: String) -> String? {
        for piece in header.split(separator: ";").dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == name else { continue }
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return nil
    }

    private static func decodedBody(_ body: Data, transfer: String?) -> Data {
        switch transfer {
        case "base64":
            let compact = String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }
            return Data(base64Encoded: compact) ?? body
        case "quoted-printable":
            return quotedPrintable(String(decoding: body, as: UTF8.self))
        default:
            return body
        }
    }

    private static func quotedPrintable(_ text: String, underscoresAreSpaces: Bool = false) -> Data {
        var bytes: [UInt8] = []
        var utf8 = Array(text.utf8)[...]
        while let byte = utf8.popFirst() {
            if byte == UInt8(ascii: "=") {
                if utf8.first == 0x0D { utf8 = utf8.dropFirst() }
                if utf8.first == 0x0A { utf8 = utf8.dropFirst(); continue }
                if utf8.count >= 2, let value = UInt8(String(decoding: utf8.prefix(2), as: UTF8.self), radix: 16) {
                    bytes.append(value)
                    utf8 = utf8.dropFirst(2)
                    continue
                }
            }
            bytes.append(underscoresAreSpaces && byte == UInt8(ascii: "_") ? 0x20 : byte)
        }
        return Data(bytes)
    }

    /// RFC 2047 encoded words in a header: `=?utf-8?Q?K=C3=B8b?=`.
    private static func decodedWords(_ header: String) -> String {
        let pattern = /=\?([^?]+)\?([bBqQ])\?([^?]*)\?=/
        return header.replacing(pattern) { match in
            let (_, charset, mode, payload) = match.output
            let data = mode.lowercased() == "b"
                ? Data(base64Encoded: String(payload)) ?? Data()
                : quotedPrintable(String(payload), underscoresAreSpaces: true)
            return String(data: data, encoding: encoding(named: String(charset)) ?? .utf8) ?? String(payload)
        }
    }

    static func encoding(named name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}

// MARK: - Zip

/// Just enough of a zip reader for documents: the central directory, and
/// stored or deflated entries, through the system's Compression. No zip64,
/// no encryption; an entry bigger than `maxEntrySize` is not inflated.
nonisolated struct ZipArchive {
    struct Entry {
        let name: String
        let method: Int
        let compressedSize: Int
        let size: Int
        let headerOffset: Int
    }

    static let maxEntrySize = 64 << 20

    private let data: Data
    private let entries: [String: Entry]
    /// Entry names in archive order.
    let names: [String]

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        self.data = data
        let count = data.count
        // The end-of-central-directory record, behind at most a 64 KB comment.
        var end: Int?
        var offset = count - 22
        while offset >= max(0, count - 22 - 0xFFFF) {
            if Self.u32(data, offset) == 0x0605_4B50 { end = offset; break }
            offset -= 1
        }
        guard let end, let total = Self.u16(data, end + 10), var cursor = Self.u32(data, end + 16) else { return nil }
        var entries: [String: Entry] = [:]
        var names: [String] = []
        for _ in 0..<total {
            guard Self.u32(data, cursor) == 0x0201_4B50,
                  let method = Self.u16(data, cursor + 10),
                  let compressed = Self.u32(data, cursor + 20), let size = Self.u32(data, cursor + 24),
                  let nameLength = Self.u16(data, cursor + 28), let extra = Self.u16(data, cursor + 30),
                  let comment = Self.u16(data, cursor + 32), let header = Self.u32(data, cursor + 42),
                  cursor + 46 + nameLength <= count
            else { return nil }
            let start = data.startIndex + cursor + 46
            let name = String(decoding: data[start..<start + nameLength], as: UTF8.self)
            entries[name] = Entry(name: name, method: method, compressedSize: compressed, size: size, headerOffset: header)
            names.append(name)
            cursor += 46 + nameLength + extra + comment
        }
        self.entries = entries
        self.names = names
    }

    /// The entry's bytes, inflated.
    func contents(of name: String) -> Data? {
        guard let entry = entries[name], entry.size <= Self.maxEntrySize,
              Self.u32(data, entry.headerOffset) == 0x0403_4B50,
              let nameLength = Self.u16(data, entry.headerOffset + 26),
              let extra = Self.u16(data, entry.headerOffset + 28)
        else { return nil }
        let start = entry.headerOffset + 30 + nameLength + extra
        guard start + entry.compressedSize <= data.count else { return nil }
        let compressed = data[(data.startIndex + start)..<(data.startIndex + start + entry.compressedSize)]
        switch entry.method {
        case 0:
            return Data(compressed)
        case 8:
            guard entry.size > 0 else { return Data() }
            guard entry.compressedSize > 0 else { return nil }
            var output = Data(count: entry.size)
            let written = output.withUnsafeMutableBytes { destination in
                compressed.withUnsafeBytes { source in
                    // COMPRESSION_ZLIB is raw DEFLATE, as zip stores it.
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                        source.bindMemory(to: UInt8.self).baseAddress!, entry.compressedSize,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            return written == entry.size ? output : nil
        default:
            return nil
        }
    }

    private static func u16(_ data: Data, _ offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let i = data.startIndex + offset
        return Int(data[i]) | Int(data[i + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let i = data.startIndex + offset
        return Int(data[i]) | Int(data[i + 1]) << 8 | Int(data[i + 2]) << 16 | Int(data[i + 3]) << 24
    }
}
