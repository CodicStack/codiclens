#!/usr/bin/env swift

// Generates codiclens/emoji-index.json and codiclens/emoji-data-license.txt.
//
// Run it from the repository root:
//
//     swift Scripts/generate-emoji-index.swift
//
// Options:
//     --cache <dir>     keep/reuse the downloaded sources there (default: a temp dir)
//     --out <dir>       where to write the generated files (default: ./codiclens)
//     --unicode <ver>   Unicode emoji version (default: 17.0)
//     --cldr <tag>      CLDR release tag suffix (default: 48)
//
// Bumping to a newer Emoji release is one command with new --unicode/--cldr values.
//
// Why three sources: emoji-test.txt gives the canonical list, order, grouping and
// qualification status but no search keywords. CLDR annotations/en.xml carries
// keywords for the simple emoji only — every ZWJ sequence and every skin-tone
// sequence lives in annotationsDerived/en.xml instead, so both are required or
// roughly a third of the rows come out keyword-less.
//
// The join gotcha: CLDR strips U+FE0F (VS16) from its `cp` keys. Looking up
// "\u{261D}\u{FE0F}" finds nothing; looking up "\u{261D}" finds it. Every lookup
// here goes through `cldrKey`, which also strips the skin-tone modifiers so a
// toned sequence resolves back to its base.

import Foundation

// MARK: - Arguments

func argument(_ name: String, default fallback: String) -> String {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return fallback }
    return args[i + 1]
}

let unicodeVersion = argument("unicode", default: "17.0")
let cldrVersion = argument("cldr", default: "48")
let outputDirectory = URL(fileURLWithPath: argument("out", default: "codiclens"), isDirectory: true)
let cacheDirectory = URL(
    fileURLWithPath: argument(
        "cache",
        default: NSTemporaryDirectory() + "codiclens-emoji-sources"
    ),
    isDirectory: true
)

// MARK: - Sources

struct Source {
    let name: String
    let url: URL
}

let unicodeMajorMinor = unicodeVersion.contains(".") ? unicodeVersion : unicodeVersion + ".0"
let sources = [
    Source(
        name: "emoji-test.txt",
        url: URL(string: "https://www.unicode.org/Public/\(unicodeMajorMinor).0/emoji/emoji-test.txt")!
    ),
    Source(
        name: "annotations-en.xml",
        url: URL(string: "https://raw.githubusercontent.com/unicode-org/cldr/release-\(cldrVersion)/common/annotations/en.xml")!
    ),
    Source(
        name: "annotations-derived-en.xml",
        url: URL(string: "https://raw.githubusercontent.com/unicode-org/cldr/release-\(cldrVersion)/common/annotationsDerived/en.xml")!
    ),
]

func fetch(_ source: Source) -> String {
    try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let cached = cacheDirectory.appendingPathComponent(source.name)
    if let text = try? String(contentsOf: cached, encoding: .utf8) {
        FileHandle.standardError.write(Data("  cached  \(source.name)\n".utf8))
        return text
    }
    FileHandle.standardError.write(Data("  fetch   \(source.url.absoluteString)\n".utf8))
    guard let data = try? Data(contentsOf: source.url),
          let text = String(data: data, encoding: .utf8) else {
        FileHandle.standardError.write(Data("could not fetch \(source.url)\n".utf8))
        exit(1)
    }
    try? data.write(to: cached)
    return text
}

// MARK: - Scalar helpers

let variationSelector16: Unicode.Scalar = "\u{FE0F}"
let skinToneModifiers: [Unicode.Scalar] = ["\u{1F3FB}", "\u{1F3FC}", "\u{1F3FD}", "\u{1F3FE}", "\u{1F3FF}"]
let skinToneSet = Set(skinToneModifiers.map(\.value))

func hasSkinToneModifier(_ string: String) -> Bool {
    string.unicodeScalars.contains { skinToneSet.contains($0.value) }
}

/// The key both CLDR files are indexed by: the sequence with U+FE0F removed.
///
/// This is the gotcha in the whole join. CLDR strips VS16 from every `cp`, so
/// looking up "\u{261D}\u{FE0F}" verbatim finds nothing and roughly a quarter
/// of the rows come back keyword-less without a word of complaint.
func cldrKey(_ string: String) -> String {
    guard string.unicodeScalars.contains(variationSelector16) else { return string }
    return String(String.UnicodeScalarView(string.unicodeScalars.filter { $0 != variationSelector16 }))
}

/// The key a toned sequence shares with the base it is a variant of: no VS16,
/// no skin-tone modifiers.
///
/// Both have to go. A modifier *replaces* the VS16 in a sequence —
/// "\u{26F9}\u{FE0F}\u{200D}\u{2640}\u{FE0F}" becomes
/// "\u{26F9}\u{1F3FB}\u{200D}\u{2640}\u{FE0F}" — so dropping only one of
/// the two leaves the toned form pointing at nothing.
///
/// Deliberately *not* the CLDR key: collapsing tones there would make all six
/// variants of an emoji share one annotation entry, and the derived file would
/// quietly overwrite every base name with "…: dark skin tone".
func baseKey(_ string: String) -> String {
    String(String.UnicodeScalarView(string.unicodeScalars.filter {
        $0 != variationSelector16 && !skinToneSet.contains($0.value)
    }))
}

