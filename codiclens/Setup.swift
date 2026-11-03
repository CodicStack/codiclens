import Foundation

/// Setup (`GLOSSARY.md`): the small window a fresh install opens with.
///
/// Its rows, in the order the window shows them: Shortcuts, Folders,
/// Meaning, Paste, Open at login. Every row is optional and Done always
/// closes the window. A row holds the user's choice while the window is up
/// (`begin`) and puts it into effect on Done (`done`), so closing the window
/// is a skip that changes nothing; search by meaning's download starts on
/// Done and never before. Folders' Allow and Paste's Grant are the
/// exceptions: they act at once, because macOS asks the question.
///
/// Setup shows at launch and on every reopen until Done has been pressed
/// once, then only from "Show Setup…" in Settings → General. It never nags
/// from the Panel.
@Observable
final class Setup {
    let shortcuts: ShortcutsRow
    let folders: FoldersRow
    let meaning: MeaningChoiceRow
    let paste: PasteRow
    let login: LoginRow
    private(set) var isFinished: Bool

    @ObservationIgnored private let defaults: UserDefaults
    static let finishedKey = "codiclens.setup.finished"

    init(shortcuts: ShortcutsRow, folders: FoldersRow, meaning: MeaningChoiceRow, paste: PasteRow, login: LoginRow, defaults: UserDefaults) {
        self.shortcuts = shortcuts
        self.folders = folders
        self.meaning = meaning
        self.paste = paste
        self.login = login
        self.defaults = defaults
        isFinished = defaults.object(forKey: Self.finishedKey) as? Bool ?? false
    }

    /// Every row, in the window's order. A new row goes in here and in
    /// `SetupView`.
    private var rows: [any SetupRow] { [shortcuts, folders, meaning, paste, login] }

    /// Whether the launch opens Setup.
    var showsAtLaunch: Bool { !isFinished }

    /// Whether reopening the running app opens Setup beside the Panel.
    var opensOnReopen: Bool { !isFinished }

    /// The window is opening: each row shows its default the first time,
    /// and what is in force once Done has been pressed.
    func begin() {
        for row in rows { row.begin(firstRun: !isFinished) }
    }

    /// Done: each row's choice is put into effect, and Setup stops coming
    /// back on its own.
    func done() {
        for row in rows { row.done() }
        isFinished = true
        defaults.set(true, forKey: Self.finishedKey)
    }
}

/// One of Setup's rows.
protocol SetupRow: AnyObject {
    /// The window is opening. `firstRun` until Done has been pressed once:
    /// the row shows its default rather than what is in force.
    func begin(firstRun: Bool)
    /// Done: the row's choice into effect. Nothing for a row that acts on
    /// its own button.
    func done()
}

/// "Use ⌘Space for Codiclens" and "Open emoji with ⌃⌘Space", both ticked
/// the first time (ADR 0016).
@Observable
final class ShortcutsRow: SetupRow {
    let takeover: ShortcutTakeover
    var takesSpotlight = true
    var takesEmoji = true

    init(takeover: ShortcutTakeover) {
        self.takeover = takeover
    }

    /// The ⌘Space row is instructions and a link to Keyboard Shortcuts: this
    /// macOS has no private call, or refused it.
    var showsSpotlightFallback: Bool {
        !takeover.isAvailable || takeover.hasFailed(.spotlight)
    }

    /// Emoji & Symbols has no Settings row to point at (ADR 0006), so without
    /// the call there is nothing to offer.
    var canTakeEmoji: Bool { takeover.isAvailable }

    /// macOS refused ⌃⌘Space.
    var emojiFailed: Bool { takeover.hasFailed(.emoji) }

    func begin(firstRun: Bool) {
        takesSpotlight = firstRun || takeover.isOn(.spotlight)
        takesEmoji = firstRun || takeover.isOn(.emoji)
    }

    func done() {
        guard takeover.isAvailable else { return }
        apply(takesSpotlight, to: .spotlight)
        apply(takesEmoji, to: .emoji)
    }

