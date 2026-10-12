import Testing
@testable import codiclens

/// The app is the test host, and launching it started the File Index over the
/// user's real Downloads, Documents and Desktop, into their real database,
/// while the tests ran. It knows it is the host now, and starts nothing.
@MainActor
struct TestHostTests {

    @Test func theTestHostKnowsItIsOne() {
        #expect(AppDelegate.isTestHost)
    }

    /// The launch has finished before any test runs, so whatever it was
    /// going to start, it has.
    @Test func theTestHostDoesNotStartTheFileIndex() {
        #expect(!FileIndex.shared.isStarted)
    }
}
