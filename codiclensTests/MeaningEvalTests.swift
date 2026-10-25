import Foundation
import NaturalLanguage
import Testing
@testable import codiclens

private let evalRequested = ProcessInfo.processInfo.environment["CODICLENS_MEANING_EVAL"] != nil
private let evalURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("codiclens/eval/eval.json")

/// The gate before search by meaning ships: real Queries against the real
/// File Index, the full settled search (`FileIndexReader.fusedSearch` over
/// the vectors the app has made, the Query embedded by the real query
/// encoder), and how often an expected file is in the top five — overall, by
/// language and by what the expected file is. The bar is 80%. Lists every
/// miss with what came instead, and the word search's rate beside it.
///
/// The set is the user's: `~/Library/Application Support/codiclens/eval/eval.json`,
/// an array of `{"query": "…", "expected": ["/Users/…/file.pdf", …]}`, each
/// optionally with `"language": "da"`; without one the language is guessed.
/// Nothing here writes it. The index is only read; the app may be running.
///
/// ```
/// TEST_RUNNER_CODICLENS_MEANING_EVAL=1 xcodebuild test \
///   -project codiclens.xcodeproj -scheme codiclens -configuration Debug \
///   -parallel-testing-enabled NO -only-testing:codiclensTests/MeaningEvalTests
/// ```
@Suite(
    .serialized,
    .enabled(if: evalRequested),
    .enabled(if: FileManager.default.fileExists(atPath: evalURL.path),
             "No eval set at ~/Library/Application Support/codiclens/eval/eval.json: skipped"),
    .timeLimit(.minutes(20))
)
struct MeaningEvalTests {
    struct Case: Decodable {
        let query: String
        let expected: [String]
        let language: String?
    }

    static let bar = 0.8

    @Test func topFiveHitRate() async throws {
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: evalURL))
        let database = FileIndex.defaultDatabaseURL
        let reader = FileIndexReader(url: database)
        let sources = Array(reader.counts().keys)
        let vectors = MeaningVectors(databaseURL: database)
        let opened = vectors.open(expectedRows: reader.vectorRows())
        print("\(cases.count) queries over \(sources.count) Sources, \(opened ? vectors.liveCount : 0) vectors"
              + (opened ? "" : " (the vector files do not match the database: words only)"))
        let encoder = EmbeddingClient.helper(textOnly: true, idleExit: 30)
        try await encoder.hold()
        defer { Task { await encoder.shutdown() } }

        var tally: [String: (hits: Int, words: Int, total: Int)] = [:]
        func count(_ key: String, hit: Bool, words: Bool) {
            tally[key, default: (0, 0, 0)].total += 1
            if hit { tally[key, default: (0, 0, 0)].hits += 1 }
            if words { tally[key, default: (0, 0, 0)].words += 1 }
        }
        var misses: [String] = []
        for test in cases {
            let vector = try await encoder.embedQuery(test.query, code: false)
            let scores = opened ? vectors.snapshot().map { MeaningScores($0, query: vector) } ?? .empty : .empty
            let fused = reader.fusedSearch(test.query, limit: 5, sources: sources, meaning: scores)
            let words = reader.search(test.query, limit: 5, sources: sources, passages: .lastWordPrefix)
            let expected = Set(test.expected.map { ($0 as NSString).expandingTildeInPath })
            let isHit = fused.contains { expected.contains($0.url.path) }
            let isWordHit = words.contains { expected.contains($0.url.path) }
            let language = test.language ?? Self.language(of: test.query)
            let kind = test.expected.first.flatMap { reader.content(atPath: ($0 as NSString).expandingTildeInPath) }
            count("all", hit: isHit, words: isWordHit)
            count("language \(language)", hit: isHit, words: isWordHit)
            count("kind \(kind.map { "\($0)" } ?? "not indexed")", hit: isHit, words: isWordHit)
            if !isHit {
                misses.append("✗ \"\(test.query)\" wanted \(test.expected.map { ($0 as NSString).lastPathComponent })\n"
                              + fused.map { "      \($0.score) \($0.name) \($0.meaning.map { "\($0)" } ?? "words")" }
                                  .joined(separator: "\n"))
            }
        }
        print("top-5 hit rate (fused / words alone):")
        for (key, value) in tally.sorted(by: { $0.key < $1.key }) {
            print("  \(key.padding(toLength: 22, withPad: " ", startingAt: 0)) "
                  + "\(value.hits)/\(value.total) = \(Int((Double(value.hits) / Double(value.total) * 100).rounded()))%"
                  + "   words \(value.words)/\(value.total)")
        }
        print(misses.joined(separator: "\n"))
        let all = tally["all"] ?? (0, 0, 1)
        #expect(Double(all.hits) / Double(all.total) >= Self.bar, "below the \(Int(Self.bar * 100))% bar")
    }

    static func language(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.danish, .english]
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "?"
    }
}
