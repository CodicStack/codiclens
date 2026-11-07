import Testing
@testable import codiclens

/// ⌃← and ⌃→ (symbolic hotkeys 79 and 81) borrowed from macOS while the Panel
/// is up, as `PanelController` calls it: `borrow` as it shows, `handBack` as
/// it hides by any path. Over `FakeSymbolicHotKeys` and `ThrowawayDefaults`,
/// so the Mac's Spaces shortcuts are never touched. A launch is a new loan
/// over the same defaults.
@MainActor
struct SpacesArrowLoanTests {
    let defaults = ThrowawayDefaults()
    let hotKeys = FakeSymbolicHotKeys()
    static let left: Int32 = 79
    static let right: Int32 = 81

    init() {
        hotKeys.held.formUnion([Self.left, Self.right])
    }

    private func launch() -> SpacesArrowLoan {
        SpacesArrowLoan(hotKeys: hotKeys, defaults: defaults)
    }

    private var recorded: [Int]? {
        defaults.object(forKey: SpacesArrowLoan.defaultsKey) as? [Int]
    }

    @Test func showingBorrowsBothAndHidingHandsThemBack() {
        let loan = launch()

        loan.borrow()
        #expect(!hotKeys.held.contains(Self.left))
        #expect(!hotKeys.held.contains(Self.right))
        #expect(loan.borrowed == [Self.left, Self.right])
        #expect(recorded == [79, 81], "written down while borrowed")

        loan.handBack()
        #expect(hotKeys.held.isSuperset(of: [Self.left, Self.right]))
        #expect(loan.borrowed.isEmpty)
        #expect(recorded == nil)
    }

    @Test func onlyWhatMacOSHoldsIsBorrowedAndOnlyThatIsHandedBack() {
        // The user turned off Move right a space.
        hotKeys.held.remove(Self.right)
        let loan = launch()

        loan.borrow()
        loan.handBack()

        #expect(hotKeys.calls.map(\.id) == [Self.left, Self.left])
        #expect(hotKeys.held.contains(Self.left))
        #expect(!hotKeys.held.contains(Self.right), "never turned on")
    }

    @Test func theSystemShortcutsAreNeverTouched() {
        let loan = launch()

        loan.borrow()
        loan.handBack()

        #expect(Set(hotKeys.calls.map(\.id)).isSubset(of: [Self.left, Self.right]))
        #expect(hotKeys.macOSHolds == [.spotlight, .emoji])
    }

    /// The save panel's Cancel shows the Panel again without a hide, and
    /// `tearDown` hides after a hide.
    @Test func aSecondShowOrHideDoesNothing() {
        let loan = launch()

        loan.handBack()
        #expect(hotKeys.calls.isEmpty, "nothing borrowed")

        loan.borrow()
        loan.borrow()
        #expect(hotKeys.calls.count == 2)
        #expect(loan.borrowed == [Self.left, Self.right])

        loan.handBack()
        loan.handBack()
        #expect(hotKeys.calls.count == 4)
        #expect(hotKeys.held.isSuperset(of: [Self.left, Self.right]))
    }

    @Test func withBothTurnedOffNothingIsBorrowedOrRecorded() {
        hotKeys.held.subtract([Self.left, Self.right])
        let loan = launch()

        loan.borrow()
        loan.handBack()

        #expect(hotKeys.calls.isEmpty)
        #expect(recorded == nil)
        #expect(!hotKeys.held.contains(Self.left))
        #expect(!hotKeys.held.contains(Self.right))
    }

    @Test func withoutThePrivateCallsNothingIsBorrowed() {
        hotKeys.isAvailable = false
        let loan = launch()

        loan.borrow()

        #expect(loan.borrowed.isEmpty)
        #expect(recorded == nil)
    }

    /// A crash with the Panel up: the next launch hands back what was
    /// recorded, and nothing else.
    @Test func aLaunchHandsBackWhatACrashLeftBorrowed() {
        launch().borrow()
        #expect(recorded == [79, 81])
        hotKeys.calls.removeAll()

        let next = launch()
        next.handBack()

        #expect(hotKeys.held.isSuperset(of: [Self.left, Self.right]))
        #expect(hotKeys.calls.map(\.macOSHolds) == [true, true])
        #expect(recorded == nil)
    }

    @Test func aLaunchHandsBackOnlyTheRecordedOne() {
        hotKeys.held.remove(Self.right)
        launch().borrow()
        #expect(recorded == [79])

        launch().handBack()

        #expect(hotKeys.held.contains(Self.left))
        #expect(!hotKeys.held.contains(Self.right), "the user turned it off")
    }

    @Test func aLaunchWithNothingRecordedTouchesNothing() {
        launch().handBack()

        #expect(hotKeys.calls.isEmpty)
    }

    /// Only ⌃← and ⌃→ are ever handed back, whatever the defaults say.
    @Test func aRecordOfAnotherHotKeyIsIgnored() {
        defaults.set([64, 79], forKey: SpacesArrowLoan.defaultsKey)
        hotKeys.held.remove(Self.left)

        launch().handBack()

        #expect(hotKeys.calls.map(\.id) == [Self.left])
    }

    @Test func oneMacOSRefusesToTakeIsNotRecorded() {
        hotKeys.refuses = [Self.right]
        let loan = launch()

        loan.borrow()

        #expect(loan.borrowed == [Self.left])
        #expect(recorded == [79])
    }

    /// One macOS will not take back stays borrowed and recorded, for the
    /// next hide or launch to try again.
    @Test func oneMacOSRefusesToTakeBackIsTriedAgain() {
        let loan = launch()
        loan.borrow()
        hotKeys.refuses = [Self.right]

        loan.handBack()
        #expect(loan.borrowed == [Self.right])
        #expect(recorded == [81])

        hotKeys.refuses = []
        loan.handBack()
        #expect(loan.borrowed.isEmpty)
        #expect(hotKeys.held.contains(Self.right))
        #expect(recorded == nil)
    }
}
