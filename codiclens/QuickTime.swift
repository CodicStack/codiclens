import Foundation

/// Opening a recording or a video in QuickTime Player at a moment, and playing
/// it from there: what Enter does on a File Result that matched at a time.
///
/// AppleScript, because nothing else reaches into another app's player, and
/// `osascript` rather than `NSAppleScript`, which is main-thread only: the
/// first run waits on macOS asking the user whether Codiclens may control
/// QuickTime (`NSAppleEventsUsageDescription`), and a launch takes a second
/// or two, neither of which may hold up the main thread. The child is
/// attributed to Codiclens, so the question and the switch in Privacy &
/// Security name Codiclens.
nonisolated enum QuickTime {
    /// Takes the file and the moment as arguments, so no path is ever
    /// spliced into the script. Milliseconds as a whole number, because
    /// `as real` reads "842.5" by the user's locale, and Danish wants a comma.
    static let script = """
        on run argv
            set theFile to POSIX file (item 1 of argv)
            set theSeconds to ((item 2 of argv) as integer) / 1000
            tell application "QuickTime Player"
                activate
                open theFile
                set current time of document 1 to theSeconds
                play document 1
            end tell
        end run
        """

    /// Whether QuickTime opened `url` and is playing it from `seconds`. False
    /// when the user said no, QuickTime could not open it, or `osascript`
    /// would not run. Blocks until it is done: call it off the main thread.
    static func open(_ url: URL, at seconds: Double) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, url.path, String(Int((seconds * 1000).rounded()))]
        // Never pipes: see `GitIgnored` — a pipe end inherited by another
        // child holds off its end.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
