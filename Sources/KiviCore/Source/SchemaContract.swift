import CryptoKit
import Foundation

/// Checks that Kivi's `ZCAPTURE` still looks like we expect.
///
/// Kivi auto-updates daily via Sparkle, so drift is a matter of when, not if.
/// The failure that matters is the silent one: a schema change that makes our
/// query match zero rows, and we cheerfully record "0 words today". So a missing
/// required column is a hard failure with zero writes, and only *extra* columns
/// are tolerated.
public enum SchemaContract {
    public enum Outcome: Equatable, Sendable {
        case ok
        /// Kivi added columns. Harmless — proceed.
        case extended(added: [String])
        /// A required column is gone or retyped. Refuse to write.
        case failedMissingColumn([String])

        public var canProceed: Bool {
            switch self {
            case .ok, .extended: true
            case .failedMissingColumn: false
            }
        }

        public var detail: String {
            switch self {
            case .ok: "schema ok"
            case .extended(let added): "schema extended: \(added.joined(separator: ", "))"
            case .failedMissingColumn(let missing):
                "required column(s) missing or retyped: \(missing.joined(separator: ", "))"
            }
        }
    }

    /// Only these are load-bearing. Everything else is recorded opportunistically.
    public static let required: [String: String] = [
        "Z_PK": "INTEGER",
        "ZCREATEDAT": "TIMESTAMP",
        "ZDURATIONSECONDS": "FLOAT",
        "ZAPPBUNDLEID": "VARCHAR",
        "ZMODE": "VARCHAR",
        "ZSTATUS": "VARCHAR",
        "ZFORMATTEDTEXT": "VARCHAR",
        "ZUPDATEDAT": "TIMESTAMP",
    ]

    /// Columns observed in Kivi's real schema that we do not depend on.
    ///
    /// Without this list every run would report `schema_extended`, which would
    /// make the signal useless — the point is to notice a *genuinely new*
    /// column, not to rediscover the ones already there.
    public static let knownOptional: Set<String> = [
        "ZARCHIVED", "ZLANGUAGEHINT", "ZPINNED", "ZPENDINGSYNC", "ZRAWTEXT",
        "ZID", "ZORGID", "ZREMOTEID", "ZREVISIONCOUNT", "ZUSERID",
        "ZWORKSPACEID", "ZENT", "Z_OPT",
    ]

    public static func validate(_ db: Database) throws -> Outcome {
        let columns =
            try db.query("PRAGMA table_info(ZCAPTURE)") { row in
                (name: row.text(1) ?? "", type: (row.text(2) ?? "").uppercased())
            }

        guard !columns.isEmpty else {
            return .failedMissingColumn(["ZCAPTURE"])
        }

        let present = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0.type) })
        let missing = required.filter { present[$0.key] != $0.value }.keys.sorted()

        if !missing.isEmpty {
            return .failedMissingColumn(missing)
        }

        let added =
            columns.map(\.name)
            .filter { !required.keys.contains($0) && !knownOptional.contains($0) }
            .sorted()
        return added.isEmpty ? .ok : .extended(added: added)
    }

    /// Stable hash of the `name:type:notnull:pk` contract, stored per source so a
    /// drift report can be reproduced exactly from a user's bug report.
    public static func hash(_ db: Database) throws -> String {
        let rows =
            try db.query(
                """
                SELECT name, type, \"notnull\", pk FROM pragma_table_info('ZCAPTURE')
                ORDER BY name
                """
            ) { row in
                "\(row.text(0) ?? ""):\(row.text(1) ?? ""):\(row.int64OrZero(2)):\(row.int64OrZero(3))"
            }
        let digest = SHA256.hash(data: Data(rows.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The digest text shown in "Copy diagnostics", so a drift report is
    /// reproducible without the user having to open a terminal.
    public static func diagnostics(_ db: Database) throws -> String {
        let columns =
            try db.query("PRAGMA table_info(ZCAPTURE)") { row in
                "\(row.text(1) ?? "?")\t\(row.text(2) ?? "?")"
            }
        return (try ["schema_hash: \(hash(db))"] + columns).joined(separator: "\n")
    }
}