// MARK: - emoji-test.txt

struct TestRow {
    let string: String
    let unicodeName: String
    let group: String
}

func parseEmojiTest(_ text: String) -> (base: [TestRow], toned: [TestRow]) {
    var base: [TestRow] = []
    var toned: [TestRow] = []
    var group = ""

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("# group:") {
            group = String(trimmed.dropFirst("# group:".count)).trimmingCharacters(in: .whitespaces)
            continue
        }
        if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }

        // "<code points> ; <status> # <emoji> E<version> <name>"
        //
        // Split on the *first* separator each time. The keycap rows carry a
        // literal "#" in their name — "0023 FE0F 20E3 ; fully-qualified # #\u{FE0F}\u{20E3} E0.6 keycap: #"
        // — so splitting on every "#" silently loses them.
        guard let semicolon = trimmed.firstIndex(of: ";") else { continue }
        let tail = trimmed[trimmed.index(after: semicolon)...]
        guard let hash = tail.firstIndex(of: "#") else { continue }

        let status = tail[..<hash].trimmingCharacters(in: .whitespaces)
        guard status == "fully-qualified" else { continue }
        // The Component group is modifiers and hair styles, not pickable emoji.
        guard group != "Component" else { continue }

        var comment = tail[tail.index(after: hash)...]
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .map(String.init)
        guard comment.count >= 3 else { continue }
        let string = comment.removeFirst()
        comment.removeFirst()                       // the "E<version>" token
        let row = TestRow(string: string, unicodeName: comment.joined(separator: " "), group: group)

        if hasSkinToneModifier(string) {
            toned.append(row)
        } else {
            base.append(row)
        }
    }
    return (base, toned)
}

// MARK: - CLDR annotations

struct Annotation {
    var name: String?
    var keywords: [String]?
}

func unescapeXML(_ string: String) -> String {
    guard string.contains("&") else { return string }
    return string
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&apos;", with: "'")
        .replacingOccurrences(of: "&amp;", with: "&")
}

