// The fusion of meaning and words, the per-modality scale, the lookup and kind-word rules and the stopwords are
// adapted from DigUp's Searcher.swift (https://github.com/ARahim3/DigUp), MIT licence — see docs/licenses/digup/LICENSE.
import Accelerate
import Foundation
import Metal

/// Search by meaning: File Results found by what a file says, shows or sounds
/// like rather than by its name. The vectors come from EmbeddingGemma 2 on
/// llama.cpp, in a helper process (`EmbeddingService`); the model files are
/// downloaded at launch unless the user has turned it off (`ModelFiles`,
/// `MeaningSettings`).
nonisolated enum MeaningSearch {
    /// Whether this Mac can search by meaning at all: Apple silicon with a
    /// Metal device. llama.cpp is built for arm64 only
    /// (`Scripts/build-llama.sh`), so on an Intel Mac the feature is
    /// unavailable rather than slow, and nothing downloads the model there.
    static let isSupported: Bool = {
        #if arch(arm64)
        return MTLCreateSystemDefaultDevice() != nil
        #else
        return false
        #endif
    }()
}

/// What made a vector. Text, picture and sound vectors sit at different
/// levels for the same Query (DigUp measured 0.75–0.86 for text against
/// 0.67–0.78 for pictures), so each is centred on its own average before they
/// are compared (`MeaningRanking.zScores`).
nonisolated enum MeaningModality: UInt8, Sendable, CaseIterable {
    case text = 0
    case image = 1
    case audio = 2
}

