import Foundation
import SQLite3

/// Errors surfaced by the wrapper. Always carries the SQL context so a failure
/// is actionable from a menu bar app with no visible window.
public struct DatabaseError: Error, CustomStringConvertible, Sendable {
    public let context: String
    public let code: Int32

    init(context: String, code: Int32) {
        self.context = context
        self.code = code
    }

    /// For failures that happen in Foundation rather than in SQLite itself, where
    /// there is no connection to take a real code from.
    static func cantOpen(_ context: String) -> DatabaseError {
        DatabaseError(context: context, code: SQLITE_CANTOPEN)
    }

    public var description: String { "\(context) [sqlite \(code)]" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A value that can be bound to a statement parameter.
public enum SQLValue: Sendable {
    case int64(Int64)
    case double(Double)
    case text(String?)
    case null
}

/// A read cursor over the current row. All accessors return optionals: this
/// database is somebody else's, and third-party schemas are full of NULLs.
public struct Row {
    fileprivate let stmt: OpaquePointer

    public func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(stmt, index) == SQLITE_NULL
    }

    public func int64(_ index: Int32) -> Int64? {
        guard !isNull(index) else { return nil }
        return sqlite3_column_int64(stmt, index)
    }

    /// True when the column holds a non-finite REAL. Used to reject rows rather
    /// than coerce them.
    public func isNonFinite(_ index: Int32) -> Bool {
        guard !isNull(index) else { return false }
        return !sqlite3_column_double(stmt, index).isFinite
    }

    public func int64OrZero(_ index: Int32) -> Int64 {
        int64(index) ?? 0
    }

    /// Returns nil for NULL *and* for non-finite values.
    ///
    /// A third-party REAL column can legitimately contain `Inf` or `NaN`
    /// (SQLite stores them happily). Converting those to `Int64` is a runtime
    /// trap, not a throwable error, so they must never reach the caller.
    public func double(_ index: Int32) -> Double? {
        guard !isNull(index) else { return nil }
        let value = sqlite3_column_double(stmt, index)
        return value.isFinite ? value : nil
    }

    public func text(_ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: raw)
    }
}

/// A prepared statement. Must be finalized; wrap in `defer` at every call site.
public final class Statement {
    fileprivate let handle: OpaquePointer
    private let sql: String

    fileprivate init(handle: OpaquePointer, sql: String) {
        self.handle = handle
        self.sql = sql
    }

    deinit { sqlite3_finalize(handle) }

    @discardableResult
    public func bind(_ value: Int64, at index: Int32) throws -> Statement {
        try check(sqlite3_bind_int64(handle, index, value), "bind int64")
        return self
    }

    @discardableResult
    public func bind(_ value: Double, at index: Int32) throws -> Statement {
        try check(sqlite3_bind_double(handle, index, value), "bind double")
        return self
    }

    /// Optional overloads live under a distinct name: an implicit `Int64` → `Int64?`
    /// promotion would make every non-optional call ambiguous.
    @discardableResult
    public func bindIfPresent(_ value: Int64?, at index: Int32) throws -> Statement {
        guard let value else { return try bindNil(at: index) }
        return try bind(value, at: index)
    }

    @discardableResult
    public func bindIfPresent(_ value: Double?, at index: Int32) throws -> Statement {
        guard let value else { return try bindNil(at: index) }
        return try bind(value, at: index)
    }

    @discardableResult
    public func bindIfPresent(_ value: String?, at index: Int32) throws -> Statement {
        try bind(value, at: index)
    }

    @discardableResult
    public func bindNil(at index: Int32) throws -> Statement {
        try check(sqlite3_bind_null(handle, index), "bind null")
        return self
    }

    @discardableResult
    public func bind(_ value: String?, at index: Int32) throws -> Statement {
        let rc: Int32
        if let value {
            rc = sqlite3_bind_text(handle, index, value, -1, SQLITE_TRANSIENT)
        } else {
            rc = sqlite3_bind_null(handle, index)
        }
        try check(rc, "bind text")
        return self
    }

    /// Binds positional values, 1-based, in array order.
    public func bind(_ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int64(let v): try bind(v, at: index)
            case .double(let v): try bind(v, at: index)
            case .text(let v): try bind(v, at: index)
            case .null: try bindNil(at: index)
            }
        }
    }

    /// Advances the cursor. Returns false when the result set is exhausted.
    public func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw error("step", rc)
        }
    }

    /// Runs the statement to completion, discarding rows.
    public func run() throws {
        while try step() {}
    }

    /// Returns the statement to its initial state, including clearing bindings,
    /// so it can be re-executed with new parameters.
    public func reset() throws {
        try check(sqlite3_reset(handle), "reset")
        sqlite3_clear_bindings(handle)
    }

    public var row: Row { Row(stmt: handle) }

    private func error(_ context: String, _ rc: Int32) -> DatabaseError {
        DatabaseError(context: "\(context): \(sql)", code: rc)
    }

    private func check(_ rc: Int32, _ context: String) throws {
        guard rc != SQLITE_OK else { return }
        throw error(context, rc)
    }
}

