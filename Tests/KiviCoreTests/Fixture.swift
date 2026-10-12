import Foundation
import SQLite3

@testable import KiviCore

/// Builds throwaway SQLite fixtures in a temp directory.
///
/// Two shapes are needed:
/// * `makeKiviStore` — a database shaped like Kivi's, with a real
///   `ZCAPTURE` table.
/// * `makeWALStoreWithUncheckpointedRows` — the dangerous case: rows that exist
///   only in the write-ahead log, which a naive file copy or an `immutable=1`
///   open silently misses.
enum Fixture {
    static func tempFile(_ suffix: String = ".sqlite") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kivistats-test-\(UUID().uuidString)\(suffix)")
    }

    struct Take {
        var pk: Int64
        var createdAtAppleReference: Double = 812_918_638.51
        var durationSeconds: Double?
        var appBundleID: String? = "dev.warp.Warp-Stable"
        var mode: String = "dictate"
        var status: String = "complete"
        var text: String? = "hello there this is a test"
        var updatedAtAppleReference: Double?

        /// Memberwise init in declaration order, so call sites must pass
        /// arguments in that order.
        init(
            pk: Int64,
            createdAtAppleReference: Double = 812_918_638.51,
            durationSeconds: Double? = 30,
            appBundleID: String? = "dev.warp.Warp-Stable",
            mode: String = "dictate",
            status: String = "complete",
            text: String? = "hello there this is a test",
            updatedAtAppleReference: Double? = nil
        ) {
            self.pk = pk
            self.createdAtAppleReference = createdAtAppleReference
            self.durationSeconds = durationSeconds
            self.appBundleID = appBundleID
            self.mode = mode
            self.status = status
            self.text = text
            self.updatedAtAppleReference = updatedAtAppleReference
        }
    }

    static let captureDDL = """
        CREATE TABLE ZCAPTURE (
            Z_PK INTEGER PRIMARY KEY,
            ZARCHIVED INTEGER,
            ZCREATEDAT TIMESTAMP,
            ZDURATIONSECONDS FLOAT,
            ZAPPBUNDLEID VARCHAR,
            ZFORMATTEDTEXT VARCHAR,
            ZLANGUAGEHINT VARCHAR,
            ZMODE VARCHAR,
            ZPINNED INTEGER,
            ZPENDINGSYNC INTEGER,
            ZRAWTEXT VARCHAR,
            ZSTATUS VARCHAR,
            ZUPDATEDAT TIMESTAMP,
            ZID BLOB
        )
        """

    /// A database shaped like Kivi's, with rows committed normally.
    @discardableResult
    static func makeKiviStore(_ takes: [Take], extraColumnsSQL: String = "") throws -> URL {
        let url = tempFile()
        let db = try Database(path: url.path)
        try db.execute(captureDDL)
        if !extraColumnsSQL.isEmpty { try db.execute(extraColumnsSQL) }
        try insert(takes, into: db)
        return url
    }

    static func insert(_ takes: [Take], into db: Database) throws {
        let statement = try db.prepare(
            """
            INSERT INTO ZCAPTURE
                (Z_PK, ZCREATEDAT, ZDURATIONSECONDS, ZAPPBUNDLEID, ZMODE,
                 ZSTATUS, ZFORMATTEDTEXT, ZRAWTEXT, ZUPDATEDAT)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        for take in takes {
            try statement.reset()
            try statement.bind(take.pk, at: 1)
            try statement.bind(take.createdAtAppleReference, at: 2)
            try statement.bindIfPresent(take.durationSeconds, at: 3)
            try statement.bind(take.appBundleID, at: 4)
            try statement.bind(take.mode, at: 5)
            try statement.bind(take.status, at: 6)
            try statement.bind(take.text, at: 7)
            try statement.bind(take.text, at: 8)
            try statement.bind(take.updatedAtAppleReference ?? take.createdAtAppleReference, at: 9)
            try statement.run()
        }
    }

    /// A WAL-mode store whose rows have **not** been checkpointed.
    ///
    /// Returns the open `Database` as well: while the writing connection is
    /// alive with `wal_autocheckpoint=0`, the rows live in `-wal` and not in the
    /// main file, which is the exact condition that makes a naive file copy
    /// silently lose data. The caller must hold the returned handle until it is
    /// done with the store.
    static func makeWALStoreWithUncheckpointedRows(_ takes: [Take]) throws -> (url: URL, writer: Database) {
        let url = tempFile()
        let writer = try Database(path: url.path)
        try writer.execute("PRAGMA journal_mode=WAL")
        try writer.execute("PRAGMA wal_autocheckpoint=0")
        try writer.execute(captureDDL)
        try insert(takes, into: writer)
        return (url, writer)
    }

    /// What a naive "copy the main file" snapshot would produce.
    static func naiveMainFileCopy(of url: URL) throws -> URL {
        let copy = tempFile()
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    static func rowCount(at path: String) throws -> Int64 {
        let db = try Database(path: path, readOnly: true)
        return try db.scalarInt64("SELECT count(*) FROM ZCAPTURE") ?? -1
    }

    static func rowCount(at url: URL) throws -> Int64 {
        try rowCount(at: url.path)
    }

    /// Counts rows opening read-write.
    ///
    /// Needed for a main-file-only copy: it still declares WAL mode, so a
    /// read-only open fails `SQLITE_CANTOPEN` — the very trap that makes naive
    /// copying unusable.
    static func rowCountWritable(at url: URL) throws -> Int64 {
        let db = try Database(path: url.path, readOnly: false)
        let hasTable =
            try db.scalarInt64(
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='ZCAPTURE'"
            ) ?? 0
        guard hasTable > 0 else { return -1 }
        return try db.scalarInt64("SELECT count(*) FROM ZCAPTURE") ?? -1
    }
}
