import Foundation

/// Samples Kivi's own lifetime counters so we can be honest about coverage.
///
/// ## What this can and cannot tell you
///
/// Can: whether incognito was on at each run, and whether the counter reset.
///
/// Cannot: whether incognito was on during any *specific* take, or how many
/// takes it suppressed. The gap between what Kivi reports and what we hold has
/// at least three indistinguishable causes — incognito (never written), the
/// zero-retention purge (written then deleted), and store migration. We report
/// the gap and say so, rather than imputing a cause.
public enum CoverageSampler {
    public struct Sample: Sendable, Equatable {
        public var installID: String?
        public var takeStarted: Int64?
        public var takeSuccess: Int64?
        public var takeCancelled: Int64?
        public var takeFailEmpty: Int64?
        public var pasteVerified: Int64?
        public var incognitoNow: Bool?
        public var privacyMode: Bool?
    }

    /// Reads Kivi's preference files directly rather than through `cfprefsd`,
    /// so a run sees on-disk values instead of a possibly-cached view.
    public static func sample(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Sample {
        var sample = Sample()

        let appPrefs = home.appendingPathComponent("Library/Preferences/ai.sarvam.Kivi.plist")
        let sharedPrefs =
            home.appendingPathComponent("Library/Preferences/ai.sarvam.kivi.shared.plist")

        if let contents = readPlist(at: appPrefs) {
            let counters = contents["kivi.diagnostics.counters"] as? [String: Any] ?? [:]
            sample.takeStarted = int(counters["take.started"])
            sample.takeSuccess = int(counters["take.ended.success"])
            sample.takeCancelled = int(counters["take.cancelled"])
            sample.takeFailEmpty = int(counters["take.ended.failure.empty"])
            sample.pasteVerified = int(counters["paste.verifiedPasted"])
        }

        if let shared = readPlist(at: sharedPrefs) {
            sample.installID = shared["kiviInstallationID"] as? String
            sample.incognitoNow = bool(shared["kiviIncognitoMode"])
            sample.privacyMode = bool(shared["kiviPrivacyMode"])
        }

        return sample
    }

    /// Records the sample and opens a new generation when the counters reset.
    ///
    /// A generation exists so the coverage line has an explicit break rather
    /// than a cliff to zero. Two independent reset signals, because either can
    /// happen alone: a changed installation id (genuine reinstall) or a counter
    /// that went backwards (preferences cleared).
    public static func record(
        _ sample: Sample,
        in db: Database,
        now: Date = Date(),
        sourceID: Int64 = 1
    ) throws {
        let nowSeconds = Int64(now.timeIntervalSince1970)

        let current =
            try db.query(
                "SELECT generation, base_started, base_success, install_id"
                    + " FROM coverage_generation WHERE source_id = ? ORDER BY generation DESC LIMIT 1",
                bindings: [.int64(sourceID)]
            ) { (Int($0.int64OrZero(0)), $0.int64(1), $0.int64(2), $0.text(3)) }.first

        let heldNow =
            try db.query(
                "SELECT COUNT(*) FROM take WHERE source_id = ? AND retired_at IS NULL",
                bindings: [.int64(sourceID)]
            ) { Int($0.int64OrZero(0)) }.first ?? 0

        var generation = current?.0 ?? 0
        let previousStarted = current?.1
        let previousInstall = current?.3

        let installChanged = previousInstall != nil && previousInstall != sample.installID
        let counterWentBackwards =
            previousStarted != nil && sample.takeStarted != nil && sample.takeStarted! < previousStarted!

        if current == nil {
            generation = 1
            try db.execute(
                """
                INSERT INTO coverage_generation
                    (source_id, generation, install_id, started_at, base_started,
                     base_success, base_ingested)
                VALUES (?, 1, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .int64(sourceID), .text(sample.installID), .int64(nowSeconds),
                    .int64(sample.takeStarted ?? 0), .int64(sample.takeSuccess ?? 0),
                    .int64(Int64(heldNow)),
                ]
            )
        } else if installChanged || counterWentBackwards {
            let reason = installChanged ? "installation_id_changed" : "counter_regressed"
            try db.execute(
                "UPDATE coverage_generation SET ended_at = ?, reset_reason = ?"
                    + " WHERE source_id = ? AND generation = ?",
                bindings: [
                    .int64(nowSeconds), .text(reason), .int64(sourceID), .int64(Int64(generation)),
                ]
            )
            generation += 1
            try db.execute(
                """
                INSERT INTO coverage_generation
                    (source_id, generation, install_id, started_at, base_started,
                     base_success, base_ingested, reset_reason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .int64(sourceID), .int64(Int64(generation)), .text(sample.installID),
                    .int64(nowSeconds), .int64(sample.takeStarted ?? 0),
                    .int64(sample.takeSuccess ?? 0), .int64(Int64(heldNow)), .text(reason),
                ]
            )
        }

        let insert =
            try db.prepare(
                """
                INSERT INTO counter_sample
                    (source_id, taken_at, install_id, generation, take_started, take_success,
                     take_cancelled, take_fail_empty, paste_verified, incognito_now)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            )
        try insert
            .bind(sourceID, at: 1)
            .bind(nowSeconds, at: 2)
            .bindIfPresent(sample.installID, at: 3)
            .bind(Int64(generation), at: 4)
            .bindIfPresent(sample.takeStarted, at: 5)
            .bindIfPresent(sample.takeSuccess, at: 6)
            .bindIfPresent(sample.takeCancelled, at: 7)
            .bindIfPresent(sample.takeFailEmpty, at: 8)
            .bindIfPresent(sample.pasteVerified, at: 9)
            .bindIfPresent(sample.incognitoNow.map { Int64($0 ? 1 : 0) }, at: 10)
            .run()
    }

    // MARK: - Helpers

    private static func readPlist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func int(_ value: Any?) -> Int64? {
        if let v = value as? Int64 { return v }
        if let v = value as? Int { return Int64(v) }
        if let v = value as? NSNumber { return v.int64Value }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let v = value as? Bool { return v }
        if let v = value as? NSNumber { return v.boolValue }
        return nil
    }
}
