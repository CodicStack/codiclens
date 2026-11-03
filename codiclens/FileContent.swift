// Chunking and the screenshot test adapted from DigUp's Extractors.swift and Rules.swift
// (https://github.com/ARahim3/DigUp), MIT licence — see docs/licenses/digup/LICENSE.
import Foundation

/// What the File Index reads out of a file besides its name, and so when:
/// the raw value is the reading order of both background passes. Screenshots
/// first, then photos, PDFs and documents, plain text, recordings and videos,
/// and code — with every file whose type is not known, which is read if it
/// turns out to be text — last. A file with none of these has nothing to
/// read: a folder, an archive, a font.
///
/// The contents pass (`FileContentScheduler`) reads the ones with words
/// (`hasWords`); the meaning pass (`MeaningScheduler`) gives every one of
/// them vectors, the words it read included.
nonisolated enum FileContent: Int, Sendable, CaseIterable {
    /// OCR for keyword search, and the picture itself for meaning.
    case screenshot = 0
    /// A photo or any other picture: meaning only.
    case image = 1
    /// PDFKit's text, a Passage per page; a page with little text is read
    /// for meaning as a picture.
    case pdf = 2
    /// Word, RTF, OpenDocument, Office, HTML, ePub, mail, and an iWork file's
    /// preview PDF.
    case document = 3
    /// Notes and plain text, known by their extension.
    case text = 4
    /// A recording: meaning only, in windows of its sound.
    case audio = 5
    /// A video: meaning only, its frames and its soundtrack.
    case video = 6
    /// Source code, and anything else that sniffs as text.
    case code = 7

    /// Whether the contents pass reads words out of it. The rest have only
    /// what the meaning pass sees and hears.
    var hasWords: Bool {
        switch self {
        case .screenshot, .pdf, .document, .text, .code: true
        case .image, .audio, .video: false
        }
    }

    /// What `path` holds, judged from its name — and for an image, from the
    /// screenshot flag macOS writes on it. Nothing is opened: the crawl calls
    /// this for every file. Whether an unknown file really is text is decided
    /// when it is read (`FileContentReader`); its extension is never the gate.
    static func of(_ entry: FileIndexRules.Entry) -> FileContent? {
        let ext = (entry.path as NSString).pathExtension.lowercased()
        if entry.isPackage {
            return packageDocuments.contains(ext) ? .document : nil
        }
        if entry.isDirectory { return nil }
        if ext == "pdf" { return .pdf }
        if ext == "key" { return entry.startsWithZipMagic ? .document : .code }
        if documentExtensions.contains(ext) || packageDocuments.contains(ext) { return .document }
        if imageExtensions.contains(ext) { return isScreenshot(entry.path) ? .screenshot : .image }
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        if binaryExtensions.contains(ext) { return nil }
        if textExtensions.contains(ext) { return .text }
        return .code
    }

    /// Read through `FileContentReader`'s document path. A `.key` that is not
    /// a zip is a private key, and text.
    static let documentExtensions: Set<String> = [
        "rtf", "doc", "docx", "odt", "ods", "odp", "xlsx", "pptx", "epub",
        "html", "htm", "xhtml", "webarchive", "eml", "emlx"
    ]

    /// Documents that may be a folder on disk: RTF with attachments, and
    /// iWork, which saves either a package or a single zip.
    static let packageDocuments: Set<String> = ["rtfd", "pages", "key", "numbers"]

    /// Notes and prose: read before code.
    static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "mdown", "rst", "org", "adoc", "asciidoc", "tex", "srt", "vtt", "csv", "tsv"
    ]

    /// Pictures ImageIO decodes: a screenshot, or a photo for the meaning
    /// pass.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"
    ]

    /// Recordings AVFoundation opens. Ogg and Opus are not among them, and
    /// stay with the binaries.
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "flac", "aif", "aiff", "caf"]

    /// Videos AVFoundation opens; AVI, MKV and WebM do not.
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Formats that are never text, left out without opening them: pictures,
    /// recordings, archives, fonts, compiled code and databases. A fast path,
    /// not a filter: anything not on it is sniffed. `.ts` is not here — it is
    /// TypeScript far more often than an MPEG stream, and the sniff tells.
    static let binaryExtensions: Set<String> = [
        "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "psd", "ai", "sketch", "fig", "ico", "icns",
        "mp3", "m4a", "wav", "aac", "flac", "aif", "aiff", "ogg", "opus", "caf", "mid", "midi",
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "wmv", "3gp",
        "zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "tar", "dmg", "iso", "pkg", "jar", "whl", "xip",
        "woff", "woff2", "ttf", "otf", "ttc",
        "o", "a", "so", "dylib", "dll", "exe", "class", "pyc", "wasm", "bin", "dat", "node",
        "sqlite", "sqlite3", "db", "realm", "parquet", "npy", "npz", "pt", "pth", "onnx", "safetensors", "gguf",
        "ckpt", "h5", "pb", "tflite", "mlmodel", "pdb", "car", "nib", "xls", "ppt"
    ]

    /// Data and logs: what a program wrote, not a person. Every Passage of one
    /// is read and found by its words, but only the meaning pass's first step
    /// (`MeaningPass.firstChunks`) gets vectors: the 1,500th chunk of a
    /// training log or a JSON Lines dump says what its first ones did. On the
    /// dev machine (2026-10-12) these were ~65% of the text left to embed,
    /// 144,554 vectors, most of them `.json` and `.jsonl`.
    static let dataExtensions: Set<String> = ["json", "jsonl", "ndjson", "geojson", "csv", "tsv", "log", "err", "out"]

    /// A `.txt` is a log too in a folder of these names, at any depth, or
    /// named `*.log.txt` or `log_*`.
    static let logFolders: Set<String> = ["log", "logs"]

    /// Whether `path` is data or a log (`dataExtensions`, `logFolders`),
    /// judged from its name alone.
    static func isDataOrLog(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        if dataExtensions.contains(ext) { return true }
        guard ext == "txt" else { return false }
        if name.hasSuffix(".log.txt") || name.hasPrefix("log_") { return true }
        let folders = ((path as NSString).deletingLastPathComponent as NSString).pathComponents
        return folders.contains { logFolders.contains($0.lowercased()) }
    }

    /// Names macOS and the common screenshot tools give a screenshot, in
    /// English and Danish.
    static let screenshotPrefixes = ["Screenshot", "Screen Shot", "Skærmbillede", "CleanShot", "SCR-"]

    /// macOS marks a screenshot with an extended attribute that survives moves
    /// and copies; a name like one, or a folder of them, is the fallback.
    static func isScreenshot(_ path: String) -> Bool {
        if getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0 { return true }
        let name = (path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
        if screenshotPrefixes.contains(where: name.hasPrefix) { return true }
        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            .precomposedStringWithCanonicalMapping.lowercased()
        return folder.contains("screenshot") || folder.contains("skærmbillede")
    }
}

