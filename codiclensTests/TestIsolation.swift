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
    ///
    /// Without `searchSettled` the settled pass asks `searchFiles` again, as
    /// the File Index's own does with search by meaning off.
    static func isolated(
        runner: EffectRunner? = nil,
        history: ClipboardHistory? = nil,
        emojiVM: EmojiSearchVM? = nil,
        index: AppIndex? = nil,
        sources: SourceStore? = nil,
        searchFiles: @escaping FileIndex.Search = { _ in [] },
        searchSettled: FileIndex.SettledSearch? = nil,
        searchSchedule: HeldSearchSchedule? = nil
    ) -> CommandCoordinator {
        CommandCoordinator(
            runner: runner ?? RecordingEffectRunner(),
            history: history ?? ClipboardHistory(store: InMemoryClipboardStore()),
            emojiVM: emojiVM ?? throwawayEmojiVM(),
            index: index ?? inertAppIndex,
            sources: sources ?? SourceStore(defaults: ThrowawayDefaults()),
            searchFiles: searchFiles,
            searchSettled: searchSettled ?? { query in searchFiles(query) },
            searchSchedule: searchSchedule ?? HeldSearchSchedule()
        )
    }
}

/// Subject search's schedule, run by hand: the list below the apps is searched
/// when a test says so and typing pauses when a test says so, never on a
/// clock. A test that does neither sees the apps alone, every time.
@MainActor
final class HeldSearchSchedule: SearchSchedule {
    private var searches: [@MainActor () async -> Void] = []
    private var pause: (@MainActor () -> Void)?

    /// Whether a pause is waiting to be run.
    var isPauseWaiting: Bool { pause != nil }

    func run(_ search: @escaping @MainActor () async -> Void) {
        searches.append(search)
    }

    func afterPause(_ settle: @escaping @MainActor () -> Void) {
        pause = settle
    }

    /// Runs the searches asked for so far to the end, including any they ask
    /// for as they go: the word matches for the Query as typed.
    func runSearches() async {
        while !searches.isEmpty {
            await searches.removeFirst()()
        }
    }

    /// Typing pauses: the searches out land, the settled pass runs and lands
    /// too. What the list is once the Query has settled.
    func typingPaused() async {
        await runSearches()
        let settle = pause
        pause = nil
        settle?()
        await runSearches()
    }
}
