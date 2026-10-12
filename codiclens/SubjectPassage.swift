import Foundation
import PDFKit
import UniformTypeIdentifiers

/// A File Result's Passage (`GLOSSARY.md`, **Passage**) as it travels with the
/// Subject chosen from it: the row, the Subject, the Subject Card, and the
/// Action Phase after Tab. What the Card shows of the file, where Shift+Space
/// opens it, and the moment Enter plays a recording from.
///
/// The Panel's own value, not `FileHit.Passage` itself, for two reasons: the
/// File Index can change its row's shape without the Panel following it, and a
/// test can make a timed Passage before the File Index has times at all.
nonisolated struct SubjectPassage: Hashable, Sendable {
    /// A few words either side of the match, on one line, as FTS5's
    /// `snippet()` cut them — "…" where it cut.
    let excerpt: String
    /// The words the Query matched literally, in characters of `excerpt`.
    /// None for a Passage found by its meaning alone.
    let matches: [Range<Int>]
    /// The PDF page, from 1.
    let page: Int?
    /// Where in a recording or a video it starts, in seconds.
    let seconds: Double?
    /// Where it starts in the text the File Index read, in UTF-16 units: the
    /// chunk's location. Where there is none, the preview looks for the
    /// excerpt in the whole text.
    let textOffset: Int?

    init(excerpt: String, matches: [Range<Int>] = [], page: Int? = nil,
         seconds: Double? = nil, textOffset: Int? = nil) {
        self.excerpt = excerpt
        self.matches = matches
        self.page = page
        self.seconds = seconds
        self.textOffset = textOffset
    }

    /// The File Index's Passage. A span in a recording or a video, found by
    /// meaning, starts at `seconds`: the video's frame on the Card, the
    /// player's start and QuickTime's. The File Index keeps no text offset,
    /// so a text Passage is looked for in the whole text.
    init(_ passage: FileHit.Passage) {
        self.init(excerpt: passage.excerpt, matches: passage.matches, page: passage.page, seconds: passage.start)
    }

    /// "page 4".
    var pageLabel: String? { page.map { "page \($0)" } }

    /// "at 14:02".
    var momentLabel: String? { seconds.map { "at " + Self.clock($0) } }

    /// A time as a player shows one: "14:02", "1:02:05".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// The excerpt with its matched words underlined.
    var markedExcerpt: AttributedString { underlined(excerpt, marks: matches) }
}

/// `text` with `marks`, in characters, underlined: how the app marks what a
/// Query matched, on a Result's Passage and on the Subject Card's.
nonisolated func underlined(_ text: String, marks: [Range<Int>]) -> AttributedString {
    var attributed = AttributedString(text)
    let length = text.count
    for mark in marks where mark.lowerBound >= 0 && mark.upperBound <= length {
        let start = attributed.index(attributed.startIndex, offsetByCharacters: mark.lowerBound)
        let end = attributed.index(start, offsetByCharacters: mark.count)
        attributed[start..<end].underlineStyle = .single
    }
    return attributed
}

// MARK: - The Panel's own preview

/// What Shift+Space opens for a File Result that matched inside the file: the
/// Panel's own preview, in place of the Results Slab, at the Passage.
///
/// Apple's Quick Look has no public way to highlight a word or start a video
/// at a second, so a file that matched inside gets this instead. One that
/// matched on its name, an image (its words were read by OCR; the picture is
/// the thing), and a format with no reader here (an iWork page) keep Quick
/// Look.
nonisolated struct PassagePreview: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// `PDFView` at the page, the matched words highlighted.
        case pdf(page: Int)
        /// The text the File Index read, scrolled to the Passage.
        case text(monospaced: Bool)
        /// `AVPlayerView`, playing from the moment.
        case media(seconds: Double, isVideo: Bool)
    }

    let url: URL
    let title: String
    let passage: SubjectPassage
    let kind: Kind

    /// The preview for `passage` in the file at `url`, or nil where Quick Look
    /// shows it instead.
    init?(url: URL, title: String, contentType: UTType, passage: SubjectPassage) {
        let ext = url.pathExtension.lowercased()
        let kind: Kind
        if let page = passage.page {
            guard contentType.conforms(to: .pdf) else { return nil }
            kind = .pdf(page: page)
        } else if Self.isRecording(url) {
            guard let seconds = passage.seconds else { return nil }
            kind = .media(seconds: seconds, isVideo: FileContent.videoExtensions.contains(ext))
        } else if contentType.conforms(to: .image) || ["pages", "key", "numbers"].contains(ext) {
            // An iWork file is read through the PDF it carries, by page.
            return nil
        } else {
            let isProse = FileContent.textExtensions.contains(ext)
                || FileContent.documentExtensions.contains(ext)
                || ext == "rtfd"
            kind = .text(monospaced: !isProse)
        }
        self.url = url
        self.title = title
        self.passage = passage
        self.kind = kind
    }

    /// Whether `url` is a recording or a video, by its extension as the File
    /// Index judges it: `.ts` conforms to video and is TypeScript far more
    /// often.
    static func isRecording(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return FileContent.audioExtensions.contains(ext) || FileContent.videoExtensions.contains(ext)
    }

    /// What the preview's header says beside the name.
    var locationLabel: String? {
        switch kind {
        case .pdf: passage.pageLabel
        case .media: passage.momentLabel
        case .text: nil
        }
    }
}

