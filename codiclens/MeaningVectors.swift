// Block-wise float16 scoring adapted from DigUp's Searcher.score and VectorStorage
// (https://github.com/ARahim3/DigUp), MIT licence — see docs/licenses/digup/LICENSE.
import Accelerate
import Foundation

/// Every vector in the File Index, laid out for a search to score all of them:
/// two files beside the database, appended to as vectors land.
///
/// - `FileIndex.vectors` is the vectors, 768 float16s a row, back to back. A
///   search maps it read-only and scores it in place, a block of rows at a
///   time turned into float32 first (`Snapshot.scores`). Mapped, not read: the
///   pages are the file's, clean, so the system takes them back when memory is
///   short and an idle app holds none of them dirty — 300,000 vectors are
///   460 MB. Turning search by meaning off unmaps it (`close`).
/// - `FileIndex.vector-rows` is a 24-byte record per row: its segment, its
///   file (0 once removed), its modality and whether it sets the scale. Read
///   whole at `open` (7 MB for 300,000).
///
/// The database's `segments.vec_key` and `VectorCache` are the truth; these
/// are derived, what scoring reads. Vectors are written to the cache and the
/// database first and appended here once that commits, and
/// `meta.vector_rows` counts the rows that should be here, so a crash in
/// between is caught at the next `open`, which then asks for a `rebuild` from
/// the two. Rows of files that change or go are marked
/// removed in place (`remove(files:)`) rather than rewritten; once a quarter
/// of them are, `needsCompaction` asks for a rebuild too. Nothing reloads the
/// whole matrix as vectors land.
///
/// The writing methods are called on the File Index's queue. `snapshot()` is
/// safe from any thread: what it hands back stays valid while the files grow.
nonisolated final class MeaningVectors: @unchecked Sendable {
    static let vectorBytes = EmbeddingVector.dimension * 2
    static let recordBytes = 24
    /// Rows converted to float32 at a time: 3 MB, which stays in cache.
    static let blockRows = 1024

    struct Row: Equatable, Sendable {
        var segment: Int64
        var file: Int64
        var modality: MeaningModality
        var setsScale: Bool
    }

    let vectorsURL: URL
    let rowsURL: URL

    private let lock = NSLock()
    private var rows = Rows()
    private var mapping: Mapping?
    private var vectorsFile: Int32 = -1
    private var rowsFile: Int32 = -1

    /// The rows as arrays, the way scoring and ranking walk them.
    struct Rows: Sendable {
        var segment: [Int64] = []
        var file: [Int64] = []
        var modality: [UInt8] = []
        var setsScale: [Bool] = []
        var alive: [Bool] = []
        var ofFile: [Int64: [Int]] = [:]
        var removed = 0
        /// The same, as the masks `MeaningRanking.zScores` multiplies by.
        var masks = MeaningRanking.Masks()

        var count: Int { segment.count }

        mutating func append(_ row: Row) {
            let index = segment.count
            let isAlive = row.file != 0
            segment.append(row.segment)
            file.append(row.file)
            modality.append(row.modality.rawValue)
            setsScale.append(row.setsScale)
            alive.append(isAlive)
            masks.append(modality: row.modality, setsScale: row.setsScale, alive: isAlive)
            if isAlive { ofFile[row.file, default: []].append(index) } else { removed += 1 }
        }

        mutating func remove(_ index: Int) {
            guard alive[index] else { return }
            alive[index] = false
            file[index] = 0
            removed += 1
            masks.remove(index)
        }
    }

    /// Beside the database: `FileIndex.vectors` and `FileIndex.vector-rows`.
    init(databaseURL: URL) {
        let base = databaseURL.deletingPathExtension()
        vectorsURL = base.appendingPathExtension("vectors")
        rowsURL = URL(fileURLWithPath: base.path + ".vector-rows")
    }

    deinit {
        closeFiles()
    }

    // MARK: - Opening, closing, rebuilding

    /// Opens the files if they hold exactly `expectedRows` rows, as the
    /// database says they should. False when they do not, or are not there;
    /// then a `rebuild` is due.
    @discardableResult
    func open(expectedRows: Int) -> Bool {
        lock.withLock {
            closeFiles()
            rows = Rows()
            mapping = nil
            guard let records = try? Data(contentsOf: rowsURL),
                  records.count == expectedRows * Self.recordBytes,
                  let size = try? FileManager.default.attributesOfItem(atPath: vectorsURL.path)[.size] as? Int,
                  size == expectedRows * Self.vectorBytes
            else { return false }
            records.withUnsafeBytes { raw in
                for index in 0..<expectedRows {
                    rows.append(Self.decode(raw, at: index * Self.recordBytes))
                }
            }
            guard openFiles() else { return false }
            mapping = Mapping(fileDescriptor: vectorsFile, bytes: size)
            return true
        }
    }

    /// Writes both files afresh from `source`, which hands over every vector
    /// in segment order, and opens them. Returns how many rows there are.
    @discardableResult
    func rebuild(_ source: ((Row, Data) throws -> Void) throws -> Void) throws -> Int {
        let vectorsTemp = vectorsURL.appendingPathExtension("new")
        let rowsTemp = rowsURL.appendingPathExtension("new")
        FileManager.default.createFile(atPath: vectorsTemp.path, contents: nil)
        FileManager.default.createFile(atPath: rowsTemp.path, contents: nil)
        let vectors = try FileHandle(forWritingTo: vectorsTemp)
        let records = try FileHandle(forWritingTo: rowsTemp)
        var count = 0
        var vectorBuffer = Data()
        var recordBuffer = Data()
        func flush() throws {
            try vectors.write(contentsOf: vectorBuffer)
            try records.write(contentsOf: recordBuffer)
            vectorBuffer.removeAll(keepingCapacity: true)
            recordBuffer.removeAll(keepingCapacity: true)
        }
        do {
            try source { row, vector in
                guard vector.count == Self.vectorBytes else { return }
                vectorBuffer.append(vector)
                recordBuffer.append(Self.encode(row))
                count += 1
                if count.isMultiple(of: 4096) { try flush() }
            }
            try flush()
            try vectors.close()
            try records.close()
        } catch {
            try? vectors.close()
            try? records.close()
            try? FileManager.default.removeItem(at: vectorsTemp)
            try? FileManager.default.removeItem(at: rowsTemp)
            throw error
        }
        lock.withLock { closeFiles() }
        for (file, temp) in [(vectorsURL, vectorsTemp), (rowsURL, rowsTemp)] {
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: temp, to: file)
        }
        guard open(expectedRows: count) else {
            throw SQLiteConnection.Failure(message: "the vector files did not read back")
        }
        return count
    }

    /// Unmaps the vectors and forgets the rows: what turning search by
    /// meaning off gives back. The files stay for the next `open`.
    func close() {
        lock.withLock {
            closeFiles()
            rows = Rows()
            mapping = nil
        }
    }

    /// Closes and deletes both files.
    func deleteFiles() {
        close()
        try? FileManager.default.removeItem(at: vectorsURL)
        try? FileManager.default.removeItem(at: rowsURL)
    }

    var isOpen: Bool { lock.withLock { vectorsFile >= 0 } }

    // MARK: - Keeping up

    /// Rows whose vectors the database has just committed: written to the
    /// end of both files, then mapped. Nothing already there moves.
    func append(_ items: [(row: Row, vector: Data)]) throws {
        guard !items.isEmpty else { return }
        try lock.withLock {
            guard vectorsFile >= 0, rowsFile >= 0 else { return }
            var vectors = Data(capacity: items.count * Self.vectorBytes)
            var records = Data(capacity: items.count * Self.recordBytes)
            for item in items where item.vector.count == Self.vectorBytes {
                vectors.append(item.vector)
                records.append(Self.encode(item.row))
            }
            let count = rows.count
            // Vectors first: a crash between the two leaves rows that `open`
            // counts as missing, never a row pointing past the vectors.
            try Self.write(vectors, to: vectorsFile, at: count * Self.vectorBytes)
            try Self.write(records, to: rowsFile, at: count * Self.recordBytes)
            for item in items where item.vector.count == Self.vectorBytes { rows.append(item.row) }
            // A new mapping over the longer file; one a search still holds
            // stays valid until it lets go.
            mapping = Mapping(fileDescriptor: vectorsFile, bytes: rows.count * Self.vectorBytes)
        }
    }

    /// Marks every row of `files` removed, in memory and on disk: their
    /// segments are gone from the database.
    func remove(files: [Int64]) {
        lock.withLock {
            var zero: Int64 = 0
            for file in files {
                guard let indices = rows.ofFile.removeValue(forKey: file) else { continue }
                for index in indices where rows.alive[index] {
                    rows.remove(index)
                    if rowsFile >= 0 { _ = pwrite(rowsFile, &zero, 8, off_t(index * Self.recordBytes + 8)) }
                }
            }
        }
    }

    /// A quarter of the rows are removed ones: time for a `rebuild`.
    var needsCompaction: Bool {
        lock.withLock { rows.removed > max(1000, rows.count / 4) }
    }

    /// Rows still in use.
    var liveCount: Int {
        lock.withLock { rows.count - rows.removed }
    }

    // MARK: - Searching

    /// What a search scores, taken under the lock and used without it.
    struct Snapshot: @unchecked Sendable {
        let rows: Rows
        fileprivate let mapping: Mapping

        var count: Int { rows.count }

        /// The cosine of `query` (768 floats, normalized) with every row: a
        /// matrix–vector product over the float16 rows, a block at a time
        /// turned into float32, split across the cores.
        func scores(_ query: [Float]) -> [Float] {
            let count = rows.count
            var scores = [Float](repeating: 0, count: count)
            guard count > 0, query.count == EmbeddingVector.dimension else { return scores }
            let dimension = EmbeddingVector.dimension
            let halves = mapping.base
            let parts = max(1, min(ProcessInfo.processInfo.activeProcessorCount, count / MeaningVectors.blockRows))
            scores.withUnsafeMutableBufferPointer { out in
                nonisolated(unsafe) let out = out.baseAddress!
                query.withUnsafeBufferPointer { query in
                    nonisolated(unsafe) let query = query.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: parts) { part in
                        let end = count * (part + 1) / parts
                        var row = count * part / parts
                        let block = UnsafeMutablePointer<Float>.allocate(capacity: MeaningVectors.blockRows * dimension)
                        defer { block.deallocate() }
                        while row < end {
                            let rowsHere = min(MeaningVectors.blockRows, end - row)
                            var from = vImage_Buffer(
                                data: UnsafeMutableRawPointer(mutating: halves + row * MeaningVectors.vectorBytes),
                                height: 1, width: vImagePixelCount(rowsHere * dimension), rowBytes: rowsHere * dimension * 2
                            )
                            var to = vImage_Buffer(
                                data: block, height: 1, width: vImagePixelCount(rowsHere * dimension),
                                rowBytes: rowsHere * dimension * 4
                            )
                            vImageConvert_Planar16FtoPlanarF(&from, &to, vImage_Flags(kvImageNoFlags))
                            // (rows × 768) · (768 × 1)
                            vDSP_mmul(block, 1, query, 1, out + row, 1,
                                      vDSP_Length(rowsHere), 1, vDSP_Length(dimension))
                            row += rowsHere
                        }
                    }
                }
            }
            return scores
        }
    }

    /// Nil when there is nothing to score: closed, or no vectors yet.
    func snapshot() -> Snapshot? {
        lock.withLock {
            guard let mapping, rows.count > 0 else { return nil }
            return Snapshot(rows: rows, mapping: mapping)
        }
    }

    // MARK: - Files

    /// Called with the lock held.
    private func openFiles() -> Bool {
        vectorsFile = Darwin.open(vectorsURL.path, O_RDWR | O_CLOEXEC)
        rowsFile = Darwin.open(rowsURL.path, O_RDWR | O_CLOEXEC)
        guard vectorsFile >= 0, rowsFile >= 0 else {
            closeFiles()
            return false
        }
        return true
    }

    /// Called with the lock held, or from `deinit`.
    private func closeFiles() {
        if vectorsFile >= 0 { Darwin.close(vectorsFile) }
        if rowsFile >= 0 { Darwin.close(rowsFile) }
        vectorsFile = -1
        rowsFile = -1
    }

    private static func write(_ data: Data, to file: Int32, at offset: Int) throws {
        let written = data.withUnsafeBytes { pwrite(file, $0.baseAddress, $0.count, off_t(offset)) }
        guard written == data.count else {
            throw SQLiteConnection.Failure(message: "can't write the vector files: \(String(cString: strerror(errno)))")
        }
    }

    /// segment, file (little-endian Int64s), modality, setsScale, 6 bytes of
    /// padding.
    private static func encode(_ row: Row) -> Data {
        var data = Data(count: recordBytes)
        data.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: row.segment.littleEndian, toByteOffset: 0, as: Int64.self)
            raw.storeBytes(of: row.file.littleEndian, toByteOffset: 8, as: Int64.self)
            raw.storeBytes(of: row.modality.rawValue, toByteOffset: 16, as: UInt8.self)
            raw.storeBytes(of: row.setsScale ? 1 : 0, toByteOffset: 17, as: UInt8.self)
        }
        return data
    }

    private static func decode(_ raw: UnsafeRawBufferPointer, at offset: Int) -> Row {
        Row(
            segment: Int64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int64.self)),
            file: Int64(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 8, as: Int64.self)),
            modality: MeaningModality(rawValue: raw.load(fromByteOffset: offset + 16, as: UInt8.self)) ?? .text,
            setsScale: raw.load(fromByteOffset: offset + 17, as: UInt8.self) != 0
        )
    }
}

/// The vectors file mapped read-only, unmapped when the last holder lets go.
nonisolated private final class Mapping: @unchecked Sendable {
    let base: UnsafePointer<UInt8>
    private let raw: UnsafeMutableRawPointer
    private let bytes: Int

    init?(fileDescriptor: Int32, bytes: Int) {
        guard bytes > 0, fileDescriptor >= 0 else { return nil }
        let raw = mmap(nil, bytes, PROT_READ, MAP_SHARED, fileDescriptor, 0)
        guard let raw, raw != MAP_FAILED else { return nil }
        self.raw = raw
        self.bytes = bytes
        base = UnsafePointer(raw.assumingMemoryBound(to: UInt8.self))
    }

    deinit {
        munmap(raw, bytes)
    }
}
