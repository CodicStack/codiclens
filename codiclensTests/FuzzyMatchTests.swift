import SwiftUI
import Testing
@testable import codiclens

/// The scoring ladder, and the cheap rejection that has to leave it untouched.
///
/// Lower is better and nil is no match. The tiers matter more than the numbers:
/// exact beats prefix beats substring beats subsequence beats typo, and nothing
/// may reorder them.
struct FuzzyMatchTests {

    @Test func theLadderRunsExactPrefixSubstringSubsequenceTypo() throws {
        let exact = try #require(fuzzyScore("safari", "safari"))
        let prefix = try #require(fuzzyScore("safari", "saf"))
        let substring = try #require(fuzzyScore("mobile safari", "safari"))
        let subsequence = try #require(fuzzyScore("safari", "sfi"))
        // A wrong character rather than a dropped one: dropping one leaves a
        // subsequence, which scores on the tier above.
        let typo = try #require(fuzzyScore("safari", "sefari"))

        #expect(exact < prefix)
        #expect(prefix < substring)
        #expect(substring < subsequence)
        #expect(subsequence < typo)
    }

    @Test func anEarlierSubstringScoresBetterThanALaterOne() throws {
        let early = try #require(fuzzyScore("x code", "code"))
        let late = try #require(fuzzyScore("xxxxxxx code", "code"))

        #expect(early < late)
    }

    @Test func nothingInCommonIsNoMatch() {
        #expect(fuzzyScore("safari", "qqq") == nil)
        #expect(fuzzyScore("safari", "") == nil)
    }

    // MARK: - Typo tolerance survives the length-difference rejection

    /// `fuzzyScore` rejects on the length difference before building the
    /// Levenshtein matrix, because the distance can never be less than that
    /// difference. These are the cases that must still get through it.
    @Test(arguments: [
        ("safari", "safri"),      // a dropped character
        ("safari", "sefari"),     // a wrong character
        ("safari", "saffari"),    // a doubled character
        ("notes", "notez"),
    ])
    func aTypoOfTheWholeNameStillMatches(name: String, query: String) {
        #expect(fuzzyScore(name, query) != nil, "\(query) should still find \(name)")
    }

    /// The rejection's whole point: a short Query against a long name cannot be
    /// a typo of it, and must not pay for the matrix to find that out.
    @Test(arguments: ["q", "qq", "qqzz"])
    func aShortQueryIsNeverATypoOfALongName(query: String) {
        #expect(fuzzyScore("some very long application name", query) == nil)
    }

    /// A six-character Query has a threshold of two, so a two-character length
    /// difference is not enough to reject on its own.
    @Test func aLongerQueryKeepsAWiderTolerance() {
        #expect(fuzzyScore("keynote", "keynot") != nil)
        #expect(fuzzyScore("keynotes", "keynote") != nil)
    }

    // MARK: - The distance itself

    @Test(arguments: [
        ("", "", 0),
        ("a", "", 1),
        ("", "abc", 3),
        ("kitten", "sitting", 3),
        ("safari", "safari", 0),
    ])
    func levenshteinCountsEdits(a: String, b: String, expected: Int) {
        #expect(levenshteinDistance(a, b) == expected)
    }

    // MARK: - Marking up what matched

    /// The characters of `name` that came back underlined, as a string.
    private func underlined(_ name: String, query: String) -> String {
        let attributed = highlightedName(name, query: query)
        return attributed.runs.reduce(into: "") { marked, run in
            guard run.underlineStyle != nil else { return }
            marked += String(attributed[run.range].characters)
        }
    }

    /// Underline, not weight. Weight was tried and is invisible against a row
    /// whose title is already bold.
    @Test func aMatchIsMarkedWithAnUnderline() {
        let attributed = highlightedName("Safari", query: "saf")

        #expect(attributed.runs.contains { $0.underlineStyle != nil })
        #expect(!attributed.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    }

    /// Tier one: the Query appears whole, so the whole run is underlined once —
    /// not character by character.
    @Test func aContiguousMatchUnderlinesTheWholeRun() {
        #expect(underlined("Safari", query: "saf") == "Saf")
        #expect(underlined("Mobile Safari", query: "safari") == "Safari")

        let attributed = highlightedName("Safari", query: "saf")
        let marked = attributed.runs.filter { $0.underlineStyle != nil }
        #expect(marked.count == 1, "one run, not three")
    }

    /// Tier two: the Query is spread through the name, so each character it
    /// matched is underlined where it landed. This is the case the user
    /// screenshotted — "clib" against "Clipboard History" marks `Cli` and `b`.
    @Test func aScatteredMatchUnderlinesEachCharacterItMatched() {
        #expect(underlined("Clipboard History", query: "clib") == "Clib")
        #expect(underlined("Safari", query: "sfi") == "Sfi")
    }

    /// A Query the name cannot account for marks nothing. Emoji are matched by
    /// keyword as well as by name, so this is the ordinary case there: "smile"
    /// finds 😀 through its keywords, and underlining the `n` and `g` of
    /// "grinning face" that happen to line up would claim a match that isn't in
    /// the name at all.
    @Test func aQueryTheNameCannotAccountForMarksNothing() {
        #expect(underlined("grinning face", query: "smile").isEmpty)
        #expect(underlined("Safari", query: "sefari").isEmpty, "a typo match has no run to mark")
        #expect(underlined("Safari", query: "").isEmpty)
    }

    /// Marking up must not disturb the text itself.
    @Test func theNameSurvivesUnchanged() {
        #expect(String(highlightedName("Clipboard", query: "clib").characters) == "Clipboard")
        #expect(String(highlightedName("Safari", query: "zzz").characters) == "Safari")
    }
}
