// The changelog-to-notes step of Scripts/release.sh (docs/RELEASING.md).
//
//   swift Scripts/release-notes.swift --check --changelog CHANGELOG.md --version X.Y.Z
//   swift Scripts/release-notes.swift --changelog CHANGELOG.md --version X.Y.Z --date YYYY-MM-DD --out DIR [--renderer CMD]
//
// --check refuses a changelog the release can't be cut from: no "## Unreleased", nothing under it, a section for this
// version already there, or notes that break the style rules (no subheadings, ticket numbers or em dashes).
//
// Without --check it writes three files into DIR and touches nothing else:
// - CHANGELOG.md: "## Unreleased" renamed to "## X.Y.Z (YYYY-MM-DD)", with a fresh empty "## Unreleased" above it.
// - release-notes.md: that section's markdown, the GitHub release body.
// - Codiclens-X.Y.Z.html: the appcast item's embedded notes. The newest 5 versions, newest first, each a
//   <section data-sparkle-version="X.Y.Z"> headed "X.Y.Z · D Mon YYYY". Sparkle marks the section whose version is
//   the installed CFBundleVersion (which the release script sets to X.Y.Z), and the CSS hides it and everything older.
//
// Each section's markdown goes through CMD on stdin and its HTML comes back on stdout. The default CMD renders through
// GitHub's markdown API; the fixture test (Scripts/tests/release-notes.sh) passes a local stand-in.
import Foundation

let sectionsInAppcast = 5
let defaultRenderer = "gh api markdown -f mode=markdown -F text=@-"

struct Failure: Error { let message: String }

/// A "## …" section of the changelog: its heading line and the lines under it, up to the next "## " heading.
struct Section {
  var heading: String
  var lines: [String]

  /// The markdown under the heading, without leading or trailing blank lines.
  var body: String {
    var lines = lines
    while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
    return lines.joined(separator: "\n")
  }

  var isUnreleased: Bool { heading.trimmingCharacters(in: .whitespaces) == "## Unreleased" }

  /// "## 1.2.0 (2026-11-14)" → ("1.2.0", "2026-11-14").
  var release: (version: String, date: String)? {
    let pattern = #"^## (\d+\.\d+\.\d+) \((\d{4}-\d{2}-\d{2})\)\s*$"#
    guard let match = heading.range(of: pattern, options: .regularExpression) else { return nil }
    let parts = heading[match].dropFirst(3).split(separator: " ")
    return (String(parts[0]), String(parts[1].dropFirst().prefix(10)))
  }
}

/// The changelog as the text before the first "## " heading and its sections, in order.
struct Changelog {
  var preamble: [String]
  var sections: [Section]

  init(_ text: String) {
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    preamble = []
    sections = []
    for line in lines {
      if line.hasPrefix("## ") {
        sections.append(Section(heading: line, lines: []))
      } else if sections.isEmpty {
        preamble.append(line)
      } else {
        sections[sections.count - 1].lines.append(line)
      }
    }
  }

  var text: String {
    (preamble + sections.flatMap { [$0.heading] + $0.lines }).joined(separator: "\n") + "\n"
  }

  /// The Unreleased section, or why the release can't be cut from this changelog.
  func unreleased(for version: String) throws -> Section {
    guard let section = sections.first(where: \.isUnreleased) else {
      throw Failure(message: "CHANGELOG.md has no ## Unreleased heading. Add one above the newest version.")
    }
    if section.body.isEmpty {
      throw Failure(message: "CHANGELOG.md has nothing under ## Unreleased. Write this release's notes there first.")
    }
    if sections.contains(where: { $0.release?.version == version }) {
      throw Failure(message: "CHANGELOG.md already has a \(version) section.")
    }
    for line in section.lines {
      if line.hasPrefix("#") {
        throw Failure(message: "## Unreleased has a subheading (\(line)). Notes are a few plain sentences, no subheads.")
      }
      if line.contains("\u{2014}") {
        throw Failure(message: "## Unreleased has an em dash: \(line)")
      }
      if line.range(of: #"(^|[\s(])#\d+"#, options: .regularExpression) != nil {
        throw Failure(message: "## Unreleased mentions a ticket number: \(line)")
      }
    }
    return section
  }