/// A SQLite connection.
///
/// Deliberately a plain class confined to whoever opened it (in practice an
/// actor). It is NOT `Sendable`, so the compiler prevents cross-thread use
/// rather than relying on discipline.
public final class Database {
    private let handle: OpaquePointer
    public let path: String
    public let isReadOnly: Bool

    /// Opens a connection. `readOnly` maps to `SQLITE_OPEN_READONLY` and nothing
    /// else — used for the source app's store, which must never be written to.
    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        self.isReadOnly = readOnly

        let flags =
            readOnly
            ? SQLITE_OPEN_READONLY
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE

        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close_v2(handle) }
            throw DatabaseError(context: "open \(path): \(message)", code: rc)
        }
        self.handle = handle

        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { sqlite3_close_v2(handle) }

    public func execute(_ sql: String) throws {
        let statement = try prepare(sql)
        try statement.run()
    }

    /// Executes a parameterised statement. Prefer this over `execute(_:)` when
    /// there are `?` placeholders — an unbound parameter is silently NULL.
    public func execute(_ sql: String, bindings: [SQLValue]) throws {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        try statement.run()
    }

    public func prepare(_ sql: String) throws -> Statement {
        var handle: OpaquePointer?
        let rc = sqlite3_prepare_v2(self.handle, sql, -1, &handle, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = String(cString: sqlite3_errmsg(self.handle))
            throw DatabaseError(context: "prepare: \(message) — \(sql)", code: rc)
        }
        return Statement(handle: handle, sql: sql)
    }

    /// Maps every row of `sql` into an array.
    public func query<T>(_ sql: String, _ map: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        var results: [T] = []
        while try statement.step() {
            results.append(try map(statement.row))
        }
        return results
    }

    /// Maps every row of a parameterised query.
    ///
    /// Prefer this over hand-rolling binds: an unbound `?` is silently treated
    /// as NULL by SQLite, which turns a typo into a query that quietly returns
    /// the wrong (usually empty) result instead of failing. Making the bindings
    /// a required argument removes that failure mode.
    public func query<T>(
        _ sql: String,
        bindings: [SQLValue],
        _ map: (Row) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        var results: [T] = []
        while try statement.step() {
            results.append(try map(statement.row))
        }
        return results
    }

    /// Convenience for `SELECT count(*)`-shaped queries.
    public func scalarInt64(_ sql: String) throws -> Int64? {
        try query(sql) { $0.int64(0) }.first ?? nil
    }

    public func scalarString(_ sql: String) throws -> String? {
        try query(sql) { $0.text(0) }.first ?? nil
    }

    /// Wraps `body` in `BEGIN IMMEDIATE` / `COMMIT`, rolling back on any throw.
    ///
    /// Takes a closure rather than being inlined so that a multi-statement write
    /// path — ingest especially — is all-or-nothing. Facts and rollups must never
    /// disagree.
    public func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            // Best effort: a failed rollback must not mask the original error.
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Copies this database into `destination` using the online backup API.
    ///
    /// This is the ONLY safe way to read another app's live SQLite file: it
    /// yields a point-in-time consistent copy that includes committed WAL
    /// content. Copying the file, or opening it `immutable=1`, silently loses
    /// everything not yet checkpointed.
    ///
    /// `destination` must be read-write; the copy inherits this database's
    /// journal mode, which may leave it un-openable read-only until cleared.
    public func backup(to destination: Database) throws {
        // The SOURCE may be read-only — for a third-party store it always is.
        // Only the destination needs write access.
        guard !destination.isReadOnly else {
            throw DatabaseError(context: "backup destination must be read-write", code: SQLITE_MISUSE)
        }
        guard let backup = sqlite3_backup_init(destination.handle, "main", handle, "main") else {
            throw DatabaseError(context: "backup_init", code: sqlite3_errcode(handle))
        }
        let rc = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard rc == SQLITE_DONE || rc == SQLITE_OK else {
            throw DatabaseError(context: "backup_step", code: rc)
        }
        guard finish == SQLITE_OK else {
            throw DatabaseError(context: "backup_finish", code: finish)
        }
    }

    /// Reopens a freshly-made snapshot so it can be read read-only.
    ///
    /// A backup inherits the source's WAL journal mode; a read-only open of a
    /// WAL database with no `-shm` fails `SQLITE_CANTOPEN`. Clearing the journal
    /// mode is what makes the snapshot independently readable.
    public func clearJournalModeForSnapshot() throws {
        try execute("PRAGMA journal_mode=delete;")
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Rows changed by the most recent statement. Used to count retirements
    /// without a second query.
    public var changes: Int32 { sqlite3_changes(handle) }
}
