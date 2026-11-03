import Foundation

/// How much of search by meaning the user chose, in Setup or on the Sources
/// page: none, text alone (the text model), or text, pictures and sound (the
/// text model and the image and audio encoders).
enum MeaningMode: String, CaseIterable, Equatable, Sendable {
    case off
    case text
    case full

    /// What Setup and the Sources page call it. No em dashes: the user's copy.
    var title: String {
        switch self {
        case .off: "Off"
        case .text: "Text (310 MB)"
        case .full: "Text, images and audio (865 MB)"
        }
    }
}

/// Search by meaning's choice on the Sources page and in Setup, and what it
/// says about itself. Off until the user chooses: nothing downloads by
/// itself, and Setup's Done is what starts the first download. A choice is:
/// download the model files it needs (`ModelFiles`, with their progress), then
/// give the File Index its vectors (`MeaningScheduler`), then ready. Text
/// needs the text model alone and embeds no pictures or sound; adding the
/// encoders later keeps text searched by meaning while they download. Off
/// stops the embedding and gives back the vectors' memory, and keeps what is
/// on disk for the next time; "Remove" deletes the model files and the
/// vectors too. Unavailable, and nothing ever downloads, on a Mac without
/// Apple silicon (`MeaningSearch.isSupported`).
@Observable
final class MeaningSettings {
    /// Under the choice in Setup and on the Sources page.
    static let caption = "Downloads from Hugging Face. Your files never leave this Mac."

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
            case .off: "Finds files by what they say, show or sound like, in any language."
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

    /// Where the choice is kept, so the app's is in `UserDefaults` and a
    /// test's in memory. Nothing kept is off, and not yet chosen.
    struct Choice {
        /// Nil until the user has chosen.
        var mode: MeaningMode?
        var save: (MeaningMode) -> Void

        static var off: Choice { Choice(mode: .off, save: { _ in }) }

        static func defaults(_ defaults: UserDefaults, files: ModelFiles) -> Choice {
            let kept = (defaults.object(forKey: key) as? String).flatMap(MeaningMode.init(rawValue:))
            return Choice(mode: kept ?? migrated(defaults, files: files),
                          save: { defaults.set($0.rawValue, forKey: key) })
        }

        static let key = "codiclens.meaning.mode"
        /// Before the choice: one switch, on unless the user turned it off,
        /// that downloaded both files at launch.
        static let switchKey = "codiclens.meaning.enabled"

        /// An install from before the choice: the user's own off stays off,
        /// and one that had it on with anything downloaded keeps the full
        /// choice, as it was. One that never got that far has not chosen.
        private static func migrated(_ defaults: UserDefaults, files: ModelFiles) -> MeaningMode? {
            let wasOn = defaults.object(forKey: switchKey) as? Bool
            defaults.removeObject(forKey: switchKey)
            let mode: MeaningMode? = if wasOn == false { .off } else if files.hasAnything { .full } else { nil }
            if let mode { defaults.set(mode.rawValue, forKey: key) }
            return mode
        }
    }

    /// What the File Index reports, read when the status is.
    struct Progress: Equatable {
        var counts = MeaningCounts()
        var isLowPower = false
    }

    let isSupported: Bool
    let files: ModelFiles
    private(set) var mode: MeaningMode
    /// The user has chosen, in Setup or on the Sources page.
    private(set) var isChosen: Bool

    @ObservationIgnored private let save: (MeaningMode) -> Void
    /// Puts a choice into effect in the File Index: off, or the pass with or
    /// without pictures and sound.
    @ObservationIgnored var apply: (MeaningMode) -> Void = { _ in }
    /// Deletes the vectors from the File Index.
    @ObservationIgnored var removeVectors: () -> Void = {}
    /// Read from a view's `body`, so tracked like any `@Observable` read.
    @ObservationIgnored var progress: () -> Progress = { Progress() }
    /// What the File Index's pass is doing: set once the files are there.
    private(set) var applied = MeaningMode.off

    init(files: ModelFiles, choice: Choice, isSupported: Bool = MeaningSearch.isSupported) {
        self.files = files
        self.isSupported = isSupported
        mode = isSupported ? choice.mode ?? .off : .off
        isChosen = choice.mode != nil
        save = choice.save
        files.want(needed(for: mode))
    }

    var isEnabled: Bool { mode != .off }

    /// What Setup offers the first time: the user's choice once there is
    /// one, else text, images and audio.
    var suggested: MeaningMode {
        guard isSupported else { return .off }
        return isChosen ? mode : .full
    }

    /// The model files `mode` runs on. Off keeps wanting what was, so the
    /// status of what is on disk does not change.
    private func needed(for mode: MeaningMode) -> [ModelFile] {
        switch mode {
        case .off, .full: files.files
        case .text: [files.textModel]
        }
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
        guard applied == mode, progress.counts.embedded >= progress.counts.files else {
            return progress.isLowPower ? .paused(progress.counts) : .reading(progress.counts)
        }
        return .ready(progress.counts)
    }

    /// The choice, from Setup's Done or the Sources page. Downloads what is
    /// missing, then starts the pass; off stops both. Text keeps a pass that
    /// runs while the encoders download for the full choice.
    func setMode(_ mode: MeaningMode) {
        guard isSupported else { return }
        isChosen = true
        save(mode)
        guard mode != self.mode else { return }
        self.mode = mode
        files.cancel()
        if mode == .off {
            if applied != .off {
                applied = .off
                apply(.off)
            }
        } else {
            files.want(needed(for: mode))
            start()
        }
    }

    /// At launch, and after a choice: the model files, then the pass.
    /// Starts nothing before the user has chosen.
    func start() {
        guard isSupported, isEnabled else { return }
        Task { await startAndWait() }
    }

    /// `start()`, returning once that has settled, for tests; the app does
    /// not wait.
    func startAndWait() async {
        guard isSupported, isEnabled else { return }
        let mode = self.mode
        await files.download()
        guard mode == self.mode, files.isReady, applied != mode else { return }
        applied = mode
        apply(mode)
    }

    /// Off, the model files deleted and the vectors with them. Choosing again
    /// downloads the model again and reads every file again.
    func remove() {
        setMode(.off)
        files.remove()
        removeVectors()
    }
}
