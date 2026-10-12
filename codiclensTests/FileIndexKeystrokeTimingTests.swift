import Foundation
import Testing
@testable import codiclens

private let keystrokeIndex = ProcessInfo.processInfo.environment["CODICLENS_TIME_KEYSTROKES"]

/// The per-keystroke word search over an index already on disk, read-only:
/// every prefix of a few Queries as they are typed, trailing space included,
/// each run `runs` times. Prints median, p90 and worst per Query. Off unless
/// asked for; the value is the database, or `1` for the app's own in
/// Application Support (a copy is kinder: the running app writes to it).
///
/// ```
/// TEST_RUNNER_CODICLENS_TIME_KEYSTROKES=/tmp/FileIndex.sqlite xcodebuild test \
///   -project codiclens.xcodeproj -scheme codiclens -configuration Debug \
///   -only-testing:codiclensTests/FileIndexKeystrokeTimingTests
/// ```
@Suite(.serialized, .enabled(if: keystrokeIndex != nil), .timeLimit(.minutes(20)))
struct FileIndexKeystrokeTimingTests {
    static let typed = ["the quick", "kontrakt", "invoice 2024", "const value", "function", "a b", "de", "pro"]
    static let runs = 9

    @Test func everyKeystroke() throws {
        let url = keystrokeIndex == "1" ? FileIndex.defaultDatabaseURL : URL(fileURLWithPath: keystrokeIndex ?? "")
        let reader = FileIndexReader(url: url)
        let sources = Array(reader.counts().keys)
        print("index \(url.path), sources \(sources)")
        var queries: [String] = []
        for text in Self.typed {
            for end in text.indices.dropFirst() + [text.endIndex] { queries.append(String(text[..<end])) }
            queries.append(text + " ")
        }
        for mode in [FileIndexReader.PassageMatch.wholeWords, .lastWordPrefix] {
            print("— \(mode == .wholeWords ? "on the keystroke (whole words in Passages)" : "settled (last word a prefix)")")
            measure(queries, mode: mode, reader: reader, sources: sources)
        }
    }

    private func measure(_ queries: [String], mode: FileIndexReader.PassageMatch, reader: FileIndexReader,
                         sources: [String]) {
        var worst: (String, Duration) = ("", .zero)
        var all: [Duration] = []
        for query in queries {
            var samples: [Duration] = []
            var hits: [FileHit] = []
            for _ in 0..<Self.runs {
                samples.append(ContinuousClock().measure { hits = reader.search(query, limit: 50, sources: sources, passages: mode) })
            }
            let first = samples[0]
            samples.sort()
            all += samples
            if samples.last! > worst.1 { worst = (query, samples.last!) }
            print("\("\"\(query)\"".padding(toLength: 18, withPad: " ", startingAt: 0)) median \(ms(samples[samples.count / 2]))"
                  + "  p90 \(ms(samples[samples.count * 9 / 10]))  max \(ms(samples.last!))  first \(ms(first))"
                  + "  \(hits.count) hits, \(hits.filter { $0.passage != nil }.count) by contents")
        }
        all.sort()
        print("all: median \(ms(all[all.count / 2])), p90 \(ms(all[all.count * 9 / 10])), "
              + "worst \(ms(worst.1)) for \"\(worst.0)\"")
    }

    private func ms(_ duration: Duration) -> String {
        String(format: "%.1f ms", Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
    }
}
