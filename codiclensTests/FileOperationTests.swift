import AppKit
import Testing
@testable import codiclens

/// The real file work behind Move To…, Copy To…, Rename and Compress, in a
/// temporary folder of its own: the right files come out, and nothing that was
/// already there is ever overwritten. Also the runner's half: it answers on the
/// main thread, and Copy File puts the file itself on a pasteboard.
@MainActor
struct FileOperationTests {

    // MARK: - Fixtures

    /// A temporary folder, removed by the caller.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-file-ops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func write(_ text: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func folder(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Names

    @Test func candidatesCountOnAsFinderDoes() {
        #expect(Array(FileOperation.candidates(for: "Report.pdf", keepsExtension: true).prefix(3))
            == ["Report.pdf", "Report 2.pdf", "Report 3.pdf"])
        #expect(Array(FileOperation.candidates(for: "Report 2.pdf", keepsExtension: true).prefix(3))
            == ["Report 2.pdf", "Report 3.pdf", "Report 4.pdf"])
        #expect(Array(FileOperation.candidates(for: "v1.2", keepsExtension: false).prefix(2))
            == ["v1.2", "v1.2 2"])
        #expect(Array(FileOperation.candidates(for: "notes.txt.zip", keepsExtension: true).prefix(2))
            == ["notes.txt.zip", "notes.txt 2.zip"])
        #expect(Array(FileOperation.candidates(for: "Makefile", keepsExtension: true).prefix(2))
            == ["Makefile", "Makefile 2"])
    }

    @Test(arguments: [
        ("note.txt", false, "note"),
        ("archive.tar.gz", false, "archive.tar"),
        (".gitignore", false, ".gitignore"),
        ("Makefile", false, "Makefile"),
        ("v1.2", true, "v1.2"),
    ])
    func renameSelectsTheBaseName(name: String, isFolder: Bool, selected: String) {
        #expect(name[FileOperation.baseNameRange(in: name, isFolder: isFolder)] == selected)
    }

    // MARK: - Move

    @Test func moveIntoAFolderMovesIt() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("hello", to: root.appendingPathComponent("note.txt"))
        let inbox = try folder("Inbox", in: root)

        let landed = try FileOperation.move(note, into: inbox).perform().get()

        #expect(landed == inbox.appendingPathComponent("note.txt"))
        #expect(try read(landed) == "hello")
        #expect(!FileManager.default.fileExists(atPath: note.path))
    }

    @Test func moveOntoATakenNameKeepsBoth() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("new", to: root.appendingPathComponent("note.txt"))
        let inbox = try folder("Inbox", in: root)
        try write("old", to: inbox.appendingPathComponent("note.txt"))
        try write("older", to: inbox.appendingPathComponent("note 2.txt"))

        let landed = try FileOperation.move(note, into: inbox).perform().get()

        #expect(landed.lastPathComponent == "note 3.txt")
        #expect(try read(inbox.appendingPathComponent("note.txt")) == "old")
        #expect(try read(inbox.appendingPathComponent("note 2.txt")) == "older")
        #expect(try read(landed) == "new")
    }

    @Test func moveIntoTheFolderItIsInDoesNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("hello", to: root.appendingPathComponent("note.txt"))

        let unslashed = URL(fileURLWithPath: root.path, isDirectory: false)

        #expect(FileOperation.move(note, into: root).perform() == .success(note))
        #expect(FileOperation.move(note, into: unslashed).perform() == .success(note))
        #expect(try names(in: root) == ["note.txt"])
    }

    @Test func moveAFolderIntoItselfFails() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = try folder("Projects", in: root)
        let inside = try folder("inside", in: projects)

        #expect(FileOperation.move(projects, into: inside).perform() == .failure(.failed))
        #expect(FileManager.default.fileExists(atPath: inside.path))
    }

    // MARK: - Copy

    @Test func copyLeavesTheOriginalAndNumbersTheSecondCopy() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("hello", to: root.appendingPathComponent("note.txt"))
        let inbox = try folder("Inbox", in: root)

        let first = try FileOperation.copy(note, into: inbox).perform().get()
        let second = try FileOperation.copy(note, into: inbox).perform().get()

        #expect(first.lastPathComponent == "note.txt")
        #expect(second.lastPathComponent == "note 2.txt")
        #expect(try read(note) == "hello")
        #expect(try names(in: inbox) == ["note 2.txt", "note.txt"])
    }

    @Test func copyAFolderWithADotInItsNameNumbersTheWholeName() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let release = try folder("v1.2", in: root)
        try write("x", to: release.appendingPathComponent("inner.txt"))
        let inbox = try folder("Inbox", in: root)
        try FileManager.default.createDirectory(at: inbox.appendingPathComponent("v1.2"), withIntermediateDirectories: true)

        let landed = try FileOperation.copy(release, into: inbox).perform().get()

        #expect(landed.lastPathComponent == "v1.2 2")
        #expect(try read(landed.appendingPathComponent("inner.txt")) == "x")
    }

    // MARK: - Rename

    @Test func renameRenamesInPlace() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("hello", to: root.appendingPathComponent("note.txt"))

        let renamed = try FileOperation.rename(note, to: "memo.txt").perform().get()

        #expect(renamed == root.appendingPathComponent("memo.txt"))
        #expect(try names(in: root) == ["memo.txt"])
    }

    @Test func renameOntoATakenNameIsRefusedAndTouchesNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("note", to: root.appendingPathComponent("note.txt"))
        try write("memo", to: root.appendingPathComponent("memo.txt"))

        #expect(FileOperation.rename(note, to: "memo.txt").perform() == .failure(.nameTaken))
        #expect(try read(root.appendingPathComponent("memo.txt")) == "memo")
        #expect(try read(note) == "note")
    }

    @Test func renameChangingOnlyTheCaseGoesThrough() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("hello", to: root.appendingPathComponent("note.txt"))

        let renamed = try FileOperation.rename(note, to: "Note.txt").perform().get()

        #expect(renamed.lastPathComponent == "Note.txt")
        #expect(try names(in: root) == ["Note.txt"])
    }

    @Test(arguments: ["", ".", "..", "a/b"])
    func renameRefusesANameThatIsNotOne(name: String) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("hello", to: root.appendingPathComponent("note.txt"))

        #expect(FileOperation.rename(note, to: name).perform() == .failure(.invalidName))
        #expect(try names(in: root) == ["note.txt"])
    }

    // MARK: - Compress

    @Test func compressZipsAFileBesideItAsFinderNamesIt() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("hello", to: root.appendingPathComponent("note.txt"))

        let zip = try FileOperation.compress(note).perform().get()

        #expect(zip == root.appendingPathComponent("note.txt.zip"))
        #expect(try Data(contentsOf: zip).prefix(2) == Data("PK".utf8))
        #expect(try names(in: root) == ["note.txt", "note.txt.zip"], "no scratch left behind")
    }

    @Test func compressNeverOverwritesAnEarlierZip() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("hello", to: root.appendingPathComponent("note.txt"))
        try write("not a zip", to: root.appendingPathComponent("note.txt.zip"))

        let zip = try FileOperation.compress(note).perform().get()

        #expect(zip.lastPathComponent == "note.txt 2.zip")
        #expect(try read(root.appendingPathComponent("note.txt.zip")) == "not a zip")
    }

    /// `--keepParent`: unzipping gives back the folder, not its loose contents.
    @Test func compressAFolderKeepsTheFolderInTheZip() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = try folder("Projects", in: root)
        try write("plan", to: projects.appendingPathComponent("plan.txt"))

        let zip = try FileOperation.compress(projects).perform().get()
        #expect(zip.lastPathComponent == "Projects.zip")

        let out = try folder("out", in: root)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, out.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(try read(out.appendingPathComponent("Projects/plan.txt")) == "plan")
    }

    @Test func compressSomethingThatIsNotThereFails() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = root.appendingPathComponent("gone.txt")
        #expect(FileOperation.compress(missing).perform() == .failure(.failed))
        #expect(try names(in: root).isEmpty)
    }

    // MARK: - The runner

    @Test func theRunnerAnswersWithWhereTheFileLanded() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("hello", to: root.appendingPathComponent("note.txt"))
        let inbox = try folder("Inbox", in: root)
        let pasteboard = NSPasteboard(name: .init("codiclens-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let runner = SystemEffectRunner(pasteboard: pasteboard)

        let (generation, result) = await withCheckedContinuation { continuation in
            runner.onFileOperation = { generation, result in
                #expect(Thread.isMainThread)
                continuation.resume(returning: (generation, result))
            }
            runner.run([.fileOperation(.move(note, into: inbox), generation: 7)])
        }

        #expect(generation == 7)
        #expect(result == .success(inbox.appendingPathComponent("note.txt")))
        #expect(try names(in: inbox) == ["note.txt"])
    }

    @Test func copyFilePutsTheFileItselfOnThePasteboard() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("hello", to: root.appendingPathComponent("note.txt"))
        let pasteboard = NSPasteboard(name: .init("codiclens-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        SystemEffectRunner(pasteboard: pasteboard).run([.copy(.fileURL(note))])

        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(urls == [note])
        #expect(pasteboard.types?.contains(.fileURL) == true)
    }

    @Test func copyPathPutsTextAndNoFile() {
        let pasteboard = NSPasteboard(name: .init("codiclens-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        SystemEffectRunner(pasteboard: pasteboard).run([.copy(.text("/tmp/note.txt"))])

        #expect(pasteboard.string(forType: .string) == "/tmp/note.txt")
        #expect(pasteboard.types?.contains(.fileURL) != true)
    }
}