/// A regex parse rather than XMLParser: the annotation files are one flat
/// element per line, and the DTD reference in the prologue makes the tree
/// parsers want to hit the network.
func parseAnnotations(_ text: String, into table: inout [String: Annotation]) {
    let pattern = #"<annotation cp="([^"]*)"(\s+type="tts")?>([^<]*)</annotation>"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let nsText = text as NSString

    regex.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { match, _, _ in
        guard let match else { return }
        let cp = unescapeXML(nsText.substring(with: match.range(at: 1)))
        let isName = match.range(at: 2).location != NSNotFound
        let value = unescapeXML(nsText.substring(with: match.range(at: 3)))
        let key = cldrKey(cp)

        var entry = table[key] ?? Annotation()
        if isName {
            entry.name = value
        } else {
            entry.keywords = value
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        table[key] = entry
    }
}

// MARK: - Build

FileHandle.standardError.write(Data("Generating emoji index (Unicode \(unicodeVersion), CLDR \(cldrVersion))\n".utf8))

let (baseRows, tonedRows) = parseEmojiTest(fetch(sources[0]))

var annotations: [String: Annotation] = [:]
parseAnnotations(fetch(sources[1]), into: &annotations)
parseAnnotations(fetch(sources[2]), into: &annotations)

var groups: [String] = []
var groupIndex: [String: Int] = [:]
for row in baseRows where groupIndex[row.group] == nil {
    groupIndex[row.group] = groups.count
    groups.append(row.group)
}

struct Row: Encodable {
    let e: String   // the emoji itself, fully qualified
    let n: String   // CLDR short name
    let k: [String] // CLDR keywords
    let g: Int      // index into `groups`
}

var rows: [Row] = []
var missingKeywords: [String] = []
var missingNames: [String] = []

for row in baseRows {
    let annotation = annotations[cldrKey(row.string)]
    let keywords = annotation?.keywords ?? []
    if keywords.isEmpty { missingKeywords.append(row.string) }
    if annotation?.name == nil { missingNames.append(row.string) }
    rows.append(Row(
        e: row.string,
        n: annotation?.name ?? row.unicodeName,
        k: keywords,
        g: groupIndex[row.group]!
    ))
}

// The side table. Variants are looked up by string from this same parse and
// never synthesised: in a ZWJ sequence the modifier sits after the *base*
// scalar mid-string, and some sequences take two independent tones.
// Keyed by the base emoji exactly as it appears in `emoji`, so the app looks
// variants up with the string it already has rather than re-deriving a key.
var skinToneTable: [String: [String]] = [:]
var orphanedToneVariants: [String] = []
var baseStringByKey: [String: String] = [:]
for row in baseRows { baseStringByKey[baseKey(row.string)] = row.string }

// A handful of two-tone sequences are not their base with modifiers inserted:
// 🤝 is U+1F91D, but its two-tone forms re-encode as U+1FAF1 <tone> ZWJ
// U+1FAF2 <tone>, so stripping the tones lands on a sequence that is not a row
// at all. CLDR's name is the reliable bridge — "handshake: light skin tone,
// medium-light skin tone" names its base outright.
var baseKeyByName: [String: String] = [:]
for row in rows { baseKeyByName[row.n] = row.e }

/// The names a toned variant might file itself under, most specific first.
///
/// "handshake: light skin tone, medium-light skin tone" drops its tone clauses
/// and lands on "handshake" directly. "kiss: person, person, light skin tone,
/// dark skin tone" has no untoned row of its own — Unicode says the untoned
/// form of that sequence *is* 💏 — so the qualifiers come off one at a time
/// until "kiss" matches. Only trailing clauses that are entirely skin tones are
/// dropped first, which is what keeps "keycap: #" intact.
func baseNameCandidates(_ name: String) -> [String] {
    var parts = name.components(separatedBy: ", ")
    while let last = parts.last, last.hasSuffix("skin tone"), parts.count > 1 {
        parts.removeLast()
    }
    var candidates = [parts.joined(separator: ", ")]
    while let colon = candidates[candidates.count - 1].range(of: ": ", options: .backwards) {
        candidates.append(String(candidates[candidates.count - 1][..<colon.lowerBound]))
    }
    return candidates
}

for row in tonedRows {
    if let base = baseStringByKey[baseKey(row.string)] {
        skinToneTable[base, default: []].append(row.string)
        continue
    }
    if let name = annotations[cldrKey(row.string)]?.name,
       let base = baseNameCandidates(name).lazy.compactMap({ baseKeyByName[$0] }).first {
        skinToneTable[base, default: []].append(row.string)
        continue
    }
    orphanedToneVariants.append(row.string)
}

// MARK: - Emit

struct Index: Encodable {
    let unicodeVersion: String
    let cldrVersion: String
    let groups: [String]
    let emoji: [Row]
    let skinTones: [String: [String]]
}

let index = Index(
    unicodeVersion: unicodeVersion,
    cldrVersion: cldrVersion,
    groups: groups,
    emoji: rows,
    skinTones: skinToneTable
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
let json = try encoder.encode(index)

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let jsonURL = outputDirectory.appendingPathComponent("emoji-index.json")
try json.write(to: jsonURL, options: .atomic)

let license = """
Emoji data bundled with Codiclens

Emoji list, ordering and grouping
  Unicode® Emoji \(unicodeVersion), from emoji-test.txt (UTS #51).

Emoji names and search keywords
  Unicode Common Locale Data Repository (CLDR) \(cldrVersion),
  common/annotations/en.xml and common/annotationsDerived/en.xml.

Copyright © 1991-2025 Unicode, Inc.
Unicode and the Unicode Logo are registered trademarks of Unicode, Inc.
in the U.S. and other countries.

SPDX-License-Identifier: Unicode-3.0

UNICODE LICENSE V3

Permission is hereby granted, free of charge, to any person obtaining a copy
of data files and any associated documentation (the "Data Files") or software
and any associated documentation (the "Software") to deal in the Data Files
or Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, and/or sell copies of the Data
Files or Software, and to permit persons to whom the Data Files or Software
are furnished to do so, provided that either (a) this copyright and permission
notice appear with all copies of the Data Files or Software, or (b) this
copyright and permission notice appear in associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS
INCLUDED IN THIS NOTICE BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR
CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE,
DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE
OF THE DATA FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall not
be used in advertising or otherwise to promote the sale, use or other dealings
in these Data Files or Software without prior written authorization of the
copyright holder.

Full terms: https://www.unicode.org/license.txt
"""

let licenseURL = outputDirectory.appendingPathComponent("emoji-data-license.txt")
try Data(license.utf8).write(to: licenseURL, options: .atomic)

// MARK: - Report

let size = ByteCountFormatter.string(fromByteCount: Int64(json.count), countStyle: .file)
var report = """

  rows                  \(rows.count)
  groups                \(groups.count)
  skin-tone variants    \(tonedRows.count) across \(skinToneTable.count) bases
  rows missing keywords \(missingKeywords.count)
  rows missing name     \(missingNames.count)
  json                  \(jsonURL.path) (\(size))
  license               \(licenseURL.path)

"""
if !missingKeywords.isEmpty {
    report += "  MISSING KEYWORDS: \(missingKeywords.prefix(20).joined(separator: " "))\n"
}
if !orphanedToneVariants.isEmpty {
    report += "  ORPHANED VARIANTS: \(orphanedToneVariants.prefix(20).joined(separator: " "))\n"
}
FileHandle.standardError.write(Data(report.utf8))

if !missingKeywords.isEmpty || !orphanedToneVariants.isEmpty { exit(2) }
