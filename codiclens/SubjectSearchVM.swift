import AppKit
import Combine

@Observable
class SubjectSearchVM {
    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            updateResults()
        }
    }
    var results: [Subject] = []
    var selectedIndex: Int = 0
    var isResultsVisible: Bool = false
    var isSearchCommitted: Bool = false

    private var appCache: [Subject] = []
    private var appResults: [Subject] = []

    private let visibilitySubject = PassthroughSubject<Void, Never>()
    private let commitSubject = PassthroughSubject<Void, Never>()
    private var visibilityCancellable: AnyCancellable?
    private var commitCancellable: AnyCancellable?

    init() {
        loadApps()
        loadBuiltIns()

        visibilityCancellable = visibilitySubject
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.isResultsVisible = true
            }

        commitCancellable = commitSubject
            .debounce(for: .milliseconds(1500), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.isSearchCommitted = true
            }
    }

    private func loadApps() {
        let appDirs = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices",
            NSHomeDirectory() + "/Applications"
        ]

        let fm = FileManager.default
        for dir in appDirs {
            guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in contents where item.hasSuffix(".app") {
                let path = "\(dir)/\(item)"
                let name = (item as NSString).deletingPathExtension
                let url = URL(fileURLWithPath: path)
                let icon = NSWorkspace.shared.icon(forFile: path)
                icon.size = NSSize(width: 32, height: 32)
                let bundleId = Bundle(path: path)?.bundleIdentifier

                appCache.append(Subject(
                    displayName: name,
                    path: path,
                    url: url,
                    icon: icon,
                    kind: .app(bundleIdentifier: bundleId, isRunning: false)
                ))
            }
        }
    }

    private func loadBuiltIns() {
        let settingsIcon = NSImage(systemSymbolName: "gear", accessibilityDescription: nil) ?? NSImage()
        settingsIcon.size = NSSize(width: 32, height: 32)
        appCache.append(Subject(
            displayName: "Settings",
            path: nil,
            url: nil,
            icon: settingsIcon,
            kind: .builtIn(.settings)
        ))

        let clipboardIcon = NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil) ?? NSImage()
        clipboardIcon.size = NSSize(width: 32, height: 32)
        appCache.append(Subject(
            displayName: "Clipboard",
            path: nil,
            url: nil,
            icon: clipboardIcon,
            kind: .builtIn(.clipboard)
        ))
    }

    private func updateResults() {
        isResultsVisible = false
        isSearchCommitted = false

        guard !searchText.isEmpty else {
            appResults = []
            results = []
            selectedIndex = 0
            return
        }

        appResults = appCache
            .compactMap { subject -> (Subject, Int)? in
                guard let score = fuzzyScore(subject.displayName, searchText) else { return nil }
                return (subject, score)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(5)
            .map { $0.0 }

        if appResults.isEmpty {
            let textIcon = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil) ?? NSImage()
            textIcon.size = NSSize(width: 32, height: 32)
            results = [Subject(
                displayName: searchText,
                path: nil,
                url: nil,
                icon: textIcon,
                kind: .text(rawText: searchText)
            )]
        } else {
            results = appResults
        }
        selectedIndex = 0

        visibilitySubject.send()
        commitSubject.send()
    }

    func reset() {
        searchText = ""
        results = []
        appResults = []
        selectedIndex = 0
        isResultsVisible = false
        isSearchCommitted = false
    }
}
