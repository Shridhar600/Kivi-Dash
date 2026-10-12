import Foundation
import SQLite3
import Testing

@testable import KiviCore

@Suite("SQLite wrapper")
struct SQLiteTests {
    private func tempDB() throws -> (Database, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ks-test-\(UUID().uuidString).sqlite")
        return (try Database(path: url.path), url)
    }

    @Test("round-trips values including NULL and unicode")
    func roundTrip() throws {
        let (db, url) = try tempDB()
        defer { try? FileManager.default.removeItem(at: url) }

        try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER, s TEXT)")
        let insert = try db.prepare("INSERT INTO t (id, n, s) VALUES (?, ?, ?)")
        try insert.bind(Int64(1), at: 1).bind(Int64(42), at: 2).bind("Voice Memos — ünïcodé ✓", at: 3).run()
        try insert.reset()
        try insert.bind(Int64(2), at: 1).bindNil(at: 2).bindNil(at: 3).run()

        let rows = try db.query("SELECT id, n, s FROM t ORDER BY id") { row in
            (id: row.int64OrZero(0), n: row.int64(1), s: row.text(2))
        }

        #expect(rows.count == 2)
        #expect(rows[0].id == 1)
        #expect(rows[0].n == 42)
        #expect(rows[0].s == "Voice Memos — ünïcodé ✓")
        #expect(rows[1].n == nil, "NULL integer must survive as nil, not 0")
        #expect(rows[1].s == nil, "NULL text must survive as nil, not a crash")
    }

    @Test("read-only connection refuses writes")
    func readOnlyRefusesWrites() throws {
        let (db, url) = try tempDB()
        try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        try db.execute("INSERT INTO t DEFAULT VALUES")

        let reader = try Database(path: url.path, readOnly: true)
        #expect(reader.isReadOnly)
        #expect(try reader.scalarInt64("SELECT count(*) FROM t") == 1)
        #expect(throws: DatabaseError.self) {
            try reader.execute("INSERT INTO t DEFAULT VALUES")
        }
    }

    @Test("opening a missing file read-only fails instead of creating it")
    func readOnlyMissingFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ks-absent-\(UUID().uuidString).sqlite")
        #expect(throws: DatabaseError.self) { try Database(path: url.path, readOnly: true) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("transaction commits on success and rolls back on throw")
    func transactionSemantics() throws {
        let (db, url) = try tempDB()
        defer { try? FileManager.default.removeItem(at: url) }
        try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")

        try db.transaction {
            try db.execute("INSERT INTO t DEFAULT VALUES")
        }
        #expect(try db.scalarInt64("SELECT count(*) FROM t") == 1)

        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try db.transaction {
                try db.execute("INSERT INTO t DEFAULT VALUES")
                throw Boom()
            }
        }
        #expect(try db.scalarInt64("SELECT count(*) FROM t") == 1, "rollback must undo the insert")
    }

    @Test("a bad statement throws with the SQL in the message")
    func errorCarriesContext() throws {
        let (db, url) = try tempDB()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try db.execute("SELECT * FROM does_not_exist")
            Issue.record("expected a throw")
        } catch let error as DatabaseError {
            #expect(error.description.contains("does_not_exist"))
        }
    }
}
