import Foundation
import Testing

@testable import KiviCore

@Suite("Schema contract and drift")
struct SchemaContractTests {
    private func validate(_ url: URL) throws -> SchemaContract.Outcome {
        let db = try Database(path: url.path, readOnly: true)
        return try SchemaContract.validate(db)
    }

    @Test("matching schema is ok")
    func ok() throws {
        let url = try Fixture.makeKiviStore([])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try validate(url) == .ok)
    }

    @Test("extra columns are tolerated and reported")
    func extended() throws {
        let url = try Fixture.makeKiviStore([], extraColumnsSQL: "ALTER TABLE ZCAPTURE ADD COLUMN ZNEWTHING INTEGER")
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = try validate(url)
        #expect(outcome == .extended(added: ["ZNEWTHING"]))
        #expect(outcome.canProceed, "adding a column must not break ingest")
    }

    @Test("a missing required column is refused")
    func missing() throws {
        let url = Fixture.tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database(path: url.path)
        try db.execute(
            """
            CREATE TABLE ZCAPTURE (Z_PK INTEGER PRIMARY KEY, ZCREATEDAT TIMESTAMP, ZMODE VARCHAR)
            """
        )
        let outcome = try SchemaContract.validate(db)
        #expect(!outcome.canProceed)
        guard case .failedMissingColumn(let missing) = outcome else {
            Issue.record("expected failedMissingColumn, got \(outcome)")
            return
        }
        #expect(missing.contains("ZFORMATTEDTEXT"))
        #expect(missing.contains("ZUPDATEDAT"))
    }

    @Test("an absent ZCAPTURE table is refused rather than read as zero takes")
    func absentTable() throws {
        let url = Fixture.tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database(path: url.path)
        try db.execute("CREATE TABLE something_else (id INTEGER)")
        let outcome = try SchemaContract.validate(db)
        #expect(outcome == .failedMissingColumn(["ZCAPTURE"]))
        #expect(!outcome.canProceed)
    }

    @Test("hash is stable and changes with the contract")
    func hashChanges() throws {
        let a = try Fixture.makeKiviStore([])
        let b = try Fixture.makeKiviStore([], extraColumnsSQL: "ALTER TABLE ZCAPTURE ADD COLUMN ZOTHER INTEGER")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let hashA = try SchemaContract.hash(Database(path: a.path, readOnly: true))
        let hashAgain = try SchemaContract.hash(Database(path: a.path, readOnly: true))
        let hashB = try SchemaContract.hash(Database(path: b.path, readOnly: true))
        #expect(hashA.count == 64)
        #expect(hashA == hashAgain, "hash must be stable for an unchanged schema")
        #expect(hashA != hashB, "hash must change when the contract changes")
    }

    @Test("diagnostics include the hash and column list")
    func diagnostics() throws {
        let url = try Fixture.makeKiviStore([])
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try SchemaContract.diagnostics(Database(path: url.path, readOnly: true))
        #expect(text.contains("schema_hash:"))
        #expect(text.contains("ZFORMATTEDTEXT"))
    }
}
