import Foundation

/// The query encoder, held for as long as the Panel is up: loaded as it
/// shows, so the first settled search of a session does not wait for the
/// model, and let go as it hides, by whichever path it hides.
///
/// The Panel hides more than one way, and one path can follow another
/// (`tearDown` after a hide), so a hide with nothing held and a show while
/// held do nothing: `hold` and `release` alternate. Whether search by meaning
/// is on, and so whether either does anything, is the File Index's to judge
/// (`FileIndex.holdQueryEncoder`).
final class QueryEncoderHold {
    private let hold: () -> Void
    private let release: () -> Void
    private(set) var isHeld = false

    /// - Parameters:
    ///   - hold, release: the File Index's in the app (`fileIndex`); a test
    ///     counts them.
    init(hold: @escaping () -> Void, release: @escaping () -> Void) {
        self.hold = hold
        self.release = release
    }

    /// The File Index's query encoder.
    static var fileIndex: QueryEncoderHold {
        QueryEncoderHold(
            hold: { FileIndex.shared.holdQueryEncoder() },
            release: { FileIndex.shared.releaseQueryEncoder() }
        )
    }

    func panelShown() {
        guard !isHeld else { return }
        isHeld = true
        hold()
    }

    func panelHidden() {
        guard isHeld else { return }
        isHeld = false
        release()
    }
}
