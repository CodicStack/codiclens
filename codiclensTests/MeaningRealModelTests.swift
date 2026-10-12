import Foundation
import Testing
@testable import codiclens

private let realModelRequested = ProcessInfo.processInfo.environment["CODICLENS_MEANING_REAL"] != nil

/// Search by meaning with the real model, end to end: a temporary folder of
/// files whose names give nothing away — a Danish lease, an English smoothie
/// recipe, three animal pictures, a spoken recording and a short video with a
/// spoken soundtrack, among thirty notes about other things — crawled, read,
/// embedded by the real indexing helper, and searched through the real query
/// encoder. Each Query must find its file in the top three, by meaning alone.
/// Prints what each step cost. Needs the model files in Application Support
/// and `say`; off unless asked for.
///
/// ```
/// TEST_RUNNER_CODICLENS_MEANING_REAL=1 xcodebuild test \
///   -project codiclens.xcodeproj -scheme codiclens -configuration Debug \
///   -parallel-testing-enabled NO -only-testing:codiclensTests/MeaningRealModelTests
/// ```
@Suite(.serialized, .enabled(if: realModelRequested), .timeLimit(.minutes(20)))
struct MeaningRealModelTests {
    static let lease = """
        Lejekontrakt for beboelseslejlighed. Udlejer og lejer aftaler, at lejemålet begynder den 1. marts. \
        Den månedlige husleje betales forud den første hverdag i måneden. Lejer betaler et depositum svarende til \
        tre måneders husleje. Lejemålet kan opsiges af lejer med tre måneders varsel til den første i en måned. \
        Husdyr må ikke holdes uden udlejers skriftlige samtykke.
        """
    static let recipe = """
        Breakfast in five minutes. Put one ripe banana, a cup of frozen berries, a spoon of honey, half a cup of \
        plain yogurt and a splash of milk in the blender. Blend until smooth and drink it cold.
        """
    static let spoken = "The quarterly budget meeting has been moved to Thursday afternoon at three o'clock."
    static let videoSpoken = "Remember to water the tomato plants in the greenhouse every single morning."

    static let fillers = [
        "The train to Aarhus leaves from platform four at half past nine.",
        "Our football team won the derby two to one after extra time.",
        "Install the package with npm and run the build script before testing.",
        "The weather tomorrow will be cloudy with light rain in the evening.",
        "Remember to renew the car insurance before the end of the year.",
        "The museum opens at ten and the special exhibition is about Vikings.",
        "Set the oven to two hundred degrees and bake the bread for forty minutes.",
        "The wifi password for the guest network is printed on the router.",
        "Jeg har bestilt tid hos frisøren på tirsdag klokken fire.",
        "Husk at købe mælk, æg og rugbrød på vej hjem.",
        "Bilen skal til syn i næste måned, og dækkene skal skiftes.",
        "Vi mødes ved stranden lørdag og griller hvis vejret holder.",
        "The quarterly tax filing is due on the fifteenth of the month.",
        "Bring a passport, a charger and comfortable walking shoes on the trip.",
        "The new phone has a better camera but the battery is smaller.",
        "Knitting a scarf takes about two balls of wool and a free weekend.",
        "The cat sleeps on the windowsill every afternoon in the sun.",
        "Our flight to Lisbon was delayed by three hours because of fog.",
        "Mortgage rates went up again, so we are waiting to buy a house.",
        "The guitar needs new strings and the tuning pegs are loose.",
        "Water the lawn only in the evening during a dry summer.",
        "Børnene skal hentes klokken tre fra børnehaven på fredag.",
        "Reservationen på restauranten er til seks personer klokken syv.",
        "The printer on the second floor is out of toner again.",
        "Chess club meets on Wednesdays in the library basement.",
        "Paint the fence before winter so the wood does not rot.",
        "Our dentist moved to a new clinic near the central station.",
        "The marathon route goes along the harbour and through the park.",
        "Back up the laptop to the external drive every Friday.",
        "The library book about volcanoes is two weeks overdue.",
    ]

