// Adapted from DigUp's Database.swift (https://github.com/ARahim3/DigUp), MIT licence — see docs/licenses/digup/LICENSE.
import Foundation
import SQLite3

/// A thin wrapper over the system SQLite (3.51 on macOS 26, FTS5 built in).
/// One connection, and it does not lock: whoever owns one decides which
/// thread may use it. The File Index's writer keeps its connection on one
/// serial queue; its reader guards its own with a lock.
nonisolated final class SQLiteConnection {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    fileprivate let handle: OpaquePointer
    private var statements: [String: SQLiteStatement] = [:]

    /// Opens (and creates) the database at `path` in WAL mode, so readers on
    /// other connections — later, in another process — never wait on the
    /// writer and the writer never waits on them.
    ///
    /// `pageSize` applies only to a database this creates: once WAL is on,
    /// SQLite keeps the size it has.
    init(path: String, pageSize: Int? = nil) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(db)
            throw Failure(message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        if let pageSize { try execute("PRAGMA page_size = \(pageSize)") }
        try execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;")
    }

    /// Statements go first, while the connection is still whole: closing
    /// under live ones leaves a "zombie" connection, and FTS5 tables
    /// finalised against one log API misuse.
    deinit {
        statements.removeAll()
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw Failure(message: "\(message) (in: \(sql.prefix(120)))")
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(self, sql)
    }

    /// Runs `sql` with `values` bound and calls `row` for each result row.
    ///
    /// The statement is prepared once per connection and kept: a crawl runs
    /// the same handful of statements a hundred thousand times, and preparing
    /// each time was most of its cost. So `row` must not run the same `sql`
    /// again from inside itself.
    func query(_ sql: String, _ values: [SQLiteValue] = [], row: (SQLiteStatement) throws -> Void = { _ in }) throws {
        let statement: SQLiteStatement
        if let cached = statements[sql] {
            statement = cached
        } else {
            statement = try prepare(sql)
            statements[sql] = statement
        }
        try statement.run(values, row: row)
    }

    func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
        try query(sql, values)
    }

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }
    fileprivate var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }
}

nonisolated enum SQLiteValue {
    case int(Int64), double(Double), text(String), blob(Data), null
}

/// A prepared statement. Reusable: `run` resets it first, so a hot query —
/// the reader's search — is prepared once and not per keystroke.
nonisolated final class SQLiteStatement {
    private let statement: OpaquePointer
    // Unowned: the connection caches its statements, and a strong reference
    // back would keep both alive for ever. `sqlite3_close_v2` outlives
    // unfinalised statements by design.
    private unowned let connection: SQLiteConnection

    fileprivate init(_ connection: SQLiteConnection, _ sql: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteConnection.Failure(message: "\(connection.errorMessage) (in: \(sql.prefix(160)))")
        }
        self.statement = statement
        self.connection = connection
    }

    deinit { sqlite3_finalize(statement) }

    func run(_ values: [SQLiteValue] = [], row: (SQLiteStatement) throws -> Void = { _ in }) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        try bind(values)
        defer { sqlite3_reset(statement) }
        while try step() { try row(self) }
    }

    private func bind(_ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .int(let number): status = sqlite3_bind_int64(statement, index, number)
            case .double(let number): status = sqlite3_bind_double(statement, index, number)
            case .text(let text): status = sqlite3_bind_text(statement, index, text, -1, transient)
            case .blob(let data):
                status = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)
                }
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw SQLiteConnection.Failure(message: connection.errorMessage) }
        }
    }

    private func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteConnection.Failure(message: connection.errorMessage)
        }
    }

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

    func text(_ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    /// A blob column's bytes, copied; nil for NULL. An empty blob is empty
    /// data, not nil.
    func blob(_ column: Int32) -> Data? {
        guard !isNull(column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

/// SQLITE_TRANSIENT: SQLite copies bound text and blobs, so Swift's temporary
/// buffers are safe to pass.
nonisolated private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
