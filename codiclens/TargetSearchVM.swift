import AppKit
import Combine
import ImageIO

@Observable
class TargetSearchVM {
    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            if isFileSearchMode {
                fileSearchSubject.send(searchText)
            } else {
                filterTargets()
            }
        }
    }
    var selectedIndex: Int = 0
    var isSearching: Bool = false

    var allTargets: [ActionTarget] = []
    var filteredTargets: [ActionTarget] = []

    private var isFileSearchMode = false
    private let fileSearchSubject = PassthroughSubject<String, Never>()
    private var cancellable: AnyCancellable?
    private var searchProcess: Process?

    private static let priorityFolders: [String] = {
        let home = NSHomeDirectory()
        return [
            home + "/Downloads/",
            home + "/Documents/",
            home + "/Desktop/"
        ]
    }()

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif",
        "tiff", "tif", "bmp", "webp", "pdf", "svg"
    ]

    init() {
        cancellable = fileSearchSubject
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] text in
                self?.performFileSearch(text)
            }
    }

    func loadTargets(for subject: Subject, action: SubjectAction) {
        searchText = ""
        isFileSearchMode = false

        if case .app(let bundleId, _) = subject.kind, bundleId == "com.apple.finder" {
            isFileSearchMode = true
            allTargets = []
            filteredTargets = []
            selectedIndex = 0
            return
        }

        switch action.handler {
        case .openWith:
            allTargets = ActionTarget.openWithTargets(for: subject)
        case .share:
            allTargets = ActionTarget.shareTargets(for: subject)
        default:
            allTargets = []
        }
        filteredTargets = allTargets
        selectedIndex = 0
    }

    private func performFileSearch(_ text: String) {
        searchProcess?.terminate()
        searchProcess = nil

        guard !text.isEmpty else {
            filteredTargets = []
            selectedIndex = 0
            isSearching = false
            return
        }

        let queryText = text
        isSearching = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let priorityResults = Self.runMdfind(queryText, scopedTo: Self.priorityFolders)
            let generalResults = Self.runMdfind(queryText, scopedTo: nil)

            let prioritySet = Set(priorityResults)
            let otherResults = generalResults.filter { !prioritySet.contains($0) }.prefix(50)
            let paths = priorityResults + otherResults

            let home = NSHomeDirectory()
            let targets: [(ActionTarget, Int, Int)] = paths.compactMap { path in
                let url = URL(fileURLWithPath: path)
                let name = url.lastPathComponent
                guard let score = fuzzyScore(name, queryText) else { return nil }

                let icon = Self.thumbnailForFile(at: path)
                let subtitle = Self.shortenPath(path, home: home)
                let priority = Self.folderPriority(for: path)

                return (ActionTarget(name: name, icon: icon, subtitle: subtitle, url: url, sharingService: nil), priority, score)
            }

            let sorted = targets
                .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
                .prefix(50)
                .map { $0.0 }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.searchText == queryText else { return }
                self.filteredTargets = Array(sorted)
                self.selectedIndex = 0
                self.isSearching = false
            }
        }
    }

    private static func thumbnailForFile(at path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            let url = URL(fileURLWithPath: path) as CFURL
            if let source = CGImageSourceCreateWithURL(url, nil) {
                let status = CGImageSourceGetStatus(source)
                let count = CGImageSourceGetCount(source)
                if status == .statusComplete && count > 0 {
                    let options: [CFString: Any] = [
                        kCGImageSourceThumbnailMaxPixelSize: 64,
                        kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                        kCGImageSourceCreateThumbnailWithTransform: true
                    ]
                    if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                        let w = CGFloat(cgImage.width)
                        let h = CGFloat(cgImage.height)
                        let scale = 32.0 / max(w, h, 1)
                        return NSImage(cgImage: cgImage, size: NSSize(width: w * scale, height: h * scale))
                    }
                }
            }
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }

    private static func shortenPath(_ path: String, home: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        if dir.hasPrefix(home) {
            return "~" + dir.dropFirst(home.count)
        }
        return dir
    }

    private static func runMdfind(_ query: String, scopedTo folders: [String]?) -> [String] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")

        var args: [String] = []
        if let folders {
            for folder in folders {
                args += ["-onlyin", folder]
            }
        }
        args += ["-name", query]
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output.components(separatedBy: "\n")
            .filter { !$0.isEmpty && !$0.hasSuffix(".app") }
    }

    private static func folderPriority(for path: String) -> Int {
        for folder in priorityFolders {
            if path.hasPrefix(folder) { return 0 }
        }
        return 1
    }

    private func filterTargets() {
        if searchText.isEmpty {
            filteredTargets = allTargets
        } else {
            filteredTargets = allTargets.filter { target in
                fuzzyScore(target.name, searchText) != nil
            }
        }
        selectedIndex = 0
    }

    func reset() {
        searchText = ""
        allTargets = []
        filteredTargets = []
        selectedIndex = 0
        isFileSearchMode = false
        searchProcess?.terminate()
        searchProcess = nil
    }
}
