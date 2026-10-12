import Foundation

/// What git leaves out of the repos in the folder Sources, for the "Ignored
/// by git" switch (`FileIndexRules.SkipGroup.gitIgnored`).
///
/// **Git is asked, never imitated.** Negation, anchoring, folder-only
/// patterns, a `.gitignore` in every folder, `.git/info/exclude` and the
/// user's `core.excludesFile` are its to apply, and tracked files are never
/// ignored, as git has it. Two questions, one process per repo each:
///
/// - `load`: a repo the crawl walks into is listed whole by `git ls-files
///   --others --ignored --exclude-standard --directory`, which names an
///   ignored folder once rather than every file in it. It also names a folder
///   that is merely *full* of ignored files, so the folders it names are put
///   to `git check-ignore` before they count: a new file in one of those is
///   not ignored.
/// - `ask`: paths FSEvents brings that the index has no row for are put to
///   `git check-ignore`, because a listing made before they existed cannot
///   say. It judges a path that does not exist yet as well as one that does.
///
/// **Only repos at or below a Source count.** A repo *around* a Source is not
/// asked: a dotfiles repo at `~` that ignores `*` would empty Documents. Repos
/// nest, and git does not look inside a repo from the one around it, so each
/// answers for its own files — and a folder the outer one ignores takes a
/// repo inside it along.
///
/// What is known is one set of paths, folders and files, from every repo; a
/// path is ignored when it or a folder above it is in the set. Without git
/// (`installedGit` nil) the set stays empty and the switch has no effect.
///
/// Synchronous and not thread-safe, like `FileIndexer`, which owns it.
nonisolated final class GitIgnored {
    /// The git to run, found once without running anything. Not
    /// `/usr/bin/git`: where the Command Line Tools are missing, that shim
    /// offers to install them in a dialog, and the File Index runs unseen.
    static let installedGit: String? = {
        var candidates: [String] = []
        // xcode-select's choice, as the shim would make it.
        if let developer = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            candidates.append(developer + "/usr/bin/git")
        }
        candidates += [
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Nil: nothing is ignored. Tests pass nil for a Mac without git.
    let git: String?

    /// Every path known to be ignored, with the repo that said so.
    private var ignored: [String: String] = [:]
    /// The repos listed whole since they were last forgotten.
    private var loaded: Set<String> = []

    init(git: String? = GitIgnored.installedGit) {
        self.git = git
    }

    var isAvailable: Bool { git != nil }

    // MARK: - Asking

    /// Whether `path` or a folder above it, up to `root`, is ignored, as far
    /// as git has been asked by the repos in `root`.
    func isIgnored(_ path: String, below root: String) -> Bool {
        guard !ignored.isEmpty else { return false }
        var current = path
        while current.utf8.count > root.utf8.count {
            if contains(current, below: root) { return true }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
    }

    /// Whether `path` itself was named by a repo in `root`: for a walk, which
    /// knows whether the folder it is in was. A Source inside another that
    /// is a repo is not that repo's to judge.
    func contains(_ path: String, below root: String) -> Bool {
        guard let repo = ignored[path] else { return false }
        return repo == root || repo.hasPrefix(root + "/")
    }

    /// Lists `repo` whole, in place of what it said before.
    func load(repo: String) {
        forget(repo: repo)
        loaded.insert(repo)
        guard let listed = run(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"],
                               in: repo) else { return }
        var folders: [String] = []
        for entry in listed {
            if entry.hasSuffix("/") {
                folders.append(String(entry.dropLast()))
            } else {
                ignored[repo + "/" + entry] = repo
            }
        }
        guard !folders.isEmpty else { return }
        for folder in checkIgnore(folders, in: repo) {
            ignored[repo + "/" + folder] = repo
        }
    }

    /// `load`, unless that was done already and not forgotten since.
    func loadIfNeeded(repo: String) {
        if !loaded.contains(repo) { load(repo: repo) }
    }

    /// Puts `paths` to every repo they are in below `root`, one process per
    /// repo. The innermost judges the path; each one around it judges the
    /// folder of the repo inside it, which is all of the path it can see.
    func ask(_ paths: [String], below root: String) {
        var questions: [String: Set<String>] = [:]
        for path in paths where path != root && !isIgnored(path, below: root) {
            let repos = Self.repos(containing: path, below: root)
            for (index, repo) in repos.enumerated() {
                let subject = index + 1 < repos.count ? repos[index + 1] : path
                questions[repo, default: []].insert(String(subject.dropFirst(repo.count + 1)))
            }
        }
        for (repo, relatives) in questions {
            for relative in checkIgnore(Array(relatives), in: repo) {
                ignored[repo + "/" + relative] = repo
            }
        }
    }

    /// Drops what `repo` said, to be asked again.
    func forget(repo: String) {
        loaded.remove(repo)
        ignored = ignored.filter { $0.value != repo }
    }

    /// Drops what every repo at or below `root` said: a crawl lists them again.
    func forget(below root: String) {
        let isBelow = { (repo: String) in repo == root || repo.hasPrefix(root + "/") }
        loaded = loaded.filter { !isBelow($0) }
        ignored = ignored.filter { !isBelow($0.value) }
    }

    func forgetAll() {
        loaded = []
        ignored = [:]
    }

    /// The folders from `root` down to `path`'s own with a `.git` in them —
    /// a folder, or a worktree's or submodule's file — outermost first.
    /// `path` itself is not one: a repo does not judge its own folder.
    static func repos(containing path: String, below root: String) -> [String] {
        guard path.hasPrefix(root + "/") else { return [] }
        var folders = [root]
        var current = root
        for name in path.dropFirst(root.count + 1).split(separator: "/").dropLast() {
            current += "/" + name
            folders.append(current)
        }
        var info = stat()
        return folders.filter { lstat($0 + "/.git", &info) == 0 }
    }

    // MARK: - Git's own setup

    /// What git's setup outside any repo comes to: which git, and the user's
    /// global excludes file with what it says. Nothing in a Source reports a
    /// change to these, so the index keeps this beside its rules and a launch
    /// that finds it changed reads every root again. Read once.
    private(set) lazy var setupStamp: String = {
        guard let git else { return "no git" }
        let configured = run(["config", "-z", "--path", "--get", "core.excludesFile"], in: "/")?.first
        let environment = ProcessInfo.processInfo.environment
        let config = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory() + "/.config"
        let path = configured ?? config + "/git/ignore"
        let contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return [git, path, contents].joined(separator: "\n")
    }()

    // MARK: - Running git

    /// What git inherits of the app's environment: the basics, never the test
    /// host's injection variables or a `GIT_DIR` from wherever the app was
    /// started. `XDG_CONFIG_HOME` is where the global excludes file lives.
    private static let inherited: Set<String> = [
        "HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "XDG_CONFIG_HOME"
    ]

    /// The paths among `relatives` that `repo` ignores.
    private func checkIgnore(_ relatives: [String], in repo: String) -> [String] {
        run(["check-ignore", "--stdin", "-z"], in: repo, input: relatives) ?? []
    }

    /// Runs git in `directory` and returns what it printed, split at NULs, or
    /// nil if it failed: no git, not a repo, or a path git refused. `input`
    /// is its stdin, NUL-separated.
    ///
    /// Nothing goes through a pipe. Git reads a file, writes a file and is
    /// waited for by its exit: a pipe end is inherited by any process started
    /// meanwhile on another thread — the embedding helper, `mdfind`, another
    /// git — and a read waiting for end-of-file then waits for that process
    /// instead. Two gits holding each other's pipes never end.
    private func run(_ arguments: [String], in directory: String, input: [String]? = nil) -> [String]? {
        guard let git else { return nil }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("codiclens-git-\(UUID().uuidString)")
        let inputURL = scratch.appendingPathExtension("in"), outputURL = scratch.appendingPathExtension("out")
        let inputData = input.map { Data(($0.joined(separator: "\0") + "\0").utf8) } ?? Data()
        guard FileManager.default.createFile(atPath: inputURL.path, contents: inputData),
              FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let stdin = try? FileHandle(forReadingFrom: inputURL),
              let stdout = try? FileHandle(forWritingTo: outputURL) else { return nil }
        defer {
            try? stdin.close()
            try? stdout.close()
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", directory] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { Self.inherited.contains($0.key) }
        // Only the repo at `directory`, never one around it it would find by
        // looking further up; and no lock files in a repo the user is using.
        environment["GIT_CEILING_DIRECTORIES"] = (directory as NSString).deletingLastPathComponent
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        // `check-ignore` exits 1 when nothing it was given is ignored.
        guard process.terminationReason == .exit, [0, 1].contains(process.terminationStatus),
              let data = try? Data(contentsOf: outputURL) else { return nil }
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }
}
