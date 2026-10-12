import CoreGraphics
import Foundation
import IOKit.ps

/// How hard the meaning backfill works, decided afresh before every batch
/// (`MeaningScheduler`), as Spotlight and Photos pace theirs: flat out only
/// while the Mac is on power and nobody is using it.
///
/// Nothing polls: the batch loop asks as each batch starts, so a change of
/// power or of the user's presence takes effect at the next batch. Low Power
/// Mode and the Panel are told to the scheduler as they change.
nonisolated enum MeaningPace: Equatable, Sendable {
    /// Low Power Mode: no backfill. Files that change are still embedded,
    /// gently.
    case paused
    /// Eight files a batch at background priority, App Nap allowed: on
    /// battery, while the user is at the Mac, and while the Panel is open,
    /// so the query encoder has the GPU to itself as far as it can.
    case gentle
    /// On power, no input for `idleAfter`, the Panel closed: `fullBatchSize`
    /// files a batch at utility priority, App Nap off in the app and the
    /// helper (`EmbeddingRequest.fullSpeed`). Never keeps the Mac or its
    /// display awake.
    case full

    /// How long without a key, a click or a mouse movement before the user
    /// counts as away.
    static let idleAfter: TimeInterval = 120
    /// A batch's texts go to the helper together, so a full batch of
    /// one-chunk files is one call of 32: 47 vectors a second against 22 one
    /// at a time. Past that the model is the limit, not the batch
    /// (`MeaningThroughputTests`; see AGENTS.md).
    static let fullBatchSize = 32
    static let gentleBatchSize = 8

    /// What the pace is decided from besides Low Power Mode and the Panel.
    struct Machine: Sendable {
        /// On AC power, a desktop Mac included.
        var isOnPower: @Sendable () -> Bool
        /// Since the last input event of any kind, in this login session.
        var idleSeconds: @Sendable () -> TimeInterval

        static let system = Machine(
            isOnPower: {
                guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                      let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
                else { return false }
                return source as String == kIOPMACPowerKey
            },
            idleSeconds: {
                // `kCGAnyInputEventType`, which Swift cannot spell.
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            }
        )
    }

    /// The pace for the next batch. `machine` is only asked when the answer
    /// is not already settled by Low Power Mode or the Panel.
    init(isLowPower: Bool, isPanelOpen: Bool, machine: Machine) {
        if isLowPower {
            self = .paused
        } else if isPanelOpen || !machine.isOnPower() {
            self = .gentle
        } else {
            self = machine.idleSeconds() >= Self.idleAfter ? .full : .gentle
        }
    }

    /// Files a batch: light ones, that is; a PDF, a recording or a video
    /// still goes alone (`MeaningScheduler.batch`).
    var batchSize: Int {
        self == .full ? Self.fullBatchSize : Self.gentleBatchSize
    }
}