  /// Unreleased renamed to this release, with a fresh empty Unreleased above it.
  func releasing(_ version: String, on date: String) throws -> Changelog {
    _ = try unreleased(for: version)
    var next = self
    let index = sections.firstIndex(where: \.isUnreleased)!
    next.sections[index].heading = "## \(version) (\(date))"
    next.sections.insert(Section(heading: "## Unreleased", lines: [""]), at: index)
    return next
  }
}

/// "2026-12-07" → "7 Dec 2026".
func displayDate(_ isoDate: String) throws -> String {
  let parse = DateFormatter()
  parse.locale = Locale(identifier: "en_US_POSIX")
  parse.timeZone = TimeZone(identifier: "UTC")
  parse.dateFormat = "yyyy-MM-dd"
  guard let date = parse.date(from: isoDate) else { throw Failure(message: "Not a date: \(isoDate)") }
  let show = DateFormatter()
  show.locale = Locale(identifier: "en_US_POSIX")
  show.timeZone = TimeZone(identifier: "UTC")
  show.dateFormat = "d MMM yyyy"
  return show.string(from: date)
}

func render(_ markdown: String, with renderer: String) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = ["-c", renderer]
  let input = Pipe(), output = Pipe()
  process.standardInput = input
  process.standardOutput = output
  try process.run()
  input.fileHandleForWriting.write(Data((markdown + "\n").utf8))
  try input.fileHandleForWriting.close()
  let html = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw Failure(message: "Rendering the notes failed (\(renderer) exited \(process.terminationStatus)).")
  }
  return String(decoding: html, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func appcastNotes(_ changelog: Changelog, renderer: String) throws -> String {
  var html = """
    <style>
      .sparkle-installed-version, .sparkle-installed-version ~ section { display: none; }
    </style>

    """
  for section in changelog.sections.filter({ $0.release != nil }).prefix(sectionsInAppcast) {
    let (version, date) = section.release!
    html += """
      <section data-sparkle-version="\(version)">
      <h2>\(version) · \(try displayDate(date))</h2>
      \(try render(section.body, with: renderer))
      </section>

      """
  }
  return html
}

func main() throws {
  var options: [String: String] = [:]
  var check = false
  var arguments = CommandLine.arguments.dropFirst()
  while let argument = arguments.popFirst() {
    if argument == "--check" { check = true; continue }
    guard argument.hasPrefix("--"), let value = arguments.popFirst() else {
      throw Failure(message: "Usage: see the top of Scripts/release-notes.swift (at \(argument))")
    }
    options[String(argument.dropFirst(2))] = value
  }
  func option(_ name: String) throws -> String {
    guard let value = options[name] else { throw Failure(message: "Missing --\(name)") }
    return value
  }
  let changelogPath = try option("changelog")
  let version = try option("version")
  guard let text = try? String(contentsOfFile: changelogPath, encoding: .utf8) else {
    throw Failure(message: "Can't read \(changelogPath).")
  }
  let changelog = Changelog(text)
  if check {
    _ = try changelog.unreleased(for: version)
    return
  }
  let date = try option("date")
  _ = try displayDate(date)
  let out = URL(fileURLWithPath: try option("out"))
  let released = try changelog.releasing(version, on: date)
  let body = released.sections.first { $0.release?.version == version }!.body
  let html = try appcastNotes(released, renderer: options["renderer"] ?? defaultRenderer)
  try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
  try released.text.write(to: out.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
  try (body + "\n").write(to: out.appendingPathComponent("release-notes.md"), atomically: true, encoding: .utf8)
  try html.write(to: out.appendingPathComponent("Codiclens-\(version).html"), atomically: true, encoding: .utf8)
  print("Notes for \(version) written to \(out.path)")
}

do {
  try main()
} catch let failure as Failure {
  FileHandle.standardError.write(Data("error: \(failure.message)\n".utf8))
  exit(1)
}
