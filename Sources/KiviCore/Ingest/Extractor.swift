import Foundation

/// One take, reduced to numbers.
///
/// There is deliberately **no text field on this type**. The transcript is read
/// into a local variable, counted, and dropped before this value is constructed,
/// so it is impossible to persist it by accident — the compiler enforces the
/// privacy boundary rather than a code review.
public struct ExtractedTake: Sendable, Equatable {
    public let kiviPK: Int64
    public let takenAt: Int64
    public let dayLocal: String
    public let hourLocal: Int
    public let mode: String
    public let bundleID: String?
    public let bundleKey: String?
    public let durationMS: Int64?
    public let wordCount: Int
    public let charCount: Int
    public let isComplete: Bool
    public let isTruncated: Bool
    public let srcUpdatedAt: Int64

    /// Frozen at ingest so rollups are a pure sum and the rule stays backfillable.
    public var isSpeedEligible: Bool {
        guard mode == "dictate", isComplete, !isTruncated, wordCount >= 5,
            let durationMS
        else { return false }
        let seconds = Double(durationMS) / 1000
        // Below 5s the duration is quantisation noise; above 300s the orb was
        // left open and the "rate" is not speech at all.
        return (5.0...300.0).contains(seconds)
    }
}

/// Reads takes out of a snapshot and reduces them to numbers.
public enum Extractor {
    static let sql = """
        SELECT Z_PK, ZCREATEDAT, ZDURATIONSECONDS, ZAPPBUNDLEID, ZMODE,
               ZSTATUS, ZFORMATTEDTEXT, ZUPDATEDAT
          FROM ZCAPTURE
         ORDER BY Z_PK
        """

    /// Maps Kivi's raw mode value. Unknown values are preserved as
    /// `other:<raw>` so a new mode is counted and visible, not silently dropped.
    public static func normalizeMode(_ raw: String?) -> String {
        switch raw {
        case "dictate": "dictate"
        case "clipboard": "clipboard"
        case .some(let value): "other:\(value)"
        case nil: "other:none"
        }
    }

    /// Bundle ids are lower-cased for grouping: Kivi stores
    /// `dev.warp.Warp-Stable` but its own preferences say
    /// `dev.warp.warp-stable`, and grouping on the raw value splits one app
    /// across two rows.
    public static func normalizeBundleKey(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.lowercased()
    }

    /// Converts a duration in seconds to whole milliseconds, or nil if the value
    /// cannot be represented.
    ///
    /// Two ways a third-party column breaks this:
    /// * `Int64(someDouble)` is a **runtime trap**, not a throwable error, when
    ///   the value is out of range. `Row.double` already rejects `Inf` and `NaN`,
    ///   but a merely *large* finite value such as `1e300` sails straight through
    ///   and takes the whole process down with it.
    /// * A negative duration is meaningless, and summing one into a day's mic
    ///   time would subtract from it.
    ///
    /// Returns nil for the first so the take is still counted for its words; the
    /// duration simply counts as unknown.
    static func milliseconds(fromAppleSeconds seconds: Double) -> Int64? {
        let ms = (seconds * 1000).rounded()
        guard ms > -9.0e18, ms < 9.0e18 else { return nil }
        return Int64(max(0, ms))
    }

    /// Extracts every dated take from the snapshot.
    ///
    /// Rows with a NULL `ZCREATEDAT` are dropped rather than defaulted to zero.
    /// Zero is the Apple reference date, which lands the take on 2001-01-01 —
    /// a real rollup row that then inflates all-time totals forever, for a take
    /// whose real date is simply unknown. A take we cannot place is worth less
    /// than a take we place honestly.
    ///
    /// The count of dropped rows is not reported back; surfacing it would change
    /// this function's signature, and it is tracked in the backlog as the
    /// remaining work.
    public static func extract(from snapshot: Database, timezone: TimeZone) throws -> [ExtractedTake] {
        let rows =
            try snapshot.query(sql) { row -> ExtractedTake? in
                guard let createdAt = row.double(1) else { return nil }
                let updatedAt = row.double(7) ?? createdAt
                let takenAt = DayKey.unixSeconds(fromAppleReference: createdAt)

                // The transcript exists only inside this closure's scope.
                let counts: WordCount.Counts =
                    row.text(6).map { WordCount.count($0) } ?? WordCount.Counts(words: 0, chars: 0)

                let bundleID = row.text(3).flatMap { $0.isEmpty ? nil : $0 }

                return ExtractedTake(
                    kiviPK: row.int64OrZero(0),
                    takenAt: takenAt,
                    dayLocal: DayKey.string(fromUnixSeconds: takenAt, timezone: timezone),
                    hourLocal: DayKey.hour(fromUnixSeconds: takenAt, timezone: timezone),
                    mode: normalizeMode(row.text(4)),
                    bundleID: bundleID,
                    bundleKey: normalizeBundleKey(bundleID),
                    durationMS: row.double(2).flatMap(milliseconds(fromAppleSeconds:)),
                    wordCount: counts.words,
                    charCount: counts.chars,
                    isComplete: row.text(5) == "complete",
                    isTruncated: counts.isTruncated,
                    srcUpdatedAt: DayKey.unixSeconds(fromAppleReference: updatedAt)
                )
            }
        return rows.compactMap { $0 }
    }
}