/// How a settled search ranks a file by meaning and words together: DigUp's
/// fusion, which beat reciprocal-rank fusion on both of its evals (2026-10-07:
/// R@1 0.88 against 0.73 synthetic, 0.86 against 0.82 real).
///
/// 1. Every vector's cosine with the Query is put on this Query's scale
///    (`zScores`): minus its modality's average, in standard deviations of all
///    of them. Only a file whose best segment stands out by `zGate` counts as
///    found by meaning, which is also what makes "nothing found" honest.
/// 2. A file is a candidate by meaning (z ≥ `zGate`) or by words (at least
///    `coverageGate` of the Query's words in it).
/// 3. Its score is `meaningWeight × max(z, 0) + wordWeight × coverage^1.5`,
///    plus 1 when a Kind Word or a Kind Hint names its Kind ("video",
///    "notes": `liftedKinds`). A "lookup" — IDs and numbers like `K7Q2LM` or
///    `#1234` — weighs words double and meaning half: they mean nothing to an
///    embedding.
/// 4. A Kind Word ("video", "billede", "pdf": `askedKinds`) puts its Kind
///    first in any Query, ahead of name matches of every other Kind: the
///    Kind's name matches, then the rest of it. With a topic ("video of me
///    speaking", "billede af kontrakten") the rest is every candidate of the
///    Kind by its score, however far down the files found by meaning,
///    filled up to `kindGuesses` with the Kind's best z below the gate, since
///    a Kind Word is a request even when nothing stands out; a name that
///    matched only the Kind Word ranks among them by its score. A Query that is only a Kind ("videos", "my videos", "video file":
///    `isKindOnly`) means nothing beyond the Kind, which the per-modality scale
///    centres away, so its rest is the Kind's newest files instead, the
///    whole block at most `kindOnlyFiles`. A folder word with something else
///    to look for does the same for folders, by their names and paths
///    (`asksForFolders`). A Kind Hint never puts anything first: "release
///    notes" is not a request for notes.
nonisolated enum MeaningRanking {
    static let zGate = 2.0
    static let coverageGate = 0.5
    static let wordWeight = 2.0
    /// The scale's standard deviation never goes below this: a Query every
    /// vector scores alike on would otherwise make noise look like a match.
    static let deviationFloor = 0.02
    /// A modality with fewer vectors than this takes the overall average:
    /// three photos say nothing about where photos sit.
    static let minimumModalityRows = 20
    /// How many files found by meaning join every search, best first. More
    /// cannot reach a list of 50 below the name matches. The Kind a Kind
    /// Word asks for takes every one of its own (`MeaningScores.gated`).
    static let meaningCandidates = 200
    /// How many files of the Kind a Kind Word asks for come first with a
    /// topic, at least: its best guesses fill up to this when fewer stand
    /// out by meaning or words.
    static let kindGuesses = 10
    /// How many files of the Kind come first when the Query is only a Kind:
    /// its newest, below its name matches.
    static let kindOnlyFiles = 25

    // MARK: - The scale

    /// Which rows count for what, as 1s and 0s to multiply by: per modality,
    /// its live rows, and of those the ones that set the scale. Kept up to
    /// date row by row (`MeaningVectors.Rows`), so a Query pays for none of it.
    struct Masks: Sendable {
        var ofModality: [[Float]] = Array(repeating: [], count: MeaningModality.allCases.count)
        var inScale: [[Float]] = Array(repeating: [], count: MeaningModality.allCases.count)
        var anyInScale: [Float] = []
        var removed: [Int] = []

        init() {}

        init(modality: [UInt8], setsScale: [Bool], alive: [Bool]) {
            for row in modality.indices {
                append(modality: MeaningModality(rawValue: modality[row]) ?? .text, setsScale: setsScale[row],
                       alive: alive[row])
            }
        }

        mutating func append(modality: MeaningModality, setsScale: Bool, alive: Bool) {
            for other in MeaningModality.allCases {
                let isIt = other == modality && alive
                ofModality[Int(other.rawValue)].append(isIt ? 1 : 0)
                inScale[Int(other.rawValue)].append(isIt && setsScale ? 1 : 0)
            }
            anyInScale.append(alive && setsScale ? 1 : 0)
            if !alive { removed.append(ofModality[0].count - 1) }
        }

        mutating func remove(_ row: Int) {
            for modality in MeaningModality.allCases.map({ Int($0.rawValue) }) {
                ofModality[modality][row] = 0
                inScale[modality][row] = 0
            }
            anyInScale[row] = 0
            removed.append(row)
        }
    }

    /// This Query's meaning scores: each vector's cosine minus its modality's
    /// average, in standard deviations of all of them together. Within a
    /// modality that is the model's own order. Scaling each modality by its
    /// own deviation instead inflated the narrow ones (DigUp, 2026-10-08:
    /// 91 → 94 of 105 first).
    ///
    /// The averages and the deviation come from the live rows that set the
    /// scale only: the later pages of long files are scored on the scale but
    /// do not move it — a book's hundreds of pages pulled the text average
    /// down for every Query (DigUp, 2026-10-09). A removed row scores
    /// -infinity. Whole-array arithmetic over the masks: 300,000 rows in a
    /// few milliseconds.
    static func zScores(_ scores: [Float], masks: Masks) -> [Float] {
        let modalities = MeaningModality.allCases.map { Int($0.rawValue) }
        let counts = modalities.map { vDSP.sum(masks.inScale[$0]) }
        let sums = modalities.map { vDSP.dot(scores, masks.inScale[$0]) }
        let total = max(counts.reduce(0, +), 1)
        let overall = sums.reduce(0, +) / total
        var expected = [Float](repeating: 0, count: scores.count)
        for modality in modalities {
            let mean = counts[modality] >= Float(minimumModalityRows) ? sums[modality] / counts[modality] : overall
            expected = vDSP.add(multiplication: (masks.ofModality[modality], mean), expected)
        }
        var centered = vDSP.subtract(scores, expected)
        let mean = vDSP.dot(centered, masks.anyInScale) / total
        centered = vDSP.add(-mean, centered)
        let variance = vDSP.dot(vDSP.multiply(centered, centered), masks.anyInScale) / total
        var z = vDSP.divide(centered, max(variance.squareRoot(), Float(deviationFloor)))
        for row in masks.removed { z[row] = -.infinity }
        return z
    }

    /// `zScores` from plain arrays, for a test.
    static func zScores(_ scores: [Float], modality: [UInt8], setsScale: [Bool], alive: [Bool]) -> [Float] {
        zScores(scores, masks: Masks(modality: modality, setsScale: setsScale, alive: alive))
    }

    // MARK: - Fusion

    static func isCandidate(z: Double?, coverage: Double) -> Bool {
        (z ?? -.infinity) >= zGate || coverage >= coverageGate
    }

    /// The fused score, higher is better. `isKindLifted`: a Kind Word or a
    /// Kind Hint of the Query names the file's Kind.
    static func score(z: Double?, coverage: Double, isKindLifted: Bool, isLookup: Bool) -> Double {
        let (meaningWeight, wordsWeight) = isLookup ? (0.5, wordWeight * 2) : (1.0, wordWeight)
        return meaningWeight * max(z ?? 0, 0) + wordsWeight * pow(coverage, 1.5) + (isKindLifted ? 1 : 0)
    }

    // MARK: - The Query's words

    /// The stopwords that only hold a sentence together ("for", "the", "af",
    /// "me", "mig"), which the word search need not find and which never
    /// begin a longer word once typing pauses (`FileIndexReader.requiredWords`).
    /// Not the Kind Words, the folder words, nor the kind nouns "file" and
    /// "fil": a name that says "pdf" or "file" is what a Query that says it
    /// wants. English and Danish.
    static let functionWords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "with", "and", "or", "my", "me", "that", "this",
        "these", "those", "from", "about", "where", "what", "which", "who", "when", "is", "was", "are", "were", "be",
        "it", "its", "some", "any", "find", "show",
        "og", "eller", "på", "til", "af", "med", "en", "et", "den", "det", "de", "der", "som", "min", "mit",
        "mine", "fra", "om", "hvor", "hvad", "hvilken", "hvilket", "hvem", "hvornår", "er", "var", "har",
        "jeg", "vi", "du", "noget", "nogle", "vis", "mig", "dig", "sig", "ham", "hende", "os", "jer", "dem",
    ]

    /// The kind nouns: "file" asks for no Kind, only for a file.
    static let fileWords: Set<String> = ["file", "files", "fil", "filer"]

    /// Words that say nothing about what is in a file: the function words,
    /// the file words, and the Kind Words and folder words, which say what
    /// to look for rather than what is in it (`askedKinds` and
    /// `asksForFolders` put that first instead). A Kind Hint is a word: it
    /// may be the topic.
    static let stopwords: Set<String> = functionWords
        .union(fileWords)
        .union(kindWords.keys)
        .union(folderWords)

    /// The Query's content words as keyword search sees them, once each:
    /// stopwords out, and words of at least two letters.
    static func terms(_ query: String) -> [String] {
        var seen = Set<String>()
        return FileIndexReader.words(query).filter {
            $0.unicodeScalars.count >= 2 && !stopwords.contains($0) && seen.insert($0).inserted
        }
    }

    /// Codes and IDs ("K7Q2LM", "TRX50") and long numbers ("4815162342", an
    /// order or a phone number) mean nothing to an embedding and everything
    /// to keyword search.
    static func isLookup(_ terms: [String]) -> Bool {
        !terms.isEmpty && terms.allSatisfy {
            $0.contains(where: \.isNumber) && ($0.contains(where: \.isLetter) || $0.count >= 4)
        }
    }

    /// The Kind Words (`GLOSSARY.md`): words that ask for a Kind outright,
    /// in any Query, and put it first (`MeaningRanking`, 4). A picture word
    /// asks for photos and screenshots alike; a screenshot word for
    /// screenshots alone.
    static let kindWords: [String: Set<FileContent>] = {
        var words: [String: Set<FileContent>] = [:]
        for word in ["video", "videos", "videoen", "videoer"] { words[word] = [.video] }
        for word in ["photo", "photos", "picture", "pictures", "image", "images", "billede", "billeder", "billedet",
                     "foto", "fotos", "fotoet"] {
            words[word] = [.image, .screenshot]
        }
        for word in ["screenshot", "screenshots", "skærmbillede", "skærmbilleder", "skærmbilledet"] {
            words[word] = [.screenshot]
        }
        for word in ["pdf", "pdfs"] { words[word] = [.pdf] }
        for word in ["recording", "recordings", "optagelse", "optagelser", "optagelsen", "audio", "lyd", "lydfil",
                     "lydfiler", "lyden", "podcast", "podcasts"] {
            words[word] = [.audio]
        }
        return words
    }()

    /// The Kind Hints (`GLOSSARY.md`): words that may name a Kind or may
    /// just be the topic ("release notes", "film om havet"). They lift that
    /// Kind by the score's +1 and never put it first, and they are words the
    /// Query looks for.
    static let kindHints: [String: Set<FileContent>] = {
        var words: [String: Set<FileContent>] = [:]
        for word in ["document", "documents", "dokument", "dokumenter", "dokumentet", "note", "notes", "noter",
                     "notat", "notater"] {
            words[word] = [.document, .text]
        }
        for word in ["paper", "papers"] { words[word] = [.pdf] }
        for word in ["clip", "clips", "klip", "klippene", "movie", "movies", "film", "filmen"] { words[word] = [.video] }
        for word in ["song", "songs", "sang", "sange", "music", "musik", "sound", "sounds", "voice", "voices",
                     "stemme"] {
            words[word] = [.audio]
        }
        return words
    }()

    /// Words that ask for a folder, the way a Kind Word asks for a Kind:
    /// "code folder for data intensive systems", "mappen med regnskabet". A
    /// folder is a `FileIndexRow.Kind`, not a `FileContent`, and has no
    /// vectors, so the folders whose name or path match the rest of the
    /// Query come first, by their words alone (`asksForFolders`). The word
    /// search does not require them; on the keystroke a folder wins only a
    /// tie on one (`FileIndexReader.search`).
    static let folderWords: Set<String> = ["folder", "folders", "mappe", "mapper", "mappen"]

    /// The words a kind-only Query may have beside its Kind Words: the file
    /// words and the determiners ("my videos", "video file", "alle
    /// billeder"). Anything else is a topic.
    static let kindOnlyWords: Set<String> = fileWords.union([
        "a", "an", "the", "my", "our", "your", "some", "all", "any",
        "en", "et", "den", "det", "de", "min", "mit", "mine", "din", "dit", "dine", "vores", "nogle", "alle",
    ])

    /// Whether the Query asks for folders: a folder word, and something else
    /// to look for in their names or paths. "folder" or "my folders" alone
    /// asks for nothing.
    static func asksForFolders(_ query: String) -> Bool {
        let words = FileIndexReader.words(query)
        return words.contains(where: folderWords.contains)
            && !FileIndexReader.requiredWords(words, isSettled: true).words.contains(where: folderWords.contains)
    }

    /// The Kinds the Query's Kind Words put first: "…in a video", "billede
    /// af…", "screenshot pdf". None beside a folder word: "video folder"
    /// asks for folders.
    static func askedKinds(_ query: String) -> Set<FileContent> {
        guard !asksForFolders(query) else { return [] }
        return FileIndexReader.words(query).reduce(into: Set<FileContent>()) { $0.formUnion(kindWords[$1] ?? []) }
    }

    /// The Kinds the score lifts by 1: every Kind its Kind Words and Kind
    /// Hints name.
    static func liftedKinds(_ query: String) -> Set<FileContent> {
        FileIndexReader.words(query).reduce(into: Set<FileContent>()) {
            $0.formUnion(kindWords[$1] ?? [])
            $0.formUnion(kindHints[$1] ?? [])
        }
    }

    /// Whether the Query is only a Kind: it has a Kind Word, and every other
    /// word is a file word or a determiner (`kindOnlyWords`: "videos", "my
    /// videos", "video file", "billeder"). "image of me" has a topic.
    static func isKindOnly(_ query: String) -> Bool {
        !askedKinds(query).isEmpty
            && FileIndexReader.words(query).allSatisfy { kindWords[$0] != nil || kindOnlyWords.contains($0) }
    }
}

