import Foundation

/// One change to a file or folder on disk, asked for by an Action and performed
/// by `EffectRunner`: Move To, Copy To, Save To, Rename and Compress.
///
/// The coordinator builds one of these and returns it inside an Effect; it never
/// calls `perform()` itself. Moving a file is the same kind of thing as rotating
/// one: it mutates the world, so it crosses the seam and a test answers it with
/// a canned result. See `docs/adr/0007-async-action-behind-the-effect-seam.md`.
///
/// **Nothing here overwrites.** A Move or Copy into a folder that already holds
/// the name lands beside it as Finder's "Keep Both" does, as `name 2.ext`; so
/// do a zip and a saved Clipboard Item. A Rename onto a name that is taken is refused instead, because
/// the user typed that name and a different one would not be what they asked
/// for.
nonisolated enum FileOperation: Equatable, Sendable {
    case move(URL, into: URL)
    case copy(URL, into: URL)
    case rename(URL, to: String)
    /// Zip beside the original, named `<name>.zip` as Finder's Compress names it.
    case compress(URL)
    /// Save To…: a Clipboard Item written into a folder as a new file called
    /// `name`. The history keeps its own copy; nothing of it is moved or
    /// handed over.
    case save(Saved, into: URL, named: String)

    /// What Save To… writes.
    enum Saved: Equatable, Sendable {
        /// A Clipboard Image: its stored file, copied. The stored one stays.
        case copy(of: URL)
        /// A Clipboard text, as UTF-8.
        case text(String)
    }

    enum Failure: Error, Equatable, Sendable {
        /// Rename only: something else already has that name.
        case nameTaken
        /// Rename only: empty, `.`, `..`, or containing `/`.
        case invalidName
        case failed
    }

    /// Does it, and answers with where the result now is: the moved file, the
    /// copy, the renamed file, the zip, the saved file. Blocking; the runner
    /// calls it off the main thread.
    func perform() -> Result<URL, Failure> {
        switch self {
        case .move(let url, let folder):
            // Moving a file into the folder it is already in is Finder's
            // drag-to-the-same-window: nothing happens, and that is a success.
            // Paths, not URLs: a folder's URL may or may not end in a slash.
            if url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path {
                return .success(url)
            }
            return Self.place(url, in: folder) { try FileManager.default.moveItem(at: url, to: $0) }
        case .copy(let url, let folder):
            return Self.place(url, in: folder) { try FileManager.default.copyItem(at: url, to: $0) }
        case .rename(let url, let name):
            return Self.rename(url, to: name)
        case .compress(let url):
            return Self.compress(url)
        case .save(.copy(let stored), let folder, let name):
            return Self.place(named: name, keepsExtension: true, in: folder) {
                try FileManager.default.copyItem(at: stored, to: $0)
            }
        case .save(.text(let text), let folder, let name):
            // `.withoutOverwriting` is an exclusive create: a taken name fails
            // with "file exists", as a copy onto one does.
            return Self.place(named: name, keepsExtension: true, in: folder) {
                try Data(text.utf8).write(to: $0, options: .withoutOverwriting)
            }
        }
    }

    /// What the Subject Card says while it runs. It flashes for a quick one,
    /// knowingly, as "Reading text…" does: a threshold before showing it would
    /// be an `asyncAfter`.
    var progressNote: String {
        switch self {
        case .move: "Moving…"
        case .copy: "Copying…"
        case .rename: "Renaming…"
        case .compress: "Compressing…"
        case .save: "Saving…"
        }
    }

    /// What the Subject Card says when it did not happen. Short, because it sits
    /// in a corner chip.
    func failureNote(_ failure: Failure) -> String {
        switch failure {
        case .nameTaken: return "Name already taken"
        case .invalidName: return "Not a valid name"
        case .failed: break
        }
        return switch self {
        case .move: "Couldn't move"
        case .copy: "Couldn't copy"
        case .rename: "Couldn't rename"
        case .compress: "Couldn't compress"
        case .save: "Couldn't save"
        }
    }

    // MARK: - Names

    /// `name` if nothing is called that, otherwise Finder's next free number:
    /// `Report.pdf` → `Report 2.pdf` → `Report 3.pdf`. A name that already ends
    /// in a number counts on from it, so `Report 2.pdf` becomes `Report 3.pdf`
    /// rather than `Report 2 2.pdf`.
    ///
    /// - Parameter keepsExtension: false for a plain folder, whose dot is part
    ///   of its name: `v1.2` becomes `v1.2 2`, not `v1 2.2`.
    static func candidates(for name: String, keepsExtension: Bool) -> AnySequence<String> {
        let ext = keepsExtension ? (name as NSString).pathExtension : ""
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let suffix = ext.isEmpty ? "" : "." + ext

        var stem = base
        var first = 2
        if let space = base.lastIndex(of: " "),
           let number = Int(base[base.index(after: space)...]), number >= 1 {
            stem = String(base[..<space])
            first = number + 1
        }

        // The name itself, then numbered ones without end: `place` stops at
        // the first that does not exist.
        return AnySequence(sequence(state: Int?.none) { next -> String? in
            guard let number = next else {
                next = first
                return name
            }
            next = number + 1
            return "\(stem) \(number)\(suffix)"
        })
    }

    /// The part of a name Rename selects as it opens: everything before the
    /// extension, as Finder does, so typing replaces the name and keeps the
    /// type. A folder's whole name, and a dotfile's, since neither has one.
    static func baseNameRange(in name: String, isFolder: Bool) -> Range<String.Index> {
        guard !isFolder,
              let dot = name.lastIndex(of: "."),
              dot != name.startIndex else {
            return name.startIndex..<name.endIndex
        }
        return name.startIndex..<dot
    }

    // MARK: - Doing it

    /// Puts `url` into `folder` under the first free candidate name. Free is
    /// decided by the move or copy itself failing with "file exists", not by a
    /// look first, so a file that appears in between is never overwritten.
    private static func place(
        _ url: URL,
        in folder: URL,
        named name: String? = nil,
        _ put: (URL) throws -> Void
    ) -> Result<URL, Failure> {
        place(named: name ?? url.lastPathComponent, keepsExtension: !isPlainFolder(url), in: folder, put)
    }

    /// `place` for something that is not yet a file of its own: the name is
    /// all there is to number.
    private static func place(
        named name: String,
        keepsExtension: Bool,
        in folder: URL,
        _ put: (URL) throws -> Void
    ) -> Result<URL, Failure> {
        for candidate in candidates(for: name, keepsExtension: keepsExtension) {
            let destination = folder.appendingPathComponent(candidate)
            do {
                try put(destination)
                return .success(destination)
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                return .failure(.failed)
            }
        }
        return .failure(.failed)
    }

    private static func rename(_ url: URL, to name: String) -> Result<URL, Failure> {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            return .failure(.invalidName)
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            // Refuses an existing destination by itself. A change of case alone
            // on a case-insensitive volume is the same file, and goes through.
            try FileManager.default.moveItem(at: url, to: destination)
            return .success(destination)
        } catch CocoaError.fileWriteFileExists {
            return .failure(.nameTaken)
        } catch {
            return .failure(.failed)
        }
    }

    /// `ditto` writes into a scratch folder on the same volume, and only the
    /// finished zip is moved in beside the original. `ditto` itself would
    /// overwrite an existing zip, and a half-written one would sit there under
    /// the real name while it ran.
    private static func compress(_ url: URL) -> Result<URL, Failure> {
        let fileManager = FileManager.default
        let folder = url.deletingLastPathComponent()
        let zipName = url.lastPathComponent + ".zip"
        guard let scratch = try? fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: folder,
            create: true
        ) else { return .failure(.failed) }
        defer { try? fileManager.removeItem(at: scratch) }

        let zip = scratch.appendingPathComponent(zipName)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", url.path, zip.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        do {
            try ditto.run()
        } catch {
            return .failure(.failed)
        }
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { return .failure(.failed) }

        return place(zip, in: folder, named: zipName) { try fileManager.moveItem(at: zip, to: $0) }
    }

    /// A folder whose dot is part of its name. A package — `.app`, `.rtfd` —
    /// has an extension like a file.
    private static func isPlainFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }
}
