// The step sizes and image budgets follow DigUp's IndexOptions (https://github.com/ARahim3/DigUp), MIT licence —
// see docs/licenses/digup/LICENSE.
import Foundation

/// How the meaning pass walks a file, and what its vectors were made with.
nonisolated enum MeaningPass {
    /// A long file is embedded a step at a time, like the contents pass reads
    /// it: the first step with every file's first, the rest after. The first
    /// steps' vectors set each Query's scale (`MeaningRanking.zScores`); the
    /// later ones are scored on it. Data and logs (`FileContent.isDataOrLog`)
    /// get the first step and no more; the contents pass's first step
    /// (`FileContentReader.firstStep`) is at least as long, and this pass
    /// waits for it, so that is always their first 40 chunks.
    static let firstPages = 30
    static let laterPages = 100
    static let firstChunks = 40
    static let laterChunks = 200
    /// Of a recording or a video: the first ten minutes, then half an hour a
    /// step.
    static let firstSeconds: Double = 600
    static let laterSeconds: Double = 1800

    /// The model's audio input ignores anything past 30 s, so a recording is
    /// windows of 30 s every 25 s: a phrase cut by one is whole in the next.
    static let audioWindow: Double = 30
    static let audioHop: Double = 25
    /// A window shorter than this, past the one before it, is not worth one.
    static let audioMinimum: Double = 2
    /// A video frame every 3 s, at most 1,200 in all; one that looks like the
    /// frame kept before it only stretches that one (`MeaningReader`).
    static let frameInterval: Double = 3
    static let maxFrames = 1200
    /// Pictures smaller than this on a side are icons and badges.
    static let minimumImageSide = 256
    /// A page's or chunk's text past this is not embedded; the model reads
    /// ~2,000 tokens of it anyway.
    static let maxTextCharacters = 4000

    /// What every stored vector was made with. Any change to the model, the
    /// prompts, the budgets or the steps is a new fingerprint, and a database
    /// under another one drops its vectors and embeds everything again
    /// (`FileIndexWriter.adoptMeaningFingerprint`) — through `VectorCache`,
    /// which still has every input whose key the change left alone.
    static let fingerprint = [
        "embeddinggemma-2@\(ModelFiles.revision)",
        "prompts: title|text, search result",
        "photo \(ImageBudget.photo.tokens), screenshot \(ImageBudget.screenshot.tokens)",
        "page \(ImageBudget.pdfPage.tokens), frame \(ImageBudget.videoFrame.tokens)/\(frameInterval)s",
        "audio \(audioWindow)/\(audioHop)s",
        "steps \(firstPages)p \(firstChunks)c \(firstSeconds)s",
    ].joined(separator: "; ")

    /// The Text choice's: text alone, so going to or from it embeds again,
    /// through `VectorCache`, where every text vector is under the same key
    /// either way. Pictures, sound and pages without words, done with
    /// nothing under this one, are looked at once the encoders are added.
    static let textOnlyFingerprint = fingerprint + "; text only"

    static func fingerprint(for mode: MeaningMode) -> String {
        mode == .text ? textOnlyFingerprint : fingerprint
    }
}

