import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// FTS5's `snippet()` marks — U+0001 before a matched word, U+0002 after it —
/// turned into places in the excerpt (`FileIndexReader.passage(snippet:page:)`),
/// the one conversion there is, and those places drawn as underlines by the
/// three things that show a Passage: the row's subtitle, Finder's Target
/// subtitle and the Subject Card.
@MainActor
struct PassageMarksTests {

    /// The words `matches` mark in `excerpt`, by characters.
    private func marked(_ passage: FileHit.Passage) -> [String] {
        let characters = Array(passage.excerpt)
        return passage.matches.map { String(characters[$0]) }
    }

    /// The underlined stretches of `text`. Neighbouring underlines read as one.
    /// AppKit's key, the one `underlined` sets, named: in a file that imports
    /// SwiftUI, `.underlineStyle` is SwiftUI's, and reads nil.
    private func underlinedWords(_ text: AttributedString) -> [String] {
        text.runs.compactMap { run in
            run[AttributeScopes.AppKitAttributes.UnderlineStyleAttribute.self] == nil
                ? nil : String(text[run.range].characters)
        }
    }

    // MARK: - Marks to ranges

    @Test func oneMark() {
        let passage = FileIndexReader.passage(snippet: "…the \u{1}invoice\u{2} number…", page: nil)
        #expect(passage.excerpt == "…the invoice number…")
        #expect(passage.matches == [5..<12])
        #expect(marked(passage) == ["invoice"])
    }

    @Test func severalMarks() {
        let passage = FileIndexReader.passage(
            snippet: "…Please pay the \u{1}invoice\u{2} number \u{1}42\u{2} by Friday…", page: nil)
        #expect(passage.excerpt == "…Please pay the invoice number 42 by Friday…")
        #expect(passage.matches == [16..<23, 31..<33])
        #expect(marked(passage) == ["invoice", "42"])
    }

    @Test func marksAfterALeadingEllipsis() {
        let passage = FileIndexReader.passage(snippet: "…\u{1}invoice\u{2} number \u{1}42\u{2}…", page: nil)
        #expect(passage.excerpt == "…invoice number 42…")
        #expect(passage.matches == [1..<8, 16..<18])
        #expect(marked(passage) == ["invoice", "42"])

        let uncut = FileIndexReader.passage(snippet: "\u{1}Invoice\u{2} due", page: nil)
        #expect(uncut.matches == [0..<7])
        #expect(marked(uncut) == ["Invoice"])
    }

    @Test func adjacentMarks() {
        let touching = FileIndexReader.passage(snippet: "\u{1}in\u{2}\u{1}voice\u{2} 42", page: nil)
        #expect(touching.excerpt == "invoice 42")
        #expect(touching.matches == [0..<2, 2..<7])
        #expect(marked(touching) == ["in", "voice"])

        let spaced = FileIndexReader.passage(snippet: "…\u{1}invoice\u{2} \u{1}42\u{2}…", page: nil)
        #expect(spaced.matches == [1..<8, 9..<11])
        #expect(marked(spaced) == ["invoice", "42"])
    }

    @Test func nonASCIIBeforeAMark() {
        let passage = FileIndexReader.passage(
            snippet: "…Husk æøå 🇩🇰 👨‍👩‍👧 é \u{1}huslejen\u{2} og nr. \u{1}42\u{2}…", page: nil)
        #expect(passage.excerpt == "…Husk æøå 🇩🇰 👨‍👩‍👧 é huslejen og nr. 42…")
        #expect(marked(passage) == ["huslejen", "42"])
        #expect(underlinedWords(underlined(passage.excerpt, marks: passage.matches)) == ["huslejen", "42"])
    }

    @Test func whitespaceIsFoldedBeforeAMarkIsCounted() {
        let passage = FileIndexReader.passage(snippet: "\n  …pay\n\n the\t\u{1}invoice\u{2}  \r\n\u{1}42\u{2} ", page: nil)
        #expect(passage.excerpt == "…pay the invoice 42")
        #expect(marked(passage) == ["invoice", "42"])
    }

    @Test func emptyExcerpt() {
        let empty = FileIndexReader.passage(snippet: "", page: nil)
        #expect(empty.excerpt.isEmpty)
        #expect(empty.matches.isEmpty)
        #expect(underlinedWords(underlined("", marks: empty.matches)).isEmpty)

        let emptyMark = FileIndexReader.passage(snippet: "a \u{1}\u{2}b", page: nil)
        #expect(emptyMark.excerpt == "a b")
        #expect(emptyMark.matches.isEmpty, "a mark around nothing marks nothing")
    }

    @Test func aMarkOutsideTheTextIsDropped() {
        #expect(underlinedWords(underlined("abc", marks: [2..<5, -1..<1])).isEmpty)
    }

    // MARK: - Where the marks are drawn

    private let snippet = "…Please pay the \u{1}invoice\u{2} number \u{1}42\u{2} by Friday…"

    @Test func theSubtitleCarriesTheMarksPastItsPlace() {
        let plain = FileIndexReader.passage(snippet: snippet, page: nil)
        #expect(plain.subtitleMatches == plain.matches)

        let page = FileIndexReader.passage(snippet: "…æøå 🇩🇰 \u{1}invoice\u{2} number \u{1}42\u{2}…", page: 4)
        #expect(page.subtitle == "page 4 · …æøå 🇩🇰 invoice number 42…")
        #expect(underlinedWords(underlined(page.subtitle, marks: page.subtitleMatches)) == ["invoice", "42"])
    }

    @Test func theRowAndFindersTargetUnderlineTheMatchedWords() {
        let passage = FileIndexReader.passage(snippet: snippet, page: 2)
        let hit = FileHit(url: URL(fileURLWithPath: "/x/rent notes.txt"), name: "rent notes.txt", folder: "~/x",
                          kind: .file, score: FileHit.contentScore, passage: passage)
        let row = ResultDisplayItem(file: hit, icon: NSImage())
        #expect(underlinedWords(row.attributedSubtitle(query: "invoice 42")) == ["invoice", "42"])

        let target = ActionTarget(name: hit.name, icon: NSImage(), subtitle: passage.subtitle,
                                  subtitleMarks: passage.subtitleMatches, url: hit.url, sharingService: nil)
        let targetRow = ResultDisplayItem(from: target)
        #expect(underlinedWords(targetRow.attributedSubtitle(query: "invoice 42")) == ["invoice", "42"])
    }

    @Test func theCardUnderlinesTheMatchedWords() throws {
        let url = URL(fileURLWithPath: "/x/rent notes.txt")
        for page in [nil, 3] as [Int?] {
            let passage = SubjectPassage(FileIndexReader.passage(snippet: snippet, page: page))
            #expect(underlinedWords(passage.markedExcerpt) == ["invoice", "42"])

            let subject = Subject(displayName: url.lastPathComponent, path: url.path, url: url, icon: NSImage(),
                                  kind: .file(contentType: .plainText), thumbnailURL: url, passage: passage)
            let card = try #require(CardPassage(subject))
            #expect(underlinedWords(card.line) == ["invoice", "42"])
        }
    }
}
