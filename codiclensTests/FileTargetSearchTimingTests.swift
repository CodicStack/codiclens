import AppKit
import Testing
@testable import codiclens

private let timingRuns = ProcessInfo.processInfo.environment["CODICLENS_TIME_FILE_SEARCH"].flatMap { Int($0) }

/// Wall-clock timings for Finder's Target list, stage by stage, against the
/// real Spotlight index of the machine it runs on. Not a pass/fail test: the
/// numbers depend on what is on disk, so it is off unless asked for.
///
/// ```
/// TEST_RUNNER_CODICLENS_TIME_FILE_SEARCH=5 xcodebuild test \
///   -project codiclens.xcodeproj -scheme codiclens -configuration Debug \
///   -only-testing:codiclensTests/FileTargetSearchTimingTests
/// ```
///
/// The variable's value is the number of runs; each stage is their median.
/// "Keystroke" is the whole of what the user waits for: the 150ms debounce,
/// both lookups, ranking, icons and the hop back to main. Rows print as each
/// Query finishes.
@Suite(.serialized, .enabled(if: timingRuns != nil))
struct FileTargetSearchTimingTests {
    static let queries = ["invoice", "skat", "png", "screenshot", "a"]

    @Test func stageTimings() async {
        let runs = timingRuns ?? 1
        print("query       priority (lines)    system-wide (lines) both lookups  rank+icons  keystroke")
        for query in Self.queries {
            var priority: [Duration] = [], everywhere: [Duration] = [], both: [Duration] = []
            var targets: [Duration] = [], keystroke: [Duration] = []
            var priorityLines = 0, everywhereLines = 0

            for _ in 0..<runs {
                let search = FileTargetSearch(query: query, searchFiles: { _ in [] })
                priority.append(Self.time { priorityLines = search.lookup(.priorityFolders).count })
                everywhere.append(Self.time { everywhereLines = search.lookup(.systemWide).count })
                var paths: [String] = []
                both.append(Self.time { paths = search.candidatePaths() })
                targets.append(Self.time { _ = FileTargetSearch.targets(from: paths, query: query) })
                keystroke.append(await Self.keystroke(query))
            }

            print([
                query.padding(toLength: 12, withPad: " ", startingAt: 0),
                "\(Self.ms(priority)) (\(priorityLines))".padding(toLength: 20, withPad: " ", startingAt: 0),
                "\(Self.ms(everywhere)) (\(everywhereLines))".padding(toLength: 20, withPad: " ", startingAt: 0),
                Self.ms(both).padding(toLength: 14, withPad: " ", startingAt: 0),
                Self.ms(targets).padding(toLength: 12, withPad: " ", startingAt: 0),
                Self.ms(keystroke)
            ].joined())
            fflush(stdout)
        }
    }

    /// From typing the Query to the Target list landing, through the view model.
    @MainActor
    private static func keystroke(_ query: String) async -> Duration {
        let viewModel = TargetSearchVM(shareTargetProvider: { _ in [] }, searchFiles: { _ in [] })
        let finder = Subject(
            displayName: "Finder",
            path: "/System/Library/CoreServices/Finder.app",
            url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
            icon: NSImage(),
            kind: .app(bundleIdentifier: "com.apple.finder", isRunning: true)
        )
        let openFile = SubjectAction(
            name: "Open File",
            icon: .sfSymbol("doc"),
            isFinal: false,
            handler: .openFile
        )
        viewModel.loadTargets(for: finder, action: openFile)

        let start = ContinuousClock.now
        viewModel.searchText = query
        await waitUntil { viewModel.isSearching }
        await waitUntil { !viewModel.isSearching }
        return ContinuousClock.now - start
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        while !condition() {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = condition() } onChange: { continuation.resume() }
            }
        }
    }

    private static func time(_ body: () -> Void) -> Duration {
        ContinuousClock().measure(body)
    }

    private static func ms(_ samples: [Duration]) -> String {
        let median = samples.sorted()[samples.count / 2]
        let millis = Double(median.components.seconds) * 1000
            + Double(median.components.attoseconds) / 1e15
        return String(format: "%.0f ms", millis)
    }
}