/// The next of one file for the meaning pass to embed, as the writer hands it
/// out: what to look at, and for text, the text.
nonisolated struct MeaningJob: Equatable, Sendable {
    /// A Passage the contents pass read, waiting for its vector.
    struct Text: Equatable, Sendable {
        let segment: Int64
        let kind: FilePassage.Kind
        let location: Double?
        let text: String
    }

    let id: Int64
    let path: String
    let content: FileContent
    let size: Int64
    let mtime: Double
    /// Nothing of the file embedded yet: its vectors set the scale.
    let isFirstStep: Bool
    /// Where the last step stopped: PDF pages, the last Passage's segment
    /// id for text, or seconds. A cursor, not a count of vectors: a Passage
    /// that gets none (mostly digits) is passed all the same.
    let vecTo: Double
    var texts: [Text] = []
    /// A PDF's pages to look at in this step, from 0. A page in it with no
    /// Passage (`pagesWithText` is from 1) is embedded as a picture.
    var pages: Range<Int> = 0..<0
    var pagesWithText: Set<Int> = []
    /// The choice it was handed out under. Text: only the text is
    /// embedded, by the text model alone; a picture, a recording or a video
    /// gets nothing and is done, and a PDF's pages without words are passed.
    var mode = MeaningMode.full

    var isTextOnly: Bool { mode == .text }

    /// Audio, video and PDFs take a batch of their own: one can be minutes
    /// of work. Text-only, a recording or a video is none.
    var isHeavy: Bool {
        switch content {
        case .pdf: true
        case .audio, .video: !isTextOnly
        case .screenshot, .image, .document, .text, .code: false
        }
    }
}

/// What embedding one step of a file came to, as the writer takes it back.
nonisolated struct MeaningResult: Sendable {
    /// One vector: for a Passage that is already there (`segment`), or for
    /// a new one with no words — a picture, a page as a picture, a frame, a
    /// window of sound. `key` is where `VectorCache` keeps it.
    struct Vector: Sendable {
        var segment: Int64?
        var kind: FilePassage.Kind
        var location: Double?
        var end: Double?
        var key: VectorCache.Key
        /// 768 float16s (`EmbeddingVector.float16Data`).
        var vector: Data
    }

    let job: MeaningJob
    var vectors: [Vector] = []
    /// Where this step stopped, in `MeaningJob.vecTo`'s unit.
    var vecTo: Double
    /// For a recording or a video: nothing left past `vecTo`. Text and PDFs
    /// are judged by the writer, which knows what the contents pass has read.
    var isComplete = true
    /// The file is not to be tried again, whatever is left of it: it crashed
    /// the helper.
    var givesUp = false
    var detail: String?
}

/// How far the meaning pass has got in the enabled folder Sources.
nonisolated struct MeaningCounts: Equatable, Sendable {
    /// Files with anything to embed, and how many of those are through.
    var files = 0
    var embedded = 0
    /// Vectors a search scores.
    var vectors = 0
}

// MARK: - The writer's side

