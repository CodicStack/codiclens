import Foundation

/// Search by meaning's switch on the Sources page, and what it says about
/// itself. On unless the user turns it off: a fresh install downloads the
/// model at launch without being asked. On is: download the model files
/// (`ModelFiles`, with their progress), then give the File Index its vectors
/// (`MeaningScheduler`), then ready. Off stops the embedding and gives back
/// the vectors' memory, and keeps what is on disk for the next time; "Remove"
/// deletes the model files and the vectors too. Unavailable, and nothing ever
/// downloads, on a Mac without Apple silicon (`MeaningSearch.isSupported`).
@Observable
final class MeaningSettings {
    /// The one line under the switch.
    enum Status: Equatable {
        case unavailable
        case off
        case downloading(progress: Double)
        case verifying
        case failed(String)
        /// Giving files their vectors.
        case reading(MeaningCounts)
        /// Waiting for Low Power Mode to end.
        case paused(MeaningCounts)
        case ready(MeaningCounts)

        /// What the Sources page says. No em dashes: this is the user's copy.
        var text: String {
            switch self {
            case .unavailable: "Needs a Mac with Apple silicon"
            case .off: "Finds files by what they say, show or sound like, in any language. Downloads an 865 MB model."
            case .downloading(let progress): "Downloading the model, \(Int((progress * 100).rounded(.down)))%"
            case .verifying: "Checking the download"
            case .failed(let reason): "The download failed: \(reason)"
            case .reading(let counts): "Reading \(counts.embedded.formatted()) of \(counts.files.formatted()) files"
            case .paused(let counts):
                "Paused in Low Power Mode, \(counts.embedded.formatted()) of \(counts.files.formatted()) files read"
            case .ready(let counts): "Ready, \(counts.files.formatted()) files read"
            }
        }

        /// Work is going on that the Loading Ring may sit beside.
        var isWorking: Bool {
            switch self {
            case .downloading, .verifying, .reading: true
            case .unavailable, .off, .failed, .paused, .ready: false
            }
        }
    }

    /// Where the switch is kept, so the app's is in `UserDefaults` and a
    /// test's in memory. Nothing kept is on: only the user's own "off" is
    /// written down as off.
    struct Switch {
        var isOn: Bool
        var save: (Bool) -> Void

        static var off: Switch { Switch(isOn: false, save: { _ in }) }

        static func defaults(_ defaults: UserDefaults) -> Switch {
            Switch(isOn: defaults.object(forKey: key) as? Bool ?? true, save: { defaults.set($0, forKey: key) })
        }

        static let key = "codiclens.meaning.enabled"
    }

    /// What the File Index reports, read when the status is.
    struct Progress: Equatable {
        var counts = MeaningCounts()
        var isLowPower = false
    }

    let isSupported: Bool
    let files: ModelFiles
    private(set) var isEnabled: Bool

    @ObservationIgnored private let save: (Bool) -> Void
    /// Turns the meaning pass on or off in the File Index.
    @ObservationIgnored var apply: (Bool) -> Void = { _ in }
    /// Deletes the vectors from the File Index.
    @ObservationIgnored var removeVectors: () -> Void = {}
    /// Read from a view's `body`, so tracked like any `@Observable` read.
    @ObservationIgnored var progress: () -> Progress = { Progress() }
    /// Whether the File Index's pass is on: set once the files are there.
    private(set) var isApplied = false

    init(files: ModelFiles, switch store: Switch, isSupported: Bool = MeaningSearch.isSupported) {
        self.files = files
        self.isSupported = isSupported
        isEnabled = isSupported && store.isOn
        save = store.save
    }

    var status: Status {
        guard isSupported else { return .unavailable }
        guard isEnabled else { return .off }
        switch files.state {
        case .notDownloaded: return .downloading(progress: 0)
        case .downloading(let progress): return .downloading(progress: progress)
        case .verifying: return .verifying
        case .failed(let reason): return .failed(reason)
        case .ready: break
        }
        let progress = progress()
        guard isApplied, progress.counts.embedded >= progress.counts.files else {
            return progress.isLowPower ? .paused(progress.counts) : .reading(progress.counts)
        }
        return .ready(progress.counts)
    }

    /// The switch. On downloads what is missing, then starts the pass; off
    /// stops both.
    func setEnabled(_ isEnabled: Bool) {
        guard isSupported, isEnabled != self.isEnabled else { return }
        self.isEnabled = isEnabled
        save(isEnabled)
        if isEnabled {
            start()
        } else {
            files.cancel()
            if isApplied {
                isApplied = false
                apply(false)
            }
        }
    }

    /// At launch, and after the switch goes on: the model files, then the
    /// pass. Returns once that has settled, for tests; the app does not wait.
    func start() {
        guard isSupported, isEnabled else { return }
        Task { await startAndWait() }
    }

    func startAndWait() async {
        guard isSupported, isEnabled else { return }
        await files.download()
        guard isEnabled, files.isReady, !isApplied else { return }
        isApplied = true
        apply(true)
    }

    /// Off, the model files deleted and the vectors with them. Turning it on
    /// again downloads the model again and reads every file again.
    func remove() {
        setEnabled(false)
        files.remove()
        removeVectors()
    }
}