/// One Passage as it is read: a stretch of text and where in the file it is.
nonisolated struct FilePassage: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// A stretch of a text file or document; `location` is its offset in
        /// UTF-16 units into the text read.
        case chunk
        /// A PDF page; `location` is its number, from 1.
        case page
        /// Text OCR read out of an image; no location. Keyword search only:
        /// the picture's own vector is its meaning.
        case ocr
        // The meaning pass's, with a vector and no words.
        /// A picture, or a screenshot as a picture.
        case image
        /// A PDF page with too little text, embedded as a picture; `location`
        /// is its number.
        case pageImage = "page_image"
        /// A video frame; `location` to `end` is the stretch it stands for, in
        /// seconds.
        case frame
        /// A window of a recording or a video's soundtrack, in seconds.
        case audio

        /// What made its vector, for the per-modality scale of a search
        /// (`MeaningRanking.zScores`). Nil for one that never has a vector.
        var modality: MeaningModality? {
            switch self {
            case .chunk, .page: .text
            case .image, .pageImage, .frame: .image
            case .audio: .audio
            case .ocr: nil
            }
        }
    }

    let kind: Kind
    let location: Double?
    let text: String
}

/// A file whose contents are next to read, as the writer hands it out.
nonisolated struct FileContentJob: Equatable, Sendable {
    let id: Int64
    let path: String
    let content: FileContent
    let size: Int64
    let mtime: Double
    /// Pages or chunks read so far: a later step starts here.
    let readTo: Int
}

