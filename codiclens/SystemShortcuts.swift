import AppKit

/// A keystroke macOS holds out of the box that Codiclens wants: ⌘Space
/// (Spotlight) and ⌃⌘Space (Emoji & Symbols). See
/// `docs/adr/0016-codiclens-takes-both-system-shortcuts.md`.
enum SystemShortcut: CaseIterable, Hashable {
    case spotlight
    case emoji

    /// macOS's id for it in the symbolic hotkey table.
    var symbolicHotKey: Int32 {
        switch self {
        case .spotlight: 64
        case .emoji: 50
        }
    }

    /// The choice's words, in Setup and in Settings → General. No em
    /// dashes: the user's copy.
    var choiceTitle: String {
        switch self {
        case .spotlight: "Use ⌘Space for Codiclens (replaces Spotlight)"
        case .emoji: "Open emoji with ⌃⌘Space (replaces Emoji & Symbols)"
        }
    }

    /// Where the user's choice is kept. Absent until Setup's Done or a
    /// Settings toggle: a fresh install takes nothing.
    var defaultsKey: String {
        switch self {
        case .spotlight: "codiclens.shortcuts.spotlight"
        case .emoji: "codiclens.shortcuts.emoji"
        }
    }
}

/// macOS's symbolic hotkey table, by macOS's ids. A fake in tests: nothing
/// under test ever changes the Mac's shortcuts.
protocol SymbolicHotKeys {
    /// Whether this macOS has the calls at all.
    var isAvailable: Bool { get }
    /// Whether macOS holds hotkey `id` right now: on in Keyboard Shortcuts
    /// and not let go this session. False when it cannot be read.
    func doesMacOSHold(_ id: Int32) -> Bool
    /// Lets macOS hold hotkey `id` again (`true`) or makes it let go
    /// (`false`). False when the call failed or macOS did not do it.
    func setMacOSHolds(_ id: Int32, _ holds: Bool) -> Bool
}

extension SymbolicHotKeys {
    func setMacOSHolds(_ shortcut: SystemShortcut, _ holds: Bool) -> Bool {
        setMacOSHolds(shortcut.symbolicHotKey, holds)
    }
}

/// The private CoreGraphics calls Raycast uses too, resolved at run time so a
/// macOS without them degrades to the fallback instead of failing to launch.
/// The change lasts for the login session only, which is why it is made
/// again at every launch (ADR 0016).
struct PrivateSymbolicHotKeys: SymbolicHotKeys {
    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32
    private typealias IsEnabled = @convention(c) (Int32) -> Bool

    private let setEnabled: SetEnabled?
    private let isEnabled: IsEnabled?

    init() {
        // RTLD_DEFAULT: every image the process has loaded. AppKit brings in
        // CoreGraphics, which re-exports these from SkyLight.
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2)
        setEnabled = dlsym(everywhere, "CGSSetSymbolicHotKeyEnabled").map {
            unsafeBitCast($0, to: SetEnabled.self)
        }
        isEnabled = dlsym(everywhere, "CGSIsSymbolicHotKeyEnabled").map {
            unsafeBitCast($0, to: IsEnabled.self)
        }
    }

    var isAvailable: Bool { setEnabled != nil }

    func doesMacOSHold(_ id: Int32) -> Bool {
        isEnabled?(id) ?? false
    }

    func setMacOSHolds(_ id: Int32, _ holds: Bool) -> Bool {
        guard let setEnabled else { return false }
        let error = setEnabled(id, holds)
        guard error == 0 else {
            NSLog("[codiclens] CGSSetSymbolicHotKeyEnabled(%d, %d) failed: %d", id, holds ? 1 : 0, error)
            return false
        }
        // Assert, never assume: read it back where macOS lets us.
        guard let isEnabled else { return true }
        return isEnabled(id) == holds
    }
}

/// Codiclens's hold on ⌘Space and ⌃⌘Space, shared by Setup and Settings.
///
/// What is kept is the user's choice; whether macOS let go is `hasFailed`.
/// Each launch takes the ones that are on (`takeAtLaunch`) and termination
/// hands them back (`handBack`) without changing the choice, so quitting or
/// trashing the app gives the user Spotlight and Emoji & Symbols back.
@Observable
final class ShortcutTakeover {
    @ObservationIgnored private let hotKeys: SymbolicHotKeys
    @ObservationIgnored private let defaults: UserDefaults
    private var on: Set<SystemShortcut>
    private var failed: Set<SystemShortcut> = []