// MARK: - Finding the Passage again

/// Where a Passage is in the text it was read from, and its matched words
/// there. The File Index keeps a snippet, not a place, so the snippet is
/// looked for: its words in order, any whitespace between them, the case
/// ignored — the snippet folded every run of whitespace into one space.
nonisolated enum PassageFind {
    struct Found {
        /// The whole excerpt, or the one word found where the excerpt was not.
        let focus: Range<String.Index>
        /// The matched words, highlighted.
        let marks: [Range<String.Index>]
    }

    /// How far past `textOffset` the excerpt is looked for before the whole
    /// text is: a chunk is ~1,800 characters.
    static let offsetWindow = 4096

    static func find(_ passage: SubjectPassage, in text: String) -> Found? {
        let words = Self.words(of: passage.excerpt)
        guard !words.isEmpty else { return nil }
        let pattern = words
            .map { "(" + NSRegularExpression.escapedPattern(for: String($0.text)) + ")" }
            .joined(separator: "\\s+")
        let whole = NSRange(text.startIndex..., in: text)
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           let match = window(around: passage.textOffset, in: whole).flatMap({ regex.firstMatch(in: text, range: $0) })
            ?? regex.firstMatch(in: text, range: whole),
           let focus = Range(match.range, in: text) {
            let marks = passage.matches.compactMap { mark -> Range<String.Index>? in
                guard let index = words.firstIndex(where: { $0.start <= mark.lowerBound && mark.lowerBound < $0.start + $0.text.count }),
                      let word = Range(match.range(at: index + 1), in: text) else { return nil }
                let offset = mark.lowerBound - words[index].start
                let length = min(mark.count, words[index].text.count - offset)
                guard let start = text.index(word.lowerBound, offsetBy: offset, limitedBy: word.upperBound),
                      let end = text.index(start, offsetBy: length, limitedBy: word.upperBound) else { return nil }
                return start..<end
            }
            return Found(focus: focus, marks: marks)
        }

        // Not there as cut — a word the reader dropped, an entity decoded
        // differently. The first matched word will do, on its own.
        guard let first = passage.matches.first,
              let word = substring(of: passage.excerpt, first),
              let range = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive])
        else { return nil }
        return Found(focus: range, marks: [range])
    }

    /// The Passage on its PDF page: the page, where on it to scroll, and the
    /// matched words as selections there.
    static func selections(in document: PDFDocument, for passage: SubjectPassage)
        -> (page: PDFPage, focus: PDFSelection?, marks: [PDFSelection])? {
        guard let number = passage.page, let page = document.page(at: number - 1) else { return nil }
        guard let text = page.string, let found = find(passage, in: text) else { return (page, nil, []) }
        let marks = found.marks.compactMap { page.selection(for: NSRange($0, in: text)) }
        return (page, page.selection(for: NSRange(found.focus, in: text)), marks)
    }

    /// The excerpt's words, each with where it starts in characters, the
    /// snippet's "…" taken off the ends.
    static func words(of excerpt: String) -> [(text: Substring, start: Int)] {
        var words: [(text: Substring, start: Int)] = []
        var begin: (index: String.Index, offset: Int)?
        var offset = 0
        for index in excerpt.indices {
            if excerpt[index].isWhitespace {
                if let word = begin { words.append((excerpt[word.index..<index], word.offset)) }
                begin = nil
            } else if begin == nil {
                begin = (index, offset)
            }
            offset += 1
        }
        if let word = begin { words.append((excerpt[word.index...], word.offset)) }

        if let first = words.first {
            let text = first.text.drop { $0 == "…" }
            words[0] = (text, first.start + first.text.count - text.count)
        }
        if let last = words.last {
            let text = last.text.dropLast(last.text.reversed().prefix { $0 == "…" }.count)
            words[words.count - 1] = (text, last.start)
        }
        return words.filter { !$0.text.isEmpty }
    }

    private static func window(around offset: Int?, in whole: NSRange) -> NSRange? {
        guard let offset, offset >= 0, offset < whole.length else { return nil }
        return NSRange(location: offset, length: min(offsetWindow, whole.length - offset))
    }

    private static func substring(of text: String, _ range: Range<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= text.count else { return nil }
        let start = text.index(text.startIndex, offsetBy: range.lowerBound)
        return String(text[start..<text.index(start, offsetBy: range.count)])
    }
}

/// The text a preview shows: what the File Index read, through the same
/// reader, so a Passage's place in it is the place it was read at.
nonisolated enum PassageTextReader {
    static func read(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if FileContent.documentExtensions.contains(ext) || ext == "rtfd" {
            return FileContentReader.documentText(url)
        }
        return FileContentReader.sniffedText(
            url,
            allowsLegacyEncoding: FileContent.textExtensions.contains(ext),
            limit: FileContentReader.maxTextBytes
        )?.text
    }
}
