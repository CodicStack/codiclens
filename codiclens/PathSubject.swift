import AppKit
import UniformTypeIdentifiers

/// A file or folder named by typing its path — and the one place a URL on disk
/// is turned into a Subject.
///
/// A Query beginning `/` or `~` is a path and nothing else. Those two prefixes
/// cannot begin an app name, which is exactly why they were chosen: a Path
/// Subject never competes with the app Index, so none of the Index's gates —
/// `isIndexReady`, `canReportNoResults` — move for it. See
/// `docs/adr/0008-a-file-can-be-a-subject.md`.
///
/// This is deliberately one function's worth of work: `String` → `URL` →
/// `UTType` → `Subject`. There is no completion list, no directory read and no
/// new Mode. `~/Downloads` resolves to a `.folder` Subject that Enter opens in
/// Finder; it does not list what is inside it, because "list its contents" is
/// the rejected completion list under another name.
enum PathSubject {

    /// Whether a Query is a path at all.
    ///
    /// `/` and `~` only. `.` and `..` are deliberately **not** paths: a leading
    /// dot is an ordinary character in an app name, and a Query starting with
    /// one has to stay an app search.
    static func isPath(_ query: String) -> Bool {
        query.hasPrefix("/") || query.hasPrefix("~")
    }

    /// The single Subject a path Query names, or `nil` when nothing is there.
    ///
    /// Exactly one Result or none. A path that does not resolve is a no-match
    /// like any other, and the Panel shakes about it through the same
    /// `SubjectSearchVM.hasNoMatch` every other no-match goes through.
    static func resolve(_ query: String) -> Subject? {
        guard isPath(query) else { return nil }
        let expanded = (query as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        return subject(for: URL(fileURLWithPath: expanded))
    }

    /// A Subject for a file, folder or app bundle that exists on disk, or `nil`
    /// when nothing is at that URL.
    ///
    /// Shared with "Use as Subject", so a promoted Target and a typed path
    /// produce the same Subject for the same URL. One rule for what a thing on
    /// disk *is*, rather than two that can drift apart.
    static func subject(for url: URL) -> Subject? {
        let resolved = url.standardizedFileURL

        // Reading these is also the existence check: `resourceValues` throws
        // for a URL that isn't there, which is the whole of "a path that does
        // not exist produces no Result".
        guard let values = try? resolved.resourceValues(
            forKeys: [.contentTypeKey, .isDirectoryKey]
        ), let isDirectory = values.isDirectory else { return nil }

        let contentType = values.contentType
        let isAppBundle = contentType?.conforms(to: .applicationBundle) ?? false

        // An app bundle is a directory, so it has to be asked about first —
        // otherwise every app on disk resolves to a folder and gets a folder's
        // Actions.
        let kind: SubjectKind
        if isAppBundle {
            kind = .app(
                bundleIdentifier: Bundle(url: resolved)?.bundleIdentifier,
                isRunning: false
            )
        } else if isDirectory {
            kind = .folder
        } else {
            // `.data` is the honest fallback for a file the system has no type
            // for: it conforms to nothing interesting, so no Action that gates
            // on a content type turns on.
            kind = .file(contentType: contentType ?? .data)
        }

        // An app is named the way the Index names one — without the `.app` —
        // so a promoted app bundle and a searched one read identically.
        let name = isAppBundle
            ? resolved.deletingPathExtension().lastPathComponent
            : resolved.lastPathComponent

        // The icon is the file's generic one, drawn at once; a file's
        // thumbnail replaces it when Quick Look has one. A folder and an app
        // are their icons and get no thumbnail.
        let icon = NSWorkspace.shared.icon(forFile: resolved.path)
        icon.size = NSSize(width: 32, height: 32)
        let isFile = if case .file = kind { true } else { false }

        return Subject(
            displayName: name,
            path: resolved.path,
            url: resolved,
            icon: icon,
            kind: kind,
            thumbnailURL: isFile ? resolved : nil
        )
    }
}
