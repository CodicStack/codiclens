import Foundation
import Testing
@testable import codiclens

/// Setup over fakes: macOS's shortcut table, the login item and the
/// Accessibility grant are never touched, and what Setup keeps lives in
/// `ThrowawayDefaults`. A launch is a new `Setup` over the same defaults.
@MainActor
struct SetupTests {
    let defaults = ThrowawayDefaults()
    let hotKeys = FakeSymbolicHotKeys()
    let loginItem = FakeLoginItem()
    let accessibility = FakeAccessibility()

    /// One launch's Setup, with the shortcut takeover it shares with
    /// Settings.
    private func launch() -> (Setup, ShortcutTakeover, OpenAtLogin) {
        let takeover = ShortcutTakeover(hotKeys: hotKeys, defaults: defaults)
        let openAtLogin = OpenAtLogin(service: loginItem)
        let setup = Setup(
            shortcuts: ShortcutsRow(takeover: takeover),
            paste: PasteRow(access: accessibility),
            login: LoginRow(openAtLogin: openAtLogin),
            defaults: defaults
        )
        return (setup, takeover, openAtLogin)
    }

    @Test func aFreshInstallShowsSetupWithEveryRowTickedAndAppliesNothingYet() {
        let (setup, takeover, _) = launch()

        takeover.takeAtLaunch()
        setup.begin()

        #expect(setup.showsAtLaunch)
        #expect(setup.shortcuts.takesSpotlight)
        #expect(setup.shortcuts.takesEmoji)
        #expect(setup.login.opensAtLogin)
        #expect(hotKeys.calls.isEmpty, "nothing is taken before Done")
        #expect(loginItem.requests.isEmpty)
        #expect(accessibility.prompts == 0)
    }

    @Test func doneAppliesTheTickedRowsAndSetupIsFinished() {
        let (setup, _, _) = launch()
        setup.begin()

        setup.done()

        #expect(hotKeys.macOSHolds.isEmpty, "both shortcuts are Codiclens's")
        #expect(loginItem.isEnabled)
        #expect(!setup.showsAtLaunch)
        #expect(!setup.opensOnReopen)
        let (nextLaunch, _, _) = launch()
        #expect(!nextLaunch.showsAtLaunch)
        #expect(!nextLaunch.opensOnReopen)
    }

    @Test func doneAppliesExactlyTheChosenRows() {
        let (setup, takeover, _) = launch()
        setup.begin()
        setup.shortcuts.takesEmoji = false
        setup.login.opensAtLogin = false

        setup.done()

        #expect(hotKeys.macOSHolds == [.emoji])
        #expect(hotKeys.calls.map(\.shortcut) == [.spotlight])
        #expect(takeover.isOn(.spotlight))
        #expect(!takeover.isOn(.emoji))
        #expect(loginItem.requests.isEmpty, "off was already the state in force")
        #expect(!loginItem.isEnabled)
    }

    /// Closing the window is a skip: nothing applied, and Setup is back at
    /// the next reopen and the next launch, ticked as it was the first time.
    @Test func skippingAppliesNothingAndSetupReturnsOnReopenAndAtLaunch() {
        let (setup, takeover, _) = launch()
        setup.begin()
        setup.shortcuts.takesSpotlight = false
        setup.login.opensAtLogin = false

        // The window closes without Done.
        #expect(setup.opensOnReopen)
        #expect(hotKeys.calls.isEmpty)
        #expect(loginItem.requests.isEmpty)

        let (nextLaunch, nextTakeover, _) = launch()
        nextTakeover.takeAtLaunch()
        nextLaunch.begin()
        #expect(nextLaunch.showsAtLaunch)
        #expect(nextLaunch.opensOnReopen)
        #expect(nextLaunch.shortcuts.takesSpotlight)
        #expect(nextLaunch.login.opensAtLogin)
        #expect(hotKeys.calls.isEmpty, "a launch before Done takes nothing")
        #expect(!takeover.isOn(.spotlight))
    }

    /// Show Setup… after Done shows what is in force, not the first run's
    /// ticks, and Done there changes only what was changed.
    @Test func showingSetupAgainAfterDoneStartsFromWhatIsInForce() {
        let (setup, _, openAtLogin) = launch()
        setup.begin()
        setup.shortcuts.takesEmoji = false
        setup.done()
        loginItem.isEnabled = false // turned off in System Settings meanwhile
        openAtLogin.refresh()

        setup.begin()

        #expect(setup.shortcuts.takesSpotlight)
        #expect(!setup.shortcuts.takesEmoji)
        #expect(!setup.login.opensAtLogin)
        hotKeys.calls.removeAll()
        setup.done()
        #expect(hotKeys.calls.isEmpty)
        #expect(!loginItem.isEnabled)
    }

    // MARK: - Shortcuts at launch and quit