/// What one Query's vector made of every vector in the File Index, by file:
/// the files that stand out, best first, and any file's best segment on
/// demand.
nonisolated struct MeaningScores: Sendable {
    struct Match: Equatable, Sendable {
        let file: Int64
        let z: Double
        let segment: Int64
    }

    /// Every file whose best segment reaches `MeaningRanking.zGate`, best
    /// first. The scan that finds them is the one that scores every row, so
    /// keeping all of them costs nothing more: a Kind Word takes every one of
    /// its Kind from here, however far down (`FileIndexReader.fusedSearch`).
    let gated: [Match]
    /// Any file's best segment, or nil for a file with no vectors.
    let best: @Sendable (Int64) -> Match?

    /// The files found by meaning that join every search: the best
    /// `MeaningRanking.meaningCandidates` of `gated`. More cannot reach a
    /// list of 50 below the name matches.
    var top: ArraySlice<Match> { gated.prefix(MeaningRanking.meaningCandidates) }

    static let empty = MeaningScores(gated: [], best: { _ in nil })

    /// Scores every row of `vectors` against `query` and puts them on this
    /// Query's scale.
    init(_ vectors: MeaningVectors.Snapshot, query: [Float]) {
        self.init(rows: vectors.rows, scores: vectors.scores(query))
    }

    /// `scores`, the cosine of every row in `rows`, on this Query's scale.
    init(rows: MeaningVectors.Rows, scores: [Float]) {
        let z = MeaningRanking.zScores(scores, masks: rows.masks)
        var bestRow: [Int64: Int] = [:]
        let gate = Float(MeaningRanking.zGate)
        z.withUnsafeBufferPointer { z in
            rows.file.withUnsafeBufferPointer { files in
                for row in 0..<z.count where z[row] >= gate {
                    if let current = bestRow[files[row]], z[current] >= z[row] { continue }
                    bestRow[files[row]] = row
                }
            }
        }
        gated = bestRow.values
            .sorted { z[$0] > z[$1] }
            .map { Match(file: rows.file[$0], z: Double(z[$0]), segment: rows.segment[$0]) }
        best = { file in
            guard let indices = rows.ofFile[file], let row = indices.max(by: { z[$0] < z[$1] }) else { return nil }
            return Match(file: file, z: Double(z[row]), segment: rows.segment[row])
        }
    }

    init(gated: [Match], best: @escaping @Sendable (Int64) -> Match?) {
        self.gated = gated
        self.best = best
    }
}