    @Test func danishEnglishPicturesSpeechAndVideoAreFoundByMeaning() async throws {
        let models = ModelFiles()
        try #require(models.isReady, "the model files are not in \(models.folder.path)")
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.makeFolder("Source")
        let root = folder.path("Source")
        func path(_ name: String) -> String { root + "/" + name }

        try Self.lease.write(toFile: path("dokument-a.txt"), atomically: true, encoding: .utf8)
        try Self.recipe.write(toFile: path("notes-b.md"), atomically: true, encoding: .utf8)
        for (index, line) in Self.fillers.enumerated() {
            try line.write(toFile: path("note-\(index).txt"), atomically: true, encoding: .utf8)
        }
        for (animal, name) in [("Zebra", "IMG_0412.heic"), ("Penguin", "IMG_0413.heic"), ("Parrot", "IMG_0414.heic")] {
            // The account pictures are symlinks, which the File Index leaves out.
            let picture = URL(fileURLWithPath: "/Library/User Pictures/Animals/\(animal).heic").resolvingSymlinksInPath()
            try FileManager.default.copyItem(at: picture, to: URL(fileURLWithPath: path(name)))
        }
        try Self.say(Self.spoken, to: path("rec-0042.aiff"))
        let soundtrack = folder.path("soundtrack.aiff")
        try Self.say(Self.videoSpoken, to: soundtrack)
        try await TestMedia.movie(at: path("clip-7.mov"), seconds: 8, shot: 4, audio: URL(fileURLWithPath: soundtrack))

        let url = folder.url.appendingPathComponent("FileIndex.sqlite")
        let writer = try FileIndexWriter(url: url)
        let indexer = FileIndexer(writer: writer)
        for root in try indexer.setSources([(path: root, isEnabled: true)]) { try indexer.crawl(root) }
        let contents = FileContentScheduler(writer: writer, queue: DispatchQueue(label: "real.contents"))
        contents.setSources([root])
        while true {
            let jobs = try contents.nextBatch()
            if jobs.isEmpty { break }
            try contents.store(await FileContentScheduler.readAll(jobs))
        }

        let indexing = EmbeddingClient.helper(textOnly: false, idleExit: 30)
        let vectors = MeaningVectors(databaseURL: url)
        let cache = try VectorCache(url: VectorCache.url(besideDatabase: url))
        let meaning = MeaningScheduler(writer: writer, vectors: vectors, cache: cache, queue: DispatchQueue(label: "real.meaning"),
                                       embed: MeaningScheduler.embedAll(with: indexing, cache: cache))
        meaning.setSources([root])
        try meaning.enable()
        var perKind: [String: (files: Int, time: Duration)] = [:]
        let started = ContinuousClock.now
        while true {
            let jobs = try meaning.nextBatch()
            if jobs.isEmpty { break }
            var results: [MeaningResult] = []
            let time = try await ContinuousClock().measure {
                for job in jobs { results.append(try await MeaningReader.read(job, with: indexing, cache: cache)) }
            }
            perKind["\(jobs[0].content)", default: (0, .zero)].files += jobs.count
            perKind["\(jobs[0].content)", default: (0, .zero)].time += time
            try meaning.store(results)
        }
        print("embedded in \(ContinuousClock.now - started), \(vectors.liveCount) vectors (the helper's load included)")
        for (kind, cost) in perKind.sorted(by: { $0.key < $1.key }) { print("  \(kind): \(cost.files) files, \(cost.time)") }
        await indexing.shutdown()

        let query = EmbeddingClient.helper(textOnly: true, idleExit: 30)
        try await query.hold()
        let reader = FileIndexReader(url: url)
        let cases: [(query: String, expected: String)] = [
            ("kontrakt", "dokument-a.txt"),
            ("smoothie opskrift", "notes-b.md"),
            ("a zebra", "IMG_0412.heic"),
            ("a colourful parrot", "IMG_0414.heic"),
            ("budget meeting moved to Thursday", "rec-0042.aiff"),
            ("water the tomatoes in the greenhouse", "clip-7.mov"),
        ]
        var found = 0
        for (text, expected) in cases {
            var hits: [FileHit] = []
            let embedded = ContinuousClock.now
            let vector = try await query.embedQuery(text, code: false)
            let scored = ContinuousClock.now
            let scores = MeaningScores(try #require(vectors.snapshot()), query: vector)
            let fused = ContinuousClock.now
            hits = reader.fusedSearch(text, limit: 10, sources: [root], meaning: scores)
            let done = ContinuousClock.now
            let rank = hits.firstIndex { $0.name == expected }
            if let rank, rank < 3 { found += 1 }
            print("\"\(text)\" → \(expected) at \(rank.map { "\($0 + 1)" } ?? "—")  "
                  + "(embed \(scored - embedded), score \(fused - scored), fuse \(done - fused))")
            for hit in hits.prefix(3) {
                print("    \(hit.score) \(hit.name) \(hit.meaning.map { "\($0)" } ?? "words") \(hit.passage?.subtitle.prefix(60) ?? "")")
            }
            #expect(rank.map { $0 < 3 } == true, "\(text) should find \(expected)")
        }
        print("\(found) of \(cases.count) in the top three")
        await query.shutdown()
    }

    static func say(_ text: String, to path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", path, text]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }
}
