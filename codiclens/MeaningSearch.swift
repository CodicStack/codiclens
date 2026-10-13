// The fusion of meaning and words, the per-modality scale, the lookup and kind-word rules and the stopwords are
// adapted from DigUp's Searcher.swift (https://github.com/ARahim3/DigUp), MIT licence — see digup-license.txt.
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
///    plus 1 when the Query names its kind ("video", "skærmbillede").
///    A "lookup" — IDs and numbers like `K7Q2LM` or `#1234` — weighs words
///    double and meaning half: they mean nothing to an embedding.
/// 4. A Query that is only a kind ("audio file", "billeder", "music": every
///    word a kind word or a stopword, `isKindOnly`) means nothing beyond the
///    kind, which the per-modality scale centres away, so no file of that
///    kind would come in. Its newest files of that kind are candidates
///    instead, ahead of the rest, newest first; a file with its words still
///    comes in by coverage, after them.
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
    /// How many files found by meaning a search looks at, best first. More
    /// cannot reach a list of 50 below the name matches.
    static let meaningCandidates = 200

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

    /// `isAskedForAlone`: the file is of the kind a Query asks for, and the
    /// Query is only a kind (`isKindOnly`): it is a candidate by its kind.
    static func isCandidate(z: Double?, coverage: Double, isAskedForAlone: Bool = false) -> Bool {
        isAskedForAlone || (z ?? -.infinity) >= zGate || coverage >= coverageGate
    }

    /// The fused score, higher is better.
    static func score(z: Double?, coverage: Double, isKindAskedFor: Bool, isLookup: Bool) -> Double {
        let (meaningWeight, wordsWeight) = isLookup ? (0.5, wordWeight * 2) : (1.0, wordWeight)
        return meaningWeight * max(z ?? 0, 0) + wordsWeight * pow(coverage, 1.5) + (isKindAskedFor ? 1 : 0)
    }

    // MARK: - The Query's words

    /// Words that say nothing about what is in a file: function words, and
    /// the kind words, which say what to look for rather than what is in it
    /// (`kindWords` turns those into a boost instead; `folderWords` into a
    /// tiebreak). English and Danish.
    static let stopwords: Set<String> = [
        "folder", "folders", "mappe", "mapper", "mappen",
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "with", "and", "or", "my", "me", "that", "this",
        "these", "those", "from", "about", "where", "what", "which", "who", "when", "is", "was", "are", "were", "be",
        "it", "its", "some", "any", "find", "show", "file", "files", "photo", "photos", "picture", "pictures",
        "image", "images", "screenshot", "screenshots", "video", "videos", "pdf", "pdfs", "document", "documents",
        "recording", "recordings", "audio", "sound", "sounds",
        "og", "eller", "på", "til", "af", "for", "med", "en", "et", "den", "det", "de", "der", "som", "min", "mit",
        "mine", "fra", "om", "hvor", "hvad", "hvilken", "hvilket", "hvem", "hvornår", "er", "var", "at", "har",
        "jeg", "vi", "du", "noget", "nogle", "fil", "filer", "find", "vis", "billede", "billeder", "foto", "fotos",
        "skærmbillede", "skærmbilleder", "dokument", "dokumenter", "optagelse", "optagelser", "lyd", "lydfil",
        "lydfiler", "videoer",
    ]

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

    /// Words that ask for a kind of file: a soft boost, not a filter. Only a
    /// Query of nothing but kind words lists that kind first (`MeaningRanking`, 4).
    static let kindWords: [String: Set<FileContent>] = {
        var words: [String: Set<FileContent>] = [:]
        for word in ["screenshot", "screenshots", "skærmbillede", "skærmbilleder", "skærmbilledet"] {
            words[word] = [.screenshot]
        }
        for word in ["photo", "photos", "picture", "pictures", "image", "images", "billede", "billeder", "billedet",
                     "foto", "fotos", "fotoet"] {
            words[word] = [.image]
        }
        for word in ["pdf", "pdfs", "paper", "papers"] { words[word] = [.pdf] }
        for word in ["document", "documents", "note", "notes", "dokument", "dokumenter", "dokumentet",
                     "noter", "notat", "notater"] {
            words[word] = [.document, .text]
        }
        for word in ["video", "videos", "clip", "clips", "movie", "movies", "film", "filmen", "videoen", "videoer", "klip",
                     "klippene"] {
            words[word] = [.video]
        }
        for word in ["audio", "song", "songs", "podcast", "podcasts", "voice", "voices", "sound", "sounds", "recording",
                     "recordings", "music", "lyd", "lydfil", "lydfiler", "lyden", "sang", "sange", "musik", "optagelse",
                     "optagelser", "optagelsen", "stemme"] {
            words[word] = [.audio]
        }
        return words
    }()

    /// Words that ask for a folder: "code folder for data intensive systems",
    /// "mappen med regnskabet". A folder is a `FileIndexRow.Kind`, not a
    /// `FileContent`, so these are no `kindWords`: the word search does not
    /// require them, and a folder wins a tie on them (`FileIndexReader.search`).
    /// Never a filter, and never a list of folders on their own.
    static let folderWords: Set<String> = ["folder", "folders", "mappe", "mapper", "mappen"]

    /// The stopwords that only hold a sentence together ("for", "the", "af"),
    /// which the word search need not find. Not the kind words, nor the kind
    /// nouns "file" and "fil": a name that says "pdf" or "file" is what a
    /// Query that says it wants.
    static let functionWords: Set<String> = stopwords
        .subtracting(kindWords.keys)
        .subtracting(folderWords)
        .subtracting(["file", "files", "fil", "filer"])

    /// Whether the Query is only a kind: it names one, and every word that
    /// is not a stopword is a kind word ("audio file", "music", "lydfiler").
    static func isKindOnly(_ query: String) -> Bool {
        !kindHints(query).isEmpty && terms(query).allSatisfy { kindWords[$0] != nil }
    }

    /// The kinds the Query asks for: "…in a video", "skærmbillede af…".
    static func kindHints(_ query: String) -> Set<FileContent> {
        FileIndexReader.words(query).reduce(into: Set<FileContent>()) { $0.formUnion(kindWords[$1] ?? []) }
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

    /// Files whose best segment reaches `MeaningRanking.zGate`, best first,
    /// at most `MeaningRanking.meaningCandidates`.
    let top: [Match]
    /// Any file's best segment, or nil for a file with no vectors.
    let best: @Sendable (Int64) -> Match?

    static let none = MeaningScores(top: [], best: { _ in nil })

    /// Scores every row of `vectors` against `query` and puts them on this
    /// Query's scale.
    init(_ vectors: MeaningVectors.Snapshot, query: [Float]) {
        let rows = vectors.rows
        let z = MeaningRanking.zScores(vectors.scores(query), masks: rows.masks)
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
        top = bestRow.values
            .sorted { z[$0] > z[$1] }
            .prefix(MeaningRanking.meaningCandidates)
            .map { Match(file: rows.file[$0], z: Double(z[$0]), segment: rows.segment[$0]) }
        best = { file in
            guard let indices = rows.ofFile[file], let row = indices.max(by: { z[$0] < z[$1] }) else { return nil }
            return Match(file: file, z: Double(z[row]), segment: rows.segment[row])
        }
    }

    init(top: [Match], best: @escaping @Sendable (Int64) -> Match?) {
        self.top = top
        self.best = best
    }
}
