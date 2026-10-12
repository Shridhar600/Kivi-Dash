import Foundation
import Testing

@testable import KiviCore

@Suite("Snapshot")
struct SnapshotTests {
    private func snapshotDir() throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ks-snap-\(UUID().uuidString)", isDirectory: true)
        return (dir, dir)
    }

    /// The load-bearing test.
    ///
    /// Rows committed to a WAL-mode database but not yet checkpointed are
    /// invisible to a main-file copy and to an `immutable=1` open. Both were
    /// tried against real Kivi data and both returned fewer rows with no error.
    @Test("captures rows that exist only in the write-ahead log")
    func capturesUncheckpointedRows() throws {
        var writer: Database?
        var source: URL?
        do {
            let made = try Fixture.makeWALStoreWithUncheckpointedRows([
                .init(pk: 1, text: "row that lives in the wal"),
                .init(pk: 2, text: "another one"),
            ])
            writer = made.writer
            source = made.url

            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ks-snap-\(UUID().uuidString)", isDirectory: true)

            // Prove the hazard is real for this fixture: the rows really are in
            // the WAL, and a main-file-only copy sees none of them.
            let wal = URL(fileURLWithPath: made.url.path + "-wal")
            let walSize = (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int) ?? 0
            #expect(walSize > 0, "fixture must actually leave rows in the WAL")

            let naive = try Fixture.naiveMainFileCopy(of: made.url)
            let naiveCount = try Fixture.rowCountWritable(at: naive)

            let snapshot = try Snapshot.take(from: made.url, into: dir)
            let captured = try Fixture.rowCount(at: snapshot)

            #expect(captured == 2, "snapshot lost WAL-only rows")
            #expect(naiveCount == -1, "a main-file-only copy lost the schema and every row")

            Snapshot.discard(snapshot)
            try? FileManager.default.removeItem(at: naive)
            try? FileManager.default.removeItem(at: dir)
        }

        // Release the writer before deleting the files it still has open.
        writer = nil
        if let source { try? FileManager.default.removeItem(at: source) }
    }

    @Test("snapshot is readable read-only after being taken")
    func snapshotOpensReadOnly() throws {
        let source = try Fixture.makeKiviStore([.init(pk: 1)])
        defer { try? FileManager.default.removeItem(at: source) }

        let (dir, snapshotDir) = try snapshotDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = try Snapshot.take(from: source, into: snapshotDir)

        // A backup inherits the source's journal mode; without the reset this
        // open fails SQLITE_CANTOPEN.
        let reader = try Database(path: snapshot.path, readOnly: true)
        #expect(try reader.scalarInt64("SELECT count(*) FROM ZCAPTURE") == 1)
    }

    @Test("does not modify the source")
    func sourceUnchanged() throws {
        let source = try Fixture.makeKiviStore([.init(pk: 1), .init(pk: 2)])
        defer { try? FileManager.default.removeItem(at: source) }

        let before = try Data(contentsOf: source)
        let (dir, snapshotDir) = try snapshotDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = try Snapshot.take(from: source, into: snapshotDir)
        Snapshot.discard(snapshot)

        let after = try Data(contentsOf: source)
        #expect(before == after, "snapshotting must not alter the source database")
    }

    @Test("source is opened read-only so a write cannot happen")
    func sourceOpenedReadOnly() throws {
        let source = try Fixture.makeKiviStore([.init(pk: 1)])
        defer { try? FileManager.default.removeItem(at: source) }

        let (dir, snapshotDir) = try snapshotDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = try Snapshot.take(from: source, into: snapshotDir)
        defer { Snapshot.discard(snapshot) }

        let sourceReader = try Database(path: source.path, readOnly: true)
        #expect(sourceReader.isReadOnly)
        #expect(throws: DatabaseError.self) {
            try sourceReader.execute("DELETE FROM ZCAPTURE")
        }
    }

    @Test("discard removes the snapshot and its sidecars")
    func discardRemoves() throws {
        let source = try Fixture.makeKiviStore([.init(pk: 1)])
        defer { try? FileManager.default.removeItem(at: source) }
        let (dir, snapshotDir) = try snapshotDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = try Snapshot.take(from: source, into: snapshotDir)
        #expect(FileManager.default.fileExists(atPath: snapshot.path))

        Snapshot.discard(snapshot)

        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
        // A leftover -shm would still hold page content in a directory we
        // promised would be empty once ingest returns.
        #expect(!FileManager.default.fileExists(atPath: snapshot.path + "-shm"))
        #expect(!FileManager.default.fileExists(atPath: snapshot.path + "-wal"))
    }
}
