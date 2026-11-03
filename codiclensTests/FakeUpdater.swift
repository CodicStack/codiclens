import Foundation
import Observation
@testable import codiclens

/// The updater without Sparkle: a test sends the events Sparkle would and
/// reads back what the app would see. Events go through the same
/// `UpdateState.applying(_:)` the Sparkle-backed updater uses; requests are
/// recorded, never carried out.
@MainActor
@Observable
final class FakeUpdater: Updater {
    private(set) var state: UpdateState = .none
    var version = "1.0.0"
    var lastCheck: Date?
    var checksAutomatically = true
    var downloadsAutomatically = false
    var canCheck = true

    /// What was asked of the updater, in order.
    private(set) var requests: [UpdateRequest] = []

    func send(_ event: UpdateEvent) {
        state = state.applying(event)
    }

    func request(_ request: UpdateRequest) {
        requests.append(request)
    }
}