    private func apply(_ chosen: Bool, to shortcut: SystemShortcut) {
        guard chosen != takeover.isOn(shortcut) else { return }
        takeover.setOn(chosen, for: shortcut)
    }
}

/// "Search your files": Downloads, Documents and Desktop, and Allow. Allow
/// acts at once, like Paste's Grant: the folders become Sources, the File
/// Index starts reading them, and macOS asks about each one while the row is
/// in front of the user. Until then the File Index reads no folder. A skip
/// leaves no folder Sources; apps, Clipboard History and Emoji work anyway.
@Observable
final class FoldersRow: SetupRow {
    /// The folders offered, by path.
    let folders: [String]
    @ObservationIgnored private let sources: SourceStore
    @ObservationIgnored private let isDenied: (String) -> Bool

    /// - Parameter isDenied: whether macOS refused a folder Source. Only
    ///   asked about folders that are Sources, which the File Index has
    ///   already asked macOS about.
    init(sources: SourceStore, folders: [String] = SourceStore.defaultFolders, isDenied: @escaping (String) -> Bool) {
        self.sources = sources
        // As `SourceStore.addFolder` writes them, to be found among them.
        self.folders = folders.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
        self.isDenied = isDenied
    }

    /// The folders by the names Finder shows.
    var names: [String] { folders.map(FileManager.default.displayName(atPath:)) }

    /// Every one of the folders is a Source: Allow was pressed, or the
    /// install read them before Setup asked.
    var isAllowed: Bool { folders.allSatisfy(isSource) }

    /// The folders that are Sources but macOS refused, by name.
    var deniedNames: [String] {
        folders.filter { isSource($0) && isDenied($0) }.map(FileManager.default.displayName(atPath:))
    }

    /// Adds the folders that are not Sources yet, as one change.
    func allow() {
        sources.addFolders(folders.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    func begin(firstRun: Bool) {}
    func done() {}

    private func isSource(_ path: String) -> Bool {
        sources.folders.contains { $0.folderPath == path }
    }
}

/// "Search by meaning": Off, Text (310 MB), or Text, images and audio
/// (865 MB), preselected the first time unless the user already chose. Done
/// starts the download of what was chosen (`MeaningSettings`).
@Observable
final class MeaningChoiceRow: SetupRow {
    let meaning: MeaningSettings
    var mode = MeaningMode.full

    init(meaning: MeaningSettings) {
        self.meaning = meaning
    }

    /// False on a Mac without Apple silicon: the choice shows off, disabled.
    var isAvailable: Bool { meaning.isSupported }

    func begin(firstRun: Bool) {
        mode = firstRun ? meaning.suggested : meaning.mode
    }

    func done() {
        meaning.setMode(mode)
    }
}

/// "Paste into apps": Grant opens macOS's Accessibility prompt, and the tick
/// follows the grant (`refresh`, which the window calls while it is open).
/// A skipped Grant leaves the first Paste to ask, as it always has.
@Observable
final class PasteRow: SetupRow {
    @ObservationIgnored private let access: AccessibilityAccess
    private(set) var isGranted: Bool

    init(access: AccessibilityAccess) {
        self.access = access
        isGranted = access.isGranted
    }

    func grant() {
        access.prompt()
        refresh()
    }

    func refresh() {
        let granted = access.isGranted
        if granted != isGranted { isGranted = granted }
    }

    func begin(firstRun: Bool) { refresh() }
    func done() {}
}

/// "Open at login", ticked the first time.
@Observable
final class LoginRow: SetupRow {
    let openAtLogin: OpenAtLogin
    var opensAtLogin = true

    init(openAtLogin: OpenAtLogin) {
        self.openAtLogin = openAtLogin
    }

    func begin(firstRun: Bool) {
        openAtLogin.refresh()
        opensAtLogin = firstRun || openAtLogin.isOn
    }

    func done() {
        guard opensAtLogin != openAtLogin.isOn else { return }
        openAtLogin.setOn(opensAtLogin)
    }
}
