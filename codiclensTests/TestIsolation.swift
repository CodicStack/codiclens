import Foundation
import Testing
@testable import codiclens

// The unit-test host is the app itself, and every `.shared` it has is the
// user's: their Clipboard History, Emoji Recents, Sources and File Index.
// Nothing here touches one. `AppDelegate` starts nothing in the test host, and
// the app's initialisers take what reaches user data without a default, so a
// test builds its own from these.

/// An Index over no directories: it scans nothing and starts no FSEvents
/// stream. Pass it as `CommandCoordinator(index:)` so building a coordinator in
/// a test never touches `/Applications` or watches the filesystem.
@MainActor
let inertAppIndex = AppIndex(directories: [])

/// `UserDefaults` that keeps what it is given in memory, for a `SourceStore`
/// or `EmojiPreferences` of a test's own. A real suite per test outlives it
/// as a plist in `~/Library/Preferences`, even after
/// `removePersistentDomain` — a thousand of them had piled up. Everything the
/// app reads and writes goes through `object(forKey:)` and `set(_:forKey:)`;
/// the suite name underneath is only there so anything else lands somewhere
/// harmless.
final class ThrowawayDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: "codiclens-tests-" + UUID().uuidString)!
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { values[defaultName] = value }
    }

    override func removeObject(forKey defaultName: String) {
        set(nil, forKey: defaultName)
    }
}

/// Emoji Mode over in-memory Recents and a throwaway default tone.
@MainActor
func throwawayEmojiVM(index: EmojiIndex? = nil, recents: EmojiRecents? = nil) -> EmojiSearchVM {
    EmojiSearchVM(
        index: index,
        recents: recents ?? EmojiRecents(store: InMemoryEmojiRecentsStore()),
        preferences: EmojiPreferences(defaults: ThrowawayDefaults())
    )
}

@MainActor
extension CommandCoordinator {
    /// A coordinator over nothing of the user's: no app scan, its own Sources
    /// and Emoji state, and a File Index that finds nothing unless a test
    /// hands in one that does. Defaults are nil because a default argument
    /// cannot build a main-actor value here.
    static func isolated(
        runner: EffectRunner? = nil,
        history: ClipboardHistory? = nil,
        emojiVM: EmojiSearchVM? = nil,
        index: AppIndex? = nil,
        sources: SourceStore? = nil,
        searchFiles: @escaping FileIndex.Search = { _ in [] }
    ) -> CommandCoordinator {
        CommandCoordinator(
            runner: runner ?? RecordingEffectRunner(),
            history: history ?? ClipboardHistory(store: InMemoryClipboardStore()),
            emojiVM: emojiVM ?? throwawayEmojiVM(),
            index: index ?? inertAppIndex,
            sources: sources ?? SourceStore(defaults: ThrowawayDefaults()),
            searchFiles: searchFiles
        )
    }
}
