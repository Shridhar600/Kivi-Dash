import Foundation
import Testing

@testable import KiviCore

@Suite("Our schema")
struct SchemaTests {
    private func freshDB() throws -> (Database, URL) {
        let url = Fixture.tempFile()
        return (try Database(path: url.path), url)
    }

    @Test("creates every table and stamps the version")
    func createsTables() throws {
        let (db, url) = try freshDB()
        defer { try? FileManager.default.removeItem(at: url) }
        try Schema.apply(to: db)

        #expect(try db.scalarInt64("PRAGMA user_version") == Int64(Schema.version))

        let tables = Set(
            try db.query("SELECT name FROM sqlite_master WHERE type='table'") { $0.text(0) ?? "" }
        )
        for expected in [
            "meta", "source_store", "ingest_run", "take", "daily_rollup",
            "daily_app_rollup", "counter_sample", "coverage_generation",
        ] {
            #expect(tables.contains(expected), "missing table \(expected)")
        }
    }

    @Test("is idempotent")
    func idempotent() throws {
        let (db, url) = try freshDB()
        defer { try? FileManager.default.removeItem(at: url) }
        try Schema.apply(to: db)
        try Schema.apply(to: db)
        #expect(try db.scalarInt64("PRAGMA user_version") == Int64(Schema.version))
    }

    /// The privacy promise, enforced as a test rather than a comment.
    ///
    /// If someone ever adds a column that could hold a transcript, this fails.
    @Test("no column anywhere could hold transcript text")
    func noTextColumns() throws {
        let (db, url) = try freshDB()
        defer { try? FileManager.default.removeItem(at: url) }
        try Schema.apply(to: db)

        let tables = try db.query("SELECT name FROM sqlite_master WHERE type='table'") {
            $0.text(0) ?? ""
        }
        var offenders: [String] = []
        for table in tables {
            let columns = try db.query("PRAGMA table_info(\(table))") { $0.text(1) ?? "" }
            for column in columns where Schema.forbiddenColumnNames.contains(column.lowercased()) {
                offenders.append("\(table).\(column)")
            }
        }
        #expect(offenders.isEmpty, "schema exposes text-capable columns: \(offenders)")
    }

    @Test("round-trips a numeric take row")
    func roundTripsTake() throws {
        let (db, url) = try freshDB()
        defer { try? FileManager.default.removeItem(at: url) }
        try Schema.apply(to: db)

        try db.execute(
            """
            INSERT INTO take (source_id, kivi_pk, taken_at, day_local, hour_local, mode,
                              bundle_id, bundle_key, duration_ms, word_count, char_count,
                              word_method, is_complete, speed_eligible, src_updated_at,
                              ingested_at, last_seen_run, retired_at)
            VALUES (1, 42, 1700000000, '2026-10-03', 2, 'dictate',
                    'dev.warp.Warp-Stable', 'dev.warp.warp-stable', 30000, 120, 640,
                    'icu_v1', 1, 1, 1700000000, 1700000000, 7, NULL)
            """
        )

        let rows = try db.query("SELECT day_local, bundle_key, word_count FROM take") {
            (day: $0.text(0) ?? "", app: $0.text(1) ?? "", words: $0.int64OrZero(2))
        }
        #expect(rows.count == 1)
        #expect(rows[0].day == "2026-10-03")
        #expect(rows[0].app == "dev.warp.warp-stable")
        #expect(rows[0].words == 120)
    }
}