/// What reading a file came to, as the writer takes it back. Plain values,
/// so the reading can happen anywhere — later, in a helper process.
nonisolated struct FileContentResult: Sendable {
    let job: FileContentJob
    var passages: [FilePassage] = []
    /// Pages or chunks read once these are stored.
    var readTo: Int
    /// Nothing left to read. Otherwise the file waits for a later step.
    var isComplete = true
    /// Why nothing, or not everything, was read: "not text", "locked".
    var detail: String?
}

/// Cutting text into Passages.
nonisolated enum FileChunker {
    /// ~1,800 characters, about 450 tokens, overlapping by 200 so a phrase cut
    /// in two is whole in one of them.
    static let size = 1800
    static let overlap = 200

    /// The chunks of `text` numbered `range` (from 0), each with its offset
    /// in UTF-16 units, and how many there are in all, counting no further
    /// than `cap`. Cut at whitespace where there is any in the second half of
    /// a chunk, and the same way every time, so a later step carries on where
    /// the last one stopped.
    static func chunks(_ text: String, range: Range<Int>, cap: Int) -> (chunks: [(offset: Int, text: String)], total: Int) {
        let string = text as NSString
        let length = string.length
        let whitespace = CharacterSet.whitespacesAndNewlines
        var chunks: [(offset: Int, text: String)] = []
        var index = 0
        var start = 0

        func isSpace(_ location: Int) -> Bool {
            guard let scalar = Unicode.Scalar(string.character(at: location)) else { return false }
            return whitespace.contains(scalar)
        }

        while index < cap {
            while start < length, isSpace(start) { start += 1 }
            guard start < length else { break }
            var end = min(start + size, length)
            if end < length {
                let half = NSRange(location: start + size / 2, length: end - start - size / 2)
                let space = string.rangeOfCharacter(from: whitespace, options: .backwards, range: half)
                if space.location != NSNotFound {
                    end = space.location
                } else {
                    // No whitespace to break at, as in a minified file: cut,
                    // but not inside a character.
                    end = string.rangeOfComposedCharacterSequence(at: end).location
                    if end <= start { end = NSMaxRange(string.rangeOfComposedCharacterSequence(at: start)) }
                }
            }
            if range.contains(index) {
                let chunk = clean(string.substring(with: NSRange(location: start, length: end - start)))
                if !chunk.isEmpty { chunks.append((start, chunk)) }
            }
            index += 1
            guard end < length else { break }
            // The next chunk starts `overlap` back, on a word boundary.
            let back = end - overlap
            if back <= start {
                start = end
            } else {
                let space = string.rangeOfCharacter(from: whitespace, range: NSRange(location: back, length: end - back))
                start = space.location == NSNotFound ? end : space.location
            }
        }
        return (chunks, index)
    }

    /// One Passage's text as it is stored: runs of blanks squeezed, blanks
    /// at either end of a line dropped, and unbroken runs of 120 or more
    /// letters and digits — base64, hashes, a minified bundle's data —
    /// dropped too, since no one types them and each would be a token of its
    /// own.
    static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"[A-Za-z0-9+/=_\-]{120,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t\u{00A0}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" ?\r?\n ?"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
