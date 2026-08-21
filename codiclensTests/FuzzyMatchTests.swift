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
}