    init(hotKeys: SymbolicHotKeys, defaults: UserDefaults) {
        self.hotKeys = hotKeys
        self.defaults = defaults
        on = Set(SystemShortcut.allCases.filter { defaults.object(forKey: $0.defaultsKey) as? Bool == true })
    }

    var isAvailable: Bool { hotKeys.isAvailable }

    /// Whether the user chose to give it to Codiclens. Off until chosen.
    func isOn(_ shortcut: SystemShortcut) -> Bool { on.contains(shortcut) }

    /// Whether macOS refused the last time it was taken.
    func hasFailed(_ shortcut: SystemShortcut) -> Bool { failed.contains(shortcut) }

    /// The choice, kept and put into effect now: taken, or handed back.
    func setOn(_ isOn: Bool, for shortcut: SystemShortcut) {
        defaults.set(isOn, forKey: shortcut.defaultsKey)
        if isOn {
            on.insert(shortcut)
            take(shortcut)
        } else {
            on.remove(shortcut)
            failed.remove(shortcut)
            _ = hotKeys.setMacOSHolds(shortcut, true)
        }
    }

    /// At every launch: an OS update, a restart or another app may have
    /// given macOS the shortcut back.
    func takeAtLaunch() {
        for shortcut in SystemShortcut.allCases where on.contains(shortcut) {
            take(shortcut)
        }
    }

    /// In `applicationWillTerminate`: macOS gets back what was taken. The
    /// choice stays, for the next launch.
    func handBack() {
        for shortcut in SystemShortcut.allCases where on.contains(shortcut) {
            _ = hotKeys.setMacOSHolds(shortcut, true)
        }
    }

    private func take(_ shortcut: SystemShortcut) {
        if hotKeys.setMacOSHolds(shortcut, false) {
            failed.remove(shortcut)
        } else {
            failed.insert(shortcut)
        }
    }
}

/// ⌃← and ⌃→, lent to Codiclens while the Panel is up.
///
/// In the Panel they step between Cards as ⌃H and ⌃L do, but macOS holds
/// them for "Move left a space" and "Move right a space" (symbolic hotkeys
/// 79 and 81), and WindowServer eats a held keystroke before the Panel sees
/// it. So the Panel borrows the ones macOS holds as it shows and hands them
/// back as it hides; one the user turned off is never touched, so it is
/// never turned on either.
///
/// Unlike `ShortcutTakeover` this is no choice of the user's. The change
/// lasts the login session, so what is borrowed is written down before it
/// is taken: after a crash with the Panel up, the next launch hands it back.
final class SpacesArrowLoan {
    /// Move left a space (⌃←) and move right a space (⌃→).
    static let ids: Set<Int32> = [79, 81]
    static let defaultsKey = "codiclens.spacesArrows.borrowed"

    private let hotKeys: SymbolicHotKeys
    private let defaults: UserDefaults
    /// What macOS has let go of for Codiclens and not been given back yet.
    private(set) var borrowed: Set<Int32>

    /// Starts from what a previous run recorded and never handed back, for
    /// `handBack` to return at launch.
    init(hotKeys: SymbolicHotKeys, defaults: UserDefaults) {
        self.hotKeys = hotKeys
        self.defaults = defaults
        let recorded = defaults.object(forKey: Self.defaultsKey) as? [Int] ?? []
        borrowed = Set(recorded.map { Int32(truncatingIfNeeded: $0) }).intersection(Self.ids)
    }

    /// As the Panel shows. Borrowing again while borrowed takes nothing new:
    /// what is borrowed no longer reads as macOS's.
    func borrow() {
        let wanted = Self.ids.subtracting(borrowed).filter { hotKeys.doesMacOSHold($0) }
        guard !wanted.isEmpty else { return }
        // Written down first, so a crash between the two leaves nothing
        // unrecorded.
        record(borrowed.union(wanted))
        for id in wanted where hotKeys.setMacOSHolds(id, false) {
            borrowed.insert(id)
        }
        record(borrowed)
    }

    /// As the Panel hides, by any path, at quit and at launch. With nothing
    /// borrowed it does nothing. One macOS refuses stays borrowed, for the
    /// next hide or launch to try again.
    func handBack() {
        guard !borrowed.isEmpty else { return }
        for id in borrowed where hotKeys.setMacOSHolds(id, true) {
            borrowed.remove(id)
        }
        record(borrowed)
    }

    private func record(_ ids: Set<Int32>) {
        if ids.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(ids.sorted().map(Int.init), forKey: Self.defaultsKey)
        }
    }
}
