import AppKit

/// The one alert a copy launched outside /Applications shows before Setup:
/// straight off the DMG, translocated by Gatekeeper, or from Downloads. Its
/// button copies the app into /Applications, relaunches the copy and trashes
/// the original (or ejects the DMG it came on). Sparkle cannot update a copy
/// that is translocated or on a read-only disk image, so this is not cosmetic.
///
/// Never offered in a Debug build: Xcode runs those from DerivedData.
enum MoveToApplications {
    enum Plan: Equatable {
        case stay
        /// Copy `copy` to `to`, then trash `trash` and eject `eject` where
        /// there is one.
        case move(copy: URL, to: URL, trash: URL?, eject: URL?)
    }

    /// What to do, from where the app runs (`running`), where it was before
    /// Gatekeeper translocated it (`original`, nil when it was not), and the
    /// mounted disk image it is on (`diskImageVolume`).
    static func plan(
        running: URL,
        original: URL?,
        diskImageVolume: URL?,
        applications: URL = URL(filePath: "/Applications", directoryHint: .isDirectory)
    ) -> Plan {
        let source = original ?? running
        let inside = applications.standardizedFileURL.pathComponents
        let components = source.standardizedFileURL.pathComponents
        if components.count > inside.count, Array(components.prefix(inside.count)) == inside {
            return .stay
        }
        return .move(
            copy: running,
            to: applications.appending(path: running.lastPathComponent, directoryHint: .isDirectory),
            trash: diskImageVolume == nil ? source : nil,
            eject: diskImageVolume
        )
    }

    /// At launch, before anything starts. True when the app is moving and
    /// about to quit, so the launch goes no further.
    static func offerIfNeeded() -> Bool {
        #if DEBUG
        return false
        #else
        let running = Bundle.main.bundleURL
        let original = Translocation.originalURL(of: running)
        let plan = plan(running: running, original: original, diskImageVolume: diskImageVolume(of: original ?? running))
        guard case .move(let copy, let destination, let trash, let eject) = plan else { return false }
        // The installed copy is already running: it is the one to use, and
        // reopening it opens its Panel.
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL
        }) {
            NSWorkspace.shared.openApplication(at: destination, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return true
        }
        guard ask(fromDiskImage: eject != nil) else { return false }
        do {
            try move(copy: copy, to: destination, trash: trash)
        } catch {
            NSLog("[codiclens] move to Applications failed: %@", "\(error)")
            showFailure()
            return false
        }
        relaunch(destination, ejecting: eject)
        NSApp.terminate(nil)
        return true
        #endif
    }

    // MARK: - The alert

    private static func ask(fromDiskImage: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Codiclens to Applications?"
        alert.informativeText = fromDiskImage
            ? "Codiclens is running from the disk image. It will copy itself to your Applications folder and open from there, so it can keep itself up to date."
            : "Codiclens will move itself to your Applications folder and open from there, so it can keep itself up to date."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func showFailure() {
        let alert = NSAlert()
        alert.messageText = "Codiclens couldn't move itself"
        alert.informativeText = "Drag Codiclens into the Applications folder in Finder, then open it from there."
        alert.runModal()
    }

    // MARK: - Doing it

    private static func move(copy source: URL, to destination: URL, trash: URL?) throws {
        let files = FileManager.default
        if files.fileExists(atPath: destination.path(percentEncoded: false)) {
            try files.trashItem(at: destination, resultingItemURL: nil)
        }
        try files.copyItem(at: source, to: destination)
        // A copy keeps the quarantine flag, and a quarantined app that Finder
        // did not move is translocated again at its next launch.
        removeQuarantine(from: destination)
        if let trash {
            do {
                try files.trashItem(at: trash, resultingItemURL: nil)
            } catch {
                NSLog("[codiclens] couldn't trash the original at %@: %@", trash.path(percentEncoded: false), "\(error)")
            }
        }
    }

    private static func removeQuarantine(from url: URL) {
        let xattr = Process()
        xattr.executableURL = URL(filePath: "/usr/bin/xattr")
        xattr.arguments = ["-d", "-r", "com.apple.quarantine", url.path(percentEncoded: false)]
        try? xattr.run()
        xattr.waitUntilExit()
    }

    /// The copy opens once this process has gone, so two copies never run
    /// side by side over one File Index; a DMG is ejected in between, once
    /// nothing runs from it. The shell polls for the exit because nothing
    /// else outlives this process to be told.
    private static func relaunch(_ app: URL, ejecting volume: URL?) {
        let pid = ProcessInfo.processInfo.processIdentifier
        var script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; "
        if volume != nil { script += "/usr/bin/hdiutil detach \"$2\" -quiet; " }
        script += "/usr/bin/open \"$1\""
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-c", script, "sh", app.path(percentEncoded: false), volume?.path(percentEncoded: false) ?? ""]
        try? shell.run()
    }

    /// The volume `url` is on when that is a mounted, read-only image (a DMG),
    /// nil otherwise.
    private static func diskImageVolume(of url: URL) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeURLKey, .volumeIsRootFileSystemKey]),
              values.volumeIsReadOnly == true,
              values.volumeIsRootFileSystem != true else { return nil }
        return values.volume
    }
}

/// Gatekeeper's App Translocation: a quarantined app opened from where it
/// was downloaded runs from a random read-only mirror. Security.framework
/// says where the real copy is, through calls it does not declare in a
/// header, so they are looked up at run time.
private enum Translocation {
    private typealias IsTranslocated = @convention(c) (
        CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Bool
    private typealias OriginalPath = @convention(c) (
        CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Unmanaged<CFURL>?

    static func originalURL(of url: URL) -> URL? {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isSymbol = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let originalSymbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let isTranslocated = unsafeBitCast(isSymbol, to: IsTranslocated.self)
        let originalPath = unsafeBitCast(originalSymbol, to: OriginalPath.self)
        var translocated = false
        guard isTranslocated(url as CFURL, &translocated, nil), translocated,
              let original = originalPath(url as CFURL, nil)?.takeRetainedValue() else { return nil }
        return original as URL
    }
}