nonisolated extension FileIndexWriter {
    private static let meaningColumns = "id, path, content, size, mtime, vec_state, vec_to, read_to"

    /// The next files of the meaning backfill in `sources`: every file's
    /// first step before any file's later ones, and within each in
    /// `FileContent`'s order, newest first. A file waits until the contents
    /// pass has read its first step: that is where its text comes from.
    func meaningJobs(limit: Int, sources: [String], mode: MeaningMode = .full) throws -> [MeaningJob] {
        var jobs: [MeaningJob] = []
        let list = FileIndexReader.jsonList(sources)
        for state in ["pending", "partial"] where jobs.count < limit {
            var rows: [MeaningRow] = []
            try db.query("""
                SELECT \(Self.meaningColumns) FROM files
                WHERE vec_state = ? AND state != 'pending' AND content IS NOT NULL
                    AND source IN (SELECT value FROM json_each(?))
                ORDER BY content, mtime DESC LIMIT ?
                """, [.text(state), .text(list), .int(Int64(limit - jobs.count))]) { rows.append(MeaningRow($0)) }
            jobs += try rows.compactMap { try meaningJob($0, mode: mode) }
        }
        return jobs
    }

    /// The files among `ids` that have something to embed now, and those
    /// that will once the contents pass has read them.
    func meaningJobs(ids: [Int64], mode: MeaningMode = .full) throws -> (jobs: [MeaningJob], waiting: [Int64]) {
        var jobs: [MeaningJob] = []
        var waiting: [Int64] = []
        for id in ids {
            var row: MeaningRow?
            var isUnread = false
            try db.query("""
                SELECT \(Self.meaningColumns), state FROM files
                WHERE id = ? AND vec_state != 'done' AND content IS NOT NULL
                """, [.int(id)]) { statement in
                row = MeaningRow(statement)
                isUnread = statement.text(8) == "pending"
            }
            guard let row else { continue }
            if isUnread {
                waiting.append(id)
            } else if let job = try meaningJob(row, mode: mode) {
                jobs.append(job)
            }
        }
        return (jobs, waiting)
    }

    private struct MeaningRow {
        let id: Int64
        let path: String
        let content: FileContent?
        let size: Int64
        let mtime: Double
        let isFirstStep: Bool
        let vecTo: Double
        let readTo: Int

        init(_ row: SQLiteStatement) {
            id = row.int(0)
            path = row.text(1) ?? ""
            content = FileContent(rawValue: Int(row.int(2)))
            size = row.int(3)
            mtime = row.double(4)
            isFirstStep = row.text(5) == "pending"
            vecTo = row.double(6)
            readTo = Int(row.int(7))
        }
    }

    /// The job for one file: its next text to embed, or for a PDF its next
    /// pages. Pictures, recordings and videos are read by `MeaningReader`.
    private func meaningJob(_ row: MeaningRow, mode: MeaningMode) throws -> MeaningJob? {
        guard let content = row.content else { return nil }
        var job = MeaningJob(id: row.id, path: row.path, content: content, size: row.size, mtime: row.mtime,
                             isFirstStep: row.isFirstStep, vecTo: row.vecTo)
        job.mode = mode
        switch content {
        case .pdf:
            let start = Int(row.vecTo)
            job.pages = start..<max(start, min(start + (row.isFirstStep ? MeaningPass.firstPages : MeaningPass.laterPages),
                                              row.readTo))
            try db.query("""
                SELECT s.id, s.kind, s.loc, p.body, s.vec_key IS NULL FROM segments s JOIN passages p ON p.rowid = s.id
                WHERE s.file = ? AND s.kind = 'page' AND s.loc > ? AND s.loc <= ? ORDER BY s.loc
                """, [.int(row.id), .double(Double(job.pages.lowerBound)), .double(Double(job.pages.upperBound))]) { segment in
                job.pagesWithText.insert(Int(segment.double(2)))
                guard segment.int(4) != 0 else { return }
                job.texts.append(Self.text(segment))
            }
        case .document, .text, .code:
            // Data and logs past their first step: nothing to embed, and
            // `storeMeaning` calls them done.
            let limit = row.isFirstStep ? MeaningPass.firstChunks
                : FileContent.isDataOrLog(row.path) ? 0 : MeaningPass.laterChunks
            guard limit > 0 else { break }
            try db.query("""
                SELECT s.id, s.kind, s.loc, p.body FROM segments s JOIN passages p ON p.rowid = s.id
                WHERE s.file = ? AND s.id > ? AND s.kind IN ('chunk', 'page') ORDER BY s.id LIMIT ?
                """, [.int(row.id), .int(Int64(row.vecTo)), .int(Int64(limit))]) {
                job.texts.append(Self.text($0))
            }
        case .screenshot, .image, .audio, .video:
            break
        }
        return job
    }

    private static func text(_ row: SQLiteStatement) -> MeaningJob.Text {
        MeaningJob.Text(segment: row.int(0), kind: FilePassage.Kind(rawValue: row.text(1) ?? "") ?? .chunk,
                        location: row.isNull(2) ? nil : row.double(2), text: row.text(3) ?? "")
    }

    /// Stores a step's vectors if the file is still the one embedded — same
    /// size and date, and no other step stored meanwhile — and returns them
    /// as rows for `MeaningVectors`, in the order stored. Nil when dropped.
    /// A segment keeps its vector's `VectorCache` key, not the vector: the
    /// reader put it in the cache before this. Call inside a transaction.
    func storeMeaning(_ result: MeaningResult) throws -> [(row: MeaningVectors.Row, vector: Data)]? {
        let job = result.job
        var isCurrent = false
        var readTo = 0
        try db.query("SELECT size, mtime, vec_to, vec_state, read_to FROM files WHERE id = ?", [.int(job.id)]) { row in
            isCurrent = row.int(0) == job.size && abs(row.double(1) - job.mtime) < 0.001
                && abs(row.double(2) - job.vecTo) < 0.001 && row.text(3) == (job.isFirstStep ? "pending" : "partial")
            readTo = Int(row.int(4))
        }
        guard isCurrent else { return nil }

        var stored: [(row: MeaningVectors.Row, vector: Data)] = []
        for vector in result.vectors {
            guard let modality = vector.kind.modality, vector.vector.count == MeaningVectors.vectorBytes else { continue }
            let segment: Int64
            if let existing = vector.segment {
                try db.run("UPDATE segments SET vec_key = ?, later = ? WHERE id = ? AND file = ? AND vec_key IS NULL",
                           [.blob(vector.key.bytes), .int(job.isFirstStep ? 0 : 1), .int(existing), .int(job.id)])
                guard db.changes == 1 else { continue }
                segment = existing
            } else {
                try db.run("INSERT INTO segments(file, kind, loc, loc_end, vec_key, later) VALUES(?, ?, ?, ?, ?, ?)",
                           [.int(job.id), .text(vector.kind.rawValue), vector.location.map { .double($0) } ?? .null,
                            vector.end.map { .double($0) } ?? .null, .blob(vector.key.bytes),
                            .int(job.isFirstStep ? 0 : 1)])
                segment = db.lastInsertID
            }
            stored.append((MeaningVectors.Row(segment: segment, file: job.id, modality: modality,
                                              setsScale: job.isFirstStep), vector.vector))
        }

        let isComplete: Bool
        switch job.content {
        case _ where result.givesUp:
            isComplete = true
        case .pdf:
            isComplete = result.vecTo >= Double(readTo)
        case .document, .text, .code:
            // Data and logs have nothing left after their first step: their
            // later Passages are found by their words alone.
            var left = false
            if !FileContent.isDataOrLog(job.path) {
                try db.query("""
                    SELECT 1 FROM segments WHERE file = ? AND id > ? AND kind IN ('chunk', 'page') LIMIT 1
                    """, [.int(job.id), .int(Int64(result.vecTo))]) { _ in left = true }
            }
            isComplete = !left
        case .screenshot, .image:
            isComplete = true
        case .audio, .video:
            isComplete = result.isComplete
        }
        try db.run("UPDATE files SET vec_state = ?, vec_to = ? WHERE id = ?",
                   [.text(isComplete ? "done" : "partial"), .double(result.vecTo), .int(job.id)])
        if let detail = result.detail {
            try db.run("UPDATE files SET detail = ? WHERE id = ? AND detail IS NULL", [.text(detail), .int(job.id)])
        }
        if !stored.isEmpty { try setVectorRows(try vectorRows() + stored.count) }
        return stored
    }

    // MARK: Fingerprint and the vector files

    /// Makes `fingerprint` the one the vectors are under. Under another one,
    /// every vector goes and every file waits to be embedded again; returns
    /// whether that happened. A database with none yet just takes it.
    @discardableResult
    func adoptMeaningFingerprint(_ fingerprint: String = MeaningPass.fingerprint) throws -> Bool {
        var current: String?
        try db.query("SELECT value FROM meta WHERE key = 'meaning'") { current = $0.text(0) }
        guard current != fingerprint else { return false }
        let hadVectors = current != nil
        try db.transaction {
            if hadVectors { try dropVectors() }
            try db.run("""
                INSERT INTO meta(key, value) VALUES('meaning', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, [.text(fingerprint)])
        }
        return hadVectors
    }

    /// Makes `id` the `VectorCache` the vectors' keys point into. Another one
    /// was emptied or deleted since, so it has none of them: every vector
    /// goes, and every file is embedded again. Returns whether that happened.
    @discardableResult
    func adoptVectorCache(_ id: String) throws -> Bool {
        var current: String?
        try db.query("SELECT value FROM meta WHERE key = 'vector_cache'") { current = $0.text(0) }
        guard current != id else { return false }
        let hadVectors = current != nil
        try db.transaction {
            if hadVectors { try dropVectors() }
            try db.run("""
                INSERT INTO meta(key, value) VALUES('vector_cache', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, [.text(id)])
        }
        return hadVectors
    }

    /// Every vector, and the fingerprint and cache they were made under: what
    /// "Remove" in Settings does to the database.
    func removeMeaning() throws {
        try db.transaction {
            try dropVectors()
            try db.run("DELETE FROM meta WHERE key IN ('meaning', 'vector_cache')")
        }
    }

    private func dropVectors() throws {
        try db.run("DELETE FROM segments WHERE kind IN ('image', 'page_image', 'frame', 'audio')")
        try db.run("UPDATE segments SET vec_key = NULL, later = 0 WHERE vec_key IS NOT NULL")
        try db.run("UPDATE files SET vec_state = CASE WHEN content IS NULL THEN 'done' ELSE 'pending' END, vec_to = 0")
        try setVectorRows(0)
    }

    /// The rows `MeaningVectors` should hold: every vector stored since its
    /// files were last rebuilt.
    func vectorRows() throws -> Int {
        var rows = 0
        try db.query("SELECT value FROM meta WHERE key = 'vector_rows'") { rows = Int($0.text(0) ?? "") ?? 0 }
        return rows
    }

    func setVectorRows(_ rows: Int) throws {
        try db.run("""
            INSERT INTO meta(key, value) VALUES('vector_rows', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, [.text(String(rows))])
    }

    // MARK: The vector cache's prune

    /// Every key the index points into `VectorCache` with: what its prune
    /// keeps.
    func vectorKeys() throws -> [VectorCache.Key] {
        var keys: [VectorCache.Key] = []
        try db.query("SELECT DISTINCT vec_key FROM segments WHERE vec_key IS NOT NULL") { row in
            if let key = row.blob(0) { keys.append(VectorCache.Key(bytes: key)) }
        }
        return keys
    }

    /// Nothing waits in `sources` for either pass: every file's contents
    /// read and its vectors made, as far as each goes.
    func isCaughtUp(sources: [String]) throws -> Bool {
        var isWaiting = false
        try db.query("""
            SELECT 1 FROM files WHERE (state != 'done' OR vec_state != 'done')
                AND source IN (SELECT value FROM json_each(?)) LIMIT 1
            """, [.text(FileIndexReader.jsonList(sources))]) { _ in isWaiting = true }
        return !isWaiting
    }

    /// Writes `vectors` afresh from every vector the database points to in
    /// `cache`, in segment order, and records how many there are. A key the
    /// cache does not have is left out; `adoptVectorCache` is what catches a
    /// cache that lost them.
    @discardableResult
    func rebuild(_ vectors: MeaningVectors, from cache: VectorCache) throws -> Int {
        let count = try vectors.rebuild { emit in
            var batch: [(row: MeaningVectors.Row, key: VectorCache.Key)] = []
            func flush() throws {
                let found = try cache.vectors(for: batch.map(\.key))
                for item in batch {
                    if let vector = found[item.key] { try emit(item.row, vector) }
                }
                batch.removeAll(keepingCapacity: true)
            }
            try db.query("SELECT id, file, kind, later, vec_key FROM segments WHERE vec_key IS NOT NULL ORDER BY id") { row in
                guard let kind = FilePassage.Kind(rawValue: row.text(2) ?? ""), let modality = kind.modality,
                      let key = row.blob(4) else { return }
                batch.append((MeaningVectors.Row(segment: row.int(0), file: row.int(1), modality: modality,
                                                 setsScale: row.int(3) == 0), VectorCache.Key(bytes: key)))
                if batch.count == 1024 { try flush() }
            }
            try flush()
        }
        try setVectorRows(count)
        return count
    }
}