    @Test func eachLaunchTakesTheShortcutsThatAreOnAndQuitHandsThemBack() {
        let (setup, _, _) = launch()
        setup.begin()
        setup.shortcuts.takesEmoji = false
        setup.done()
        // A restart, or macOS taking it back: macOS holds both again.
        hotKeys.macOSHolds = [.spotlight, .emoji]

        let (_, takeover, _) = launch()
        takeover.takeAtLaunch()
        #expect(hotKeys.macOSHolds == [.emoji])

        takeover.handBack()
        #expect(hotKeys.macOSHolds == [.spotlight, .emoji])
        #expect(takeover.isOn(.spotlight), "quitting is not turning it off")
    }

    @Test func aSettingsToggleTakesOrHandsBackAtOnce() {
        let (setup, takeover, _) = launch()
        setup.begin()
        setup.done()

        takeover.setOn(false, for: .spotlight)
        #expect(hotKeys.macOSHolds == [.spotlight])
        takeover.setOn(true, for: .spotlight)
        #expect(hotKeys.macOSHolds.isEmpty)
    }

    // MARK: - When macOS refuses

    @Test func aFailedShortcutCallYieldsTheFallback() {
        hotKeys.refuses = [.spotlight]
        let (setup, takeover, _) = launch()
        setup.begin()
        #expect(!setup.shortcuts.showsSpotlightFallback, "nothing has failed yet")

        setup.done()

        #expect(takeover.hasFailed(.spotlight))
        #expect(!takeover.hasFailed(.emoji))
        setup.begin()
        #expect(setup.shortcuts.showsSpotlightFallback)
        #expect(hotKeys.macOSHolds == [.spotlight])

        // macOS lets go on a later try: the fallback goes.
        hotKeys.refuses = []
        takeover.takeAtLaunch()
        #expect(!takeover.hasFailed(.spotlight))
    }

    /// A macOS without the private calls shows the instructions from the
    /// start, before anything has been tried.
    @Test func withoutThePrivateCallsTheSpotlightRowIsTheFallback() {
        hotKeys.isAvailable = false
        let (setup, _, _) = launch()
        setup.begin()

        #expect(setup.shortcuts.showsSpotlightFallback)
        #expect(!setup.shortcuts.canTakeEmoji)
    }

    // MARK: - Paste

    @Test func grantAsksMacOSAndTicksOnceGranted() {
        let (setup, _, _) = launch()
        setup.begin()
        #expect(!setup.paste.isGranted)

        setup.paste.grant()
        #expect(accessibility.prompts == 1)
        #expect(!setup.paste.isGranted, "not until the user allows it")

        accessibility.isGranted = true
        setup.paste.refresh()
        #expect(setup.paste.isGranted)
    }

    @Test func pasteIsNotPartOfDone() {
        let (setup, _, _) = launch()
        setup.begin()

        setup.done()

        #expect(accessibility.prompts == 0, "a skipped Grant leaves the first Paste to ask")
    }

    // MARK: - Open at login

    @Test func openAtLoginMatchesTheLoginItemAndItsToggleChangesIt() {
        let (_, _, openAtLogin) = launch()
        #expect(!openAtLogin.isOn)

        openAtLogin.setOn(true)
        #expect(loginItem.isEnabled)
        #expect(openAtLogin.isOn)

        loginItem.isEnabled = false
        openAtLogin.refresh()
        #expect(!openAtLogin.isOn)
    }

    @Test func aLoginItemThatRefusesShowsWhatIsInForce() {
        loginItem.refuses = true
        let (setup, _, openAtLogin) = launch()
        setup.begin()

        setup.done()

        #expect(!openAtLogin.isOn)
        #expect(!setup.showsAtLaunch, "Done still closes Setup")
    }
}

// MARK: - Fakes

/// macOS's symbolic hotkey table, in memory. Both shortcuts start held by
/// macOS, as on a fresh Mac.
@MainActor
final class FakeSymbolicHotKeys: SymbolicHotKeys {
    var isAvailable = true
    /// Shortcuts whose call fails.
    var refuses: Set<SystemShortcut> = []
    var macOSHolds: Set<SystemShortcut> = [.spotlight, .emoji]
    var calls: [(shortcut: SystemShortcut, macOSHolds: Bool)] = []

    func setMacOSHolds(_ shortcut: SystemShortcut, _ holds: Bool) -> Bool {
        calls.append((shortcut, holds))
        guard isAvailable, !refuses.contains(shortcut) else { return false }
        if holds { macOSHolds.insert(shortcut) } else { macOSHolds.remove(shortcut) }
        return true
    }
}

@MainActor
final class FakeLoginItem: LoginItemService {
    var isEnabled = false
    var refuses = false
    var requests: [Bool] = []

    func setEnabled(_ enabled: Bool) throws {
        requests.append(enabled)
        guard !refuses else { throw CocoaError(.featureUnsupported) }
        isEnabled = enabled
    }
}

@MainActor
final class FakeAccessibility: AccessibilityAccess {
    var isGranted = false
    var prompts = 0

    func prompt() { prompts += 1 }
}
