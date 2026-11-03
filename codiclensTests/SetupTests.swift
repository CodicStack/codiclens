import Foundation
import Synchronization
import Testing
@testable import codiclens

/// Setup over fakes: macOS's shortcut table, the login item, the
/// Accessibility grant and the folder prompts are never touched, the meaning
/// model "downloads" from memory into a temporary folder, and what Setup and
/// the Sources keep lives in `ThrowawayDefaults`. A launch is a new `Setup`
/// over the same defaults. The folders it offers are made-up paths standing
/// in for Downloads, Documents and Desktop.
@MainActor
struct SetupTests {
    let defaults = ThrowawayDefaults()
    let hotKeys = FakeSymbolicHotKeys()
    let loginItem = FakeLoginItem()
    let accessibility = FakeAccessibility()
    let folderAccess = FakeFolderAccess()
    static let folders = ["/Users/test/Downloads", "/Users/test/Documents", "/Users/test/Desktop"]
    let models = Models()
    var isMeaningSupported = true

    /// Search by meaning's model folder, gone with the test.
    final class Models {
        let folder = try! TemporaryFolder()
        let downloader = StubDownloader()
        var requested: [String] { downloader.requested.withLock { $0 } }
        deinit { folder.remove() }
    }

    /// One launch's Setup, with the shortcut takeover it shares with
    /// Settings.
    private func launch(sources: SourceStore? = nil) -> (Setup, ShortcutTakeover, OpenAtLogin) {
        let takeover = ShortcutTakeover(hotKeys: hotKeys, defaults: defaults)
        let openAtLogin = OpenAtLogin(service: loginItem)
        let files = ModelFiles(folder: models.folder.url, files: StubDownloader.files, downloader: models.downloader)
        let meaning = MeaningSettings(files: files, choice: .defaults(defaults, files: files),
                                      isSupported: isMeaningSupported)
        let setup = Setup(
            shortcuts: ShortcutsRow(takeover: takeover),
            folders: FoldersRow(
                sources: sources ?? SourceStore(defaults: defaults),
                folders: Self.folders,
                isDenied: { [folderAccess] in folderAccess.denied.contains($0) }
            ),
            meaning: MeaningChoiceRow(meaning: meaning),
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
        #expect(setup.meaning.mode == .full, "text, images and audio preselected")
        #expect(setup.meaning.isAvailable)
        #expect(hotKeys.calls.isEmpty, "nothing is taken before Done")
        #expect(loginItem.requests.isEmpty)
        #expect(accessibility.prompts == 0)
        #expect(models.requested.isEmpty, "nothing downloads before Done")
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
    @Test func skippingAppliesNothingAndSetupReturnsOnReopenAndAtLaunch() async {
        let (setup, takeover, _) = launch()
        setup.begin()
        setup.shortcuts.takesSpotlight = false
        setup.login.opensAtLogin = false

        setup.meaning.mode = .text

        // The window closes without Done.
        #expect(setup.opensOnReopen)
        #expect(hotKeys.calls.isEmpty)
        #expect(loginItem.requests.isEmpty)
        #expect(models.requested.isEmpty)

        let (nextLaunch, nextTakeover, _) = launch()
        nextTakeover.takeAtLaunch()
        nextLaunch.begin()
        #expect(nextLaunch.showsAtLaunch)
        #expect(nextLaunch.opensOnReopen)
        #expect(nextLaunch.shortcuts.takesSpotlight)
        #expect(nextLaunch.login.opensAtLogin)
        #expect(nextLaunch.meaning.mode == .full)
        #expect(hotKeys.calls.isEmpty, "a launch before Done takes nothing")
        #expect(!takeover.isOn(.spotlight))
        await nextLaunch.meaning.meaning.startAndWait()
        #expect(models.requested.isEmpty, "a launch before Done downloads nothing")
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

    // MARK: - Search by meaning

    /// Done is what starts the download, of what was chosen and no more.
    @Test func doneDownloadsTheChosenMeaning() async {
        let (setup, _, _) = launch()
        setup.begin()
        setup.meaning.mode = .text
        #expect(models.requested.isEmpty)

        setup.done()
        await setup.meaning.meaning.startAndWait()

        #expect(models.requested == ["a.gguf"], "Text needs the text model alone")
        #expect(setup.meaning.meaning.mode == .text)
        let (nextLaunch, _, _) = launch()
        nextLaunch.begin()
        #expect(nextLaunch.meaning.mode == .text, "Show Setup… starts from the choice in force")
    }

    @Test func doneWithTheDefaultDownloadsEverything() async {
        let (setup, _, _) = launch()
        setup.begin()

        setup.done()
        await setup.meaning.meaning.startAndWait()

        #expect(models.requested == ["a.gguf", "b.gguf"])
        #expect(setup.meaning.meaning.status != .off)
    }

    @Test func choosingOffDownloadsNothing() async {
        let (setup, _, _) = launch()
        setup.begin()
        setup.meaning.mode = .off

        setup.done()
        await setup.meaning.meaning.startAndWait()

        #expect(models.requested.isEmpty)
        setup.begin()
        #expect(setup.meaning.mode == .off)
    }

    /// An install from before Setup with the model downloaded: Setup offers
    /// what it has, and its Done downloads nothing again.
    @Test func anInstallWithTheModelIsOfferedWhatItHas() async throws {
        for file in StubDownloader.files {
            try StubDownloader.contents[file.name]!.write(to: models.folder.url.appendingPathComponent(file.name))
        }
        let (setup, _, _) = launch()
        setup.begin()
        #expect(setup.meaning.mode == .full)

        setup.done()
        await setup.meaning.meaning.startAndWait()

        #expect(models.requested.isEmpty)
    }

    @Test func onIntelTheChoiceIsOffAndDoneDownloadsNothing() async {
        var tests = self
        tests.isMeaningSupported = false
        let (setup, _, _) = tests.launch()
        setup.begin()
        #expect(!setup.meaning.isAvailable)
        #expect(setup.meaning.mode == .off)

        setup.done()
        await setup.meaning.meaning.startAndWait()

        #expect(models.requested.isEmpty)
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

    // MARK: - Folders

    private var folderSources: [String] {
        SourceStore(defaults: defaults).folders.compactMap(\.folderPath)
    }

    @Test func aFreshInstallHasNoFolderSourcesBeforeAllow() {
        let (setup, _, _) = launch()
        setup.begin()

        #expect(!setup.folders.isAllowed)
        #expect(setup.folders.names == ["Downloads", "Documents", "Desktop"])
        #expect(folderSources.isEmpty)
    }

    /// Allow acts at once, like Grant, so macOS's three folder prompts arrive
    /// while the row is in front of the user: the File Index hears of the new
    /// Sources straight away and starts reading them.
    @Test func allowAddsTheThreeFolderSourcesAtOnce() {
        let sources = SourceStore(defaults: defaults)
        var changes = 0
        sources.onFoldersChange = { changes += 1 }
        let (setup, _, _) = launch(sources: sources)
        setup.begin()

        setup.folders.allow()

        #expect(setup.folders.isAllowed)
        #expect(changes == 1)
        #expect(folderSources == Self.folders, "before Done, and whether or not Done is pressed")
        #expect(sources.folders.allSatisfy { $0.isEnabled })
        #expect(setup.folders.deniedNames.isEmpty)
    }

    /// Skipping leaves no folder Sources, and the built-in ones work as ever.
    @Test func skippingFoldersLeavesNoFolderSourcesAndTheBuiltInsOn() {
        let (setup, _, _) = launch()
        setup.begin()

        setup.done()

        let sources = SourceStore(defaults: defaults)
        #expect(sources.folders.isEmpty)
        #expect(sources.isEnabled(.applications))
        #expect(sources.isEnabled(.clipboardHistory))
        #expect(sources.isEnabled(.emoji))
        let (nextLaunch, _, _) = launch()
        nextLaunch.begin()
        #expect(!nextLaunch.folders.isAllowed, "Show Setup… still offers Allow")
    }

    /// A folder macOS refused is named under the row, with the way to
    /// Privacy & Security; one that is not a Source is never asked about.
    @Test func aFolderMacOSDeniedIsNamedAfterAllow() {
        folderAccess.denied = [Self.folders[2]]
        let (setup, _, _) = launch()
        setup.begin()
        #expect(setup.folders.deniedNames.isEmpty, "nothing asked before Allow")

        setup.folders.allow()

        #expect(setup.folders.isAllowed)
        #expect(setup.folders.deniedNames == ["Desktop"])
        folderAccess.denied = []
        #expect(setup.folders.deniedNames.isEmpty, "allowed in System Settings")
    }

    /// An install from before Setup reads the three folders already: the
    /// row shows them allowed and Allow changes nothing.
    @Test func anInstallThatAlreadyReadsTheFoldersShowsThemAllowed() {
        let sources = SourceStore(defaults: defaults)
        sources.addFolders(Self.folders.map { URL(fileURLWithPath: $0) })
        var changes = 0
        sources.onFoldersChange = { changes += 1 }
        let (setup, _, _) = launch(sources: sources)
        setup.begin()

        #expect(setup.folders.isAllowed)
        setup.folders.allow()
        #expect(changes == 0)
    }

    /// One removed in Settings comes back with Allow; the others stay as
    /// they are, switched off ones included.
    @Test func allowAddsOnlyTheFoldersThatAreMissing() {
        let sources = SourceStore(defaults: defaults)
        sources.addFolders(Self.folders.map { URL(fileURLWithPath: $0) })
        sources.removeFolder(Self.folders[0])
        sources.setEnabled(false, for: "folder:" + Self.folders[1])
        let (setup, _, _) = launch(sources: sources)
        setup.begin()
        #expect(!setup.folders.isAllowed)

        setup.folders.allow()

        #expect(Set(folderSources) == Set(Self.folders))
        #expect(!sources.isEnabled(.folder(path: Self.folders[1])))
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

/// Which folders macOS refused. Nothing here asks macOS.
@MainActor
final class FakeFolderAccess {
    var denied: Set<String> = []
}

@MainActor
final class FakeAccessibility: AccessibilityAccess {
    var isGranted = false
    var prompts = 0

    func prompt() { prompts += 1 }
}
