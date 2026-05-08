import Foundation
import SwiftUI

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

    let prefixLen = min(n.count, q.count + 2)
    let nPrefix = String(n.prefix(prefixLen))
    let dist = levenshteinDistance(q, nPrefix)
    if dist <= max(1, q.count / 3) {
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
