import Foundation
import SwiftUI

/// Underlines the characters of `name` that `query` matched.
///
/// Two tiers, and they are the top two of `fuzzyScore`'s: a contiguous
/// substring match underlines the whole run, and otherwise every matched
/// character is underlined on its own.
///
/// **Underline, not weight.** Weight was tried and rejected: at 13pt a bolded
/// character or two inside a name is barely a difference, and where the name is
/// already bold — a selected row draws its title bold — it is no difference at
/// all. An underline reads at any weight.
///
/// The subsequence tier only runs when the **whole** Query is a subsequence of
/// the name. That is what keeps a highlight honest: Emoji are matched by their
/// keywords as well as their names, and a keyword hit has nothing to underline
/// in the CLDR name — underlining the two or three characters that happen to
/// line up before the Query runs out marks up a match that isn't there. Nothing
/// to say means plain text, not scattered marks.
func highlightedName(_ name: String, query: String) -> AttributedString {
    var attributed = AttributedString(name)
    guard !query.isEmpty else { return attributed }

    let lower = name.lowercased()
    let queryLower = query.lowercased()

    if let range = lower.range(of: queryLower) {
        let start = lower.distance(from: lower.startIndex, to: range.lowerBound)
        let length = lower.distance(from: range.lowerBound, to: range.upperBound)

        let attrStart = attributed.index(attributed.startIndex, offsetByCharacters: start)
        let attrEnd = attributed.index(attrStart, offsetByCharacters: length)
        attributed[attrStart..<attrEnd].underlineStyle = .single
        return attributed
    }

    guard isSubsequence(queryLower, of: lower) else { return attributed }

    var qi = queryLower.startIndex
    for (i, char) in lower.enumerated() {
        guard qi < queryLower.endIndex else { break }
        if char == queryLower[qi] {
            let attrIdx = attributed.index(attributed.startIndex, offsetByCharacters: i)
            let attrNext = attributed.index(attrIdx, offsetByCharacters: 1)
            attributed[attrIdx..<attrNext].underlineStyle = .single
            qi = queryLower.index(after: qi)
        }
    }

    return attributed
}

func fuzzyScore(_ name: String, _ query: String) -> Int? {
    let n = name.lowercased()
    let q = query.lowercased()

    if q.isEmpty { return nil }

    if n == q { return 0 }

    if n.hasPrefix(q) { return 1 }

    if let range = n.range(of: q) {
        let offset = n.distance(from: n.startIndex, to: range.lowerBound)
        return 10 + offset
    }

    if isSubsequence(q, of: n) {
        return 50
    }

    // Typo tolerance, and the expensive branch: everything above rejects in a
    // scan, this builds a matrix. Most candidates reach it — a Query matches a
    // handful of names and *nothing else about* the other 1,900 — so the cheap
    // rejection below is what keeps ranking the whole emoji dataset affordable.
    let prefixLen = min(n.count, q.count + 2)
    let threshold = max(1, q.count / 3)

    // An edit changes a string's length by at most one, so the distance can
    // never be smaller than the difference in length. When that lower bound is
    // already over the threshold the matrix cannot change the answer. Exactly
    // equivalent, not an approximation — and for any Query under six characters
    // it rejects every name longer than the Query plus one, which is almost all
    // of them.
    if abs(prefixLen - q.count) > threshold { return nil }

    let dist = levenshteinDistance(q, String(n.prefix(prefixLen)))
    if dist <= threshold {
        return 100 + dist
    }

    return nil
}

private func isSubsequence(_ query: String, of target: String) -> Bool {
    var qi = query.startIndex
    for char in target {
        if qi < query.endIndex && char == query[qi] {
            qi = query.index(after: qi)
        }
    }
    return qi == query.endIndex
}

func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
    let a = Array(s1.lowercased())
    let b = Array(s2.lowercased())
    let m = a.count
    let n = b.count

    if m == 0 { return n }
    if n == 0 { return m }

    var previous = Array(0...n)
    var current = [Int](repeating: 0, count: n + 1)

    for i in 1...m {
        current[0] = i
        for j in 1...n {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            current[j] = min(
                previous[j] + 1,
                current[j - 1] + 1,
                previous[j - 1] + cost
            )
        }
        previous = current
    }

    return current[n]
}
