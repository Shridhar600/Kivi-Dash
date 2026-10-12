import Foundation

public struct IngestResult: Sendable, Equatable {
    public enum Outcome: String, Sendable {
        case ok
        case skippedNoSource
        case skippedBusy
        case failedSchema
        case failedEmpty
        case failedError
    }

    public var outcome: Outcome
    public var detail: String
    public var rowsSeen: Int
    public var rowsNew: Int
    public var rowsRetired: Int
    public var daysRebuilt: Int
    public var durationMS: Int64

    public init(outcome: Outcome, detail: String = "") {
        self.outcome = outcome
        self.detail = detail
        self.rowsSeen = 0
        self.rowsNew = 0
        self.rowsRetired = 0
        self.daysRebuilt = 0
        self.durationMS = 0
    }

    public var succeeded: Bool { outcome == .ok }
}

/// Writes extracted facts into our database and rebuilds the affected days.
///
/// ## Why day-recompute rather than deltas
///
/// `daily_rollup` is recomputed from `take` for **only the days this run
/// touched**. Delta arithmetic was rejected: to subtract a take's contribution
/// later you must remember its previous contribution, which is exactly as much
/// state as the `take` row you already have. Deltas are also not idempotent —
/// a re-run after a partial failure double-counts — and a crash mid-run leaves
/// the rollup silently drifted from the facts with no way to detect it.
///
/// This still satisfies "don't recompute on every open": the UI reads only
/// `daily_rollup` and never touches `take`. A typical run rebuilds 0–2 days.
///
/// ## A retired take is still counted
///
/// Kivi purges rows, and that is expected rather than an error. Its words and
/// duration stay in the totals and `takes_retired` records how many. Excluding
/// them would mean every statistic decays as Kivi purges — a count that shrinks
/// while you dictate more is worse than useless.
public enum Ingestor {
    /// The source id used when we have never seen this Kivi installation before.
    public static let initialSourceID: Int64 = 1

    /// Resolves which `source_id` this ingest belongs to.
    ///
    /// Takes are keyed on `(source_id, kivi_pk)`, and `kivi_pk` is Kivi's own
    /// `Z_PK` — which restarts at 1 when Kivi is reinstalled. Keying every
    /// install to the same `source_id` means a fresh install's row 1 collides
    /// with the previous install's row 1, and the upsert silently replaces it.
    /// Because the replacement has a *newer* `src_updated_at`, it satisfies the
    /// change predicate, so it wins: a 900-word take is overwritten by a 4-word
    /// one, with no `retired_at` and no counter movement. History is lost
    /// silently.
    ///
    /// Keying by installation instead means a reinstall opens a new `source_id`.
    /// The old rows stay exactly where they are and keep counting; the rollups
    /// are grouped by `(day_local, source_id)` and every read path sums across
    /// sources, so lifetime totals simply include both installs.
    ///
    /// Note the upsert's `src_updated_at > take.src_updated_at` predicate is
    /// deliberately left strict. Loosening it to `>=` would make it true for
    /// every unchanged row on every run, rewriting all of `take` and rebuilding
    /// every rollup each time — and would make clock skew overwrite *more*
    /// readily, not less.
    static func resolveSourceID(in db: Database, kiviInstallationID: String?) throws -> Int64 {
        let known =
            try db.query("SELECT source_id, kivi_installation_id FROM source_store ORDER BY source_id") {
                (id: $0.int64OrZero(0), installID: $0.text(1))
            }

        guard let highest = known.map(\.id).max() else { return initialSourceID }

        // No id to match on (older builds recorded none): stay on the current
        // source rather than allocating a new one on every run.
        guard let incoming = kiviInstallationID, !incoming.isEmpty else { return highest }

        if let match = known.first(where: { $0.installID == incoming }) {
            return match.id
        }
        // A different installation: this is a reinstall, so take a new id.
        return highest + 1
    }

    public static func run(
        target: Database,
        takes: [ExtractedTake],
        timezone: TimeZone,
        now: Date = Date(),
        storePath: String = "",
        kiviAppVersion: String? = nil,
        kiviModelVersion: String? = nil,
        schemaHash: String = "",
        kiviInstallationID: String? = nil,
        incognitoNow: Bool? = nil,
        takeSuccess: Int64? = nil
    ) throws -> IngestResult {
        let started = now
        let nowSeconds = Int64(now.timeIntervalSince1970)
        // How long the run actually took is wall-clock elapsed time, which is not
        // the same thing as the `now` this run is *stamped* with. Tests inject a
        // fixture date, and measuring against that produced multi-day
        // `duration_ms` and a `finished_at` days in the future.
        let clockStart = Date()
        var result = IngestResult(outcome: .ok)
        let sourceID = try resolveSourceID(in: target, kiviInstallationID: kiviInstallationID)

        // Fetch what we already hold so we can tell new rows from edited ones.
        // A row counts as changed if it is new, if its upstream update time moved,
        // or if it was previously retired and has come back.
        typealias PriorState = (updatedAt: Int64, isRetired: Bool)
        let existing =
            Dictionary(
                uniqueKeysWithValues:
                    try target.query(
                        "SELECT kivi_pk, src_updated_at, retired_at FROM take"
                            + " WHERE source_id = ?",
                        bindings: [.int64(sourceID)]
                    ) { row in
                        (row.int64OrZero(0), PriorState(row.int64OrZero(1), row.int64(2) != nil))
                    }
            )

        result.rowsSeen = takes.count
        result.rowsNew = takes.filter { existing[$0.kiviPK] == nil }.count

        // An empty source while we already hold history means a reset or a
        // broken migration — never "the user has no takes". Refuse to write.
        if takes.isEmpty && !existing.isEmpty {
            result.outcome = .failedEmpty
            result.detail = "source returned 0 takes but we already hold \(existing.count)"
            try recordRun(
                result,
                in: target,
                started: started,
                now: nowSeconds,
                incognito: incognitoNow,
                takeSuccess: takeSuccess
            )
            return result
        }

        try target.transaction {
            let runID = try beginRun(in: target, now: nowSeconds)
            try upsertSourceStore(
                in: target,
                sourceID: sourceID,
                now: nowSeconds,
                storePath: storePath,
                kiviAppVersion: kiviAppVersion,
                kiviModelVersion: kiviModelVersion,
                schemaHash: schemaHash,
                kiviInstallationID: kiviInstallationID,
                maxPK: takes.map(\.kiviPK).max()
            )

            var dirty = try upsertTakes(
                takes,
                into: target,
                sourceID: sourceID,
                runID: runID,
                now: nowSeconds
            )
            try refreshWatermark(in: target, takes: takes, sourceID: sourceID, runID: runID)
            result.rowsRetired = try retireVanished(
                in: target,
                sourceID: sourceID,
                runID: runID,
                now: nowSeconds
            )
            dirty.formUnion(
                try dirtyDaysFromRetirement(
                    retired: result.rowsRetired,
                    target: target,
                    sourceID: sourceID,
                    now: nowSeconds
                )
            )
            // A schema migration can add a rollup column that existing rows know
            // nothing about; those days must be recomputed rather than left
            // reporting a default forever.
            if try rebuildAllDaysRequired(in: target) || rollupLooksStale(in: target) {
                dirty.formUnion(try allKnownDays(in: target))
            }

            // Pin the projection timezone. Day attribution is a projection of an
            // immutable UTC timestamp, and 44% of takes land on a different
            // calendar date in UTC vs local, so this is not academic. If the
            // zone changed under us — a flight, or a macOS timezone-data update
            // that shifts local midnight — every day must be recomputed, or the
            // read paths silently disagree with each other.
            let storedZone = try target.scalarString("SELECT value FROM meta WHERE key = 'tz_projection'")
            let zoneChanged = storedZone != nil && storedZone != timezone.identifier
            if zoneChanged {
                // Capture the day set BEFORE re-projecting. `allKnownDays` reads
                // `take.day_local`, so calling it afterwards yields only the new
                // keys — the old ones would be orphaned in `daily_rollup`, never
                // deleted, and every take whose calendar date moved would be
                // counted in both its old and its new day. Lifetime totals, streak
                // and the sparkline would all silently double up, permanently.
                let previousDays = try allKnownDays(in: target)
                try reprojectAllDays(in: target, timezone: timezone)
                dirty.formUnion(previousDays)
                dirty.formUnion(try allKnownDays(in: target))
            }
            result.daysRebuilt = try rebuildRollups(in: target, days: dirty)

            if dirty.count > 0 {
                try target.execute(
                    "DELETE FROM meta WHERE key = '\(Schema.rebuildFlagKey)'"
                )
            }
            try target.execute(
                "INSERT INTO meta (key, value) VALUES ('tz_projection', ?)"
                    + " ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                bindings: [.text(timezone.identifier)]
            )
            result.durationMS = Int64(Date().timeIntervalSince(clockStart) * 1000)
            try finishRun(
                result,
                runID: runID,
                in: target,
                started: started,
                incognito: incognitoNow,
                takeSuccess: takeSuccess
            )
        }

        return result
    }

    // MARK: - Steps

    private static func beginRun(in db: Database, now: Int64) throws -> Int64 {
        let statement =
            try db.prepare("INSERT INTO ingest_run (started_at, outcome) VALUES (?, 'running')")
        try statement.bind(now, at: 1).run()
        return db.lastInsertRowID
    }

    private static func finishRun(
        _ result: IngestResult,
        runID: Int64,
        in db: Database,
        started: Date,
        incognito: Bool?,
        takeSuccess: Int64?
    ) throws {
        let statement =
            try db.prepare(
                """
                UPDATE ingest_run
                   SET finished_at = ?, outcome = ?, detail = ?, rows_seen = ?,
                       rows_new = ?, rows_retired = ?, days_rebuilt = ?, duration_ms = ?,
                       incognito_at_run = ?, take_success_at_run = ?
                 WHERE run_id = ?
                """
            )
        try statement
            .bind(Int64(started.timeIntervalSince1970) + result.durationMS, at: 1)
            .bind(result.outcome.rawValue, at: 2)
            .bind(result.detail, at: 3)
            .bind(Int64(result.rowsSeen), at: 4)
            .bind(Int64(result.rowsNew), at: 5)
            .bind(Int64(result.rowsRetired), at: 6)
            .bind(Int64(result.daysRebuilt), at: 7)
            .bind(result.durationMS, at: 8)
            .bindIfPresent(incognito.map { Int64($0 ? 1 : 0) }, at: 9)
            .bindIfPresent(takeSuccess, at: 10)
            .bind(runID, at: 11)
            .run()
    }

    /// Records a failed attempt outside the main transaction: a failure that
    /// rolls back must still leave a diagnostic row.
    private static func recordRun(
        _ result: IngestResult,
        in db: Database,
        started: Date,
        now: Int64,
        incognito: Bool?,
        takeSuccess: Int64?
    ) throws {
        // This path never sets `result.durationMS`, so measure it here rather than
        // reusing a timestamp from `started` — which callers pass as an injected
        // fixture date, not the wall clock.
        let clockStart = Date()
        let statement =
            try db.prepare(
                """
                INSERT INTO ingest_run
                    (started_at, finished_at, outcome, detail, rows_seen, rows_new,
                     rows_retired, days_rebuilt, duration_ms, incognito_at_run, take_success_at_run)
                VALUES (?, ?, ?, ?, 0, 0, 0, 0, ?, ?, ?)
                """
            )
        try statement
            .bind(now, at: 1)
            .bind(now, at: 2)
            .bind(result.outcome.rawValue, at: 3)
            .bind(result.detail, at: 4)
            .bind(Int64(Date().timeIntervalSince(clockStart) * 1000), at: 5)
            .bindIfPresent(incognito.map { Int64($0 ? 1 : 0) }, at: 6)
            .bindIfPresent(takeSuccess, at: 7)
            .run()
    }

    private static func upsertSourceStore(
        in db: Database,
        sourceID: Int64,
        now: Int64,
        storePath: String,
        kiviAppVersion: String?,
        kiviModelVersion: String?,
        schemaHash: String,
        kiviInstallationID: String?,
        maxPK: Int64?
    ) throws {
        let statement =
            try db.prepare(
                """
                INSERT INTO source_store
                    (source_id, kivi_installation_id, store_path, kivi_app_version,
                     kivi_model_version, schema_hash, max_pk_seen, first_seen_at, last_ingest_at)
                VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
                ON CONFLICT(source_id) DO UPDATE SET
                    kivi_installation_id = excluded.kivi_installation_id,
                    store_path           = excluded.store_path,
                    kivi_app_version     = excluded.kivi_app_version,
                    kivi_model_version   = excluded.kivi_model_version,
                    schema_hash          = excluded.schema_hash,
                    last_ingest_at       = excluded.last_ingest_at
                """
            )
        try statement
            .bind(sourceID, at: 1)
            .bindIfPresent(kiviInstallationID, at: 2)
            .bind(storePath, at: 3)
            .bindIfPresent(kiviAppVersion, at: 4)
            .bindIfPresent(kiviModelVersion, at: 5)
            .bind(schemaHash, at: 6)
            .bind(now, at: 7)
            .bind(now, at: 8)
            .run()

        if let maxPK {
            let update = try db.prepare(
                "UPDATE source_store SET max_pk_seen = max(max_pk_seen, ?) WHERE source_id = ?"
            )
            try update.bind(maxPK, at: 1).bind(sourceID, at: 2).run()
        }
    }

    /// Upserts changed takes and returns the days those rows landed on.
    ///
    /// `db.changes` is the ground truth for "did this statement actually modify
    /// anything" — more reliable than re-deriving change detection in Swift and
    /// hoping the two definitions agree.
    @discardableResult
    private static func upsertTakes(
        _ takes: [ExtractedTake],
        into db: Database,
        sourceID: Int64,
        runID: Int64,
        now: Int64
    ) throws -> Set<String> {
        var changed = Set<String>()
        guard !takes.isEmpty else { return changed }
        let statement =
            try db.prepare(
                """
                INSERT INTO take
                    (source_id, kivi_pk, taken_at, day_local, hour_local, mode, bundle_id,
                     bundle_key, duration_ms, word_count, char_count, word_method, is_complete,
                     speed_eligible, src_updated_at, ingested_at, last_seen_run, retired_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(source_id, kivi_pk) DO UPDATE SET
                    taken_at       = excluded.taken_at,
                    day_local      = excluded.day_local,
                    hour_local     = excluded.hour_local,
                    mode           = excluded.mode,
                    bundle_id      = excluded.bundle_id,
                    bundle_key     = excluded.bundle_key,
                    duration_ms    = excluded.duration_ms,
                    word_count     = excluded.word_count,
                    char_count     = excluded.char_count,
                    word_method    = excluded.word_method,
                    is_complete    = excluded.is_complete,
                    speed_eligible = excluded.speed_eligible,
                    src_updated_at = excluded.src_updated_at,
                    last_seen_run  = excluded.last_seen_run,
                    retired_at     = NULL
                -- Only genuinely-changed rows are rewritten here. Adding
                -- `last_seen_run <> ...` to this predicate would make it
                -- unconditionally true, rewrite every row on every run, and
                -- (because the dirty set is derived separately) leave the
                -- rollups permanently inconsistent with the facts.
                WHERE excluded.src_updated_at > take.src_updated_at
                   OR take.retired_at IS NOT NULL
                """
            )

        for take in takes {
            try statement.reset()
            try statement
                .bind(sourceID, at: 1)
                .bind(take.kiviPK, at: 2)
                .bind(take.takenAt, at: 3)
                .bind(take.dayLocal, at: 4)
                .bind(Int64(take.hourLocal), at: 5)
                .bind(take.mode, at: 6)
                .bindIfPresent(take.bundleID, at: 7)
                .bindIfPresent(take.bundleKey, at: 8)
                .bindIfPresent(take.durationMS, at: 9)
                .bind(Int64(take.wordCount), at: 10)
                .bind(Int64(take.charCount), at: 11)
                .bind(WordCount.method, at: 12)
                .bind(take.isComplete ? Int64(1) : Int64(0), at: 13)
                .bind(take.isSpeedEligible ? Int64(1) : Int64(0), at: 14)
                .bind(take.srcUpdatedAt, at: 15)
                .bind(now, at: 16)
                .bind(runID, at: 17)
                .run()
            if db.changes > 0 { changed.insert(take.dayLocal) }
        }
        return changed
    }

    /// Moves the "last seen" watermark forward for the takes we actually saw.
    ///
    /// Separate from `upsertTakes` precisely so that *seeing* an unchanged row
    /// is not treated as a *change* of it — this is what lets `retireVanished`
    /// distinguish "Kivi deleted it" from "nothing changed".
    ///
    /// Scoped to the current batch on purpose: touching every row for this source
    /// would refresh the watermark of takes Kivi has removed, and nothing would
    /// ever be retired.
    private static func refreshWatermark(
        in db: Database,
        takes: [ExtractedTake],
        sourceID: Int64,
        runID: Int64
    ) throws {
        let statement =
            try db.prepare(
                "UPDATE take SET last_seen_run = ? WHERE source_id = ? AND kivi_pk = ?"
            )
        for take in takes {
            try statement.reset()
            try statement.bind(runID, at: 1).bind(sourceID, at: 2).bind(take.kiviPK, at: 3).run()
        }
    }

    /// Marks takes we can no longer see upstream. Watermark form: uses the
    /// `ix_take_seen` index rather than a full anti-join every run.
    private static func retireVanished(in db: Database, sourceID: Int64, runID: Int64, now: Int64) throws -> Int {
        let statement =
            try db.prepare(
                """
                UPDATE take
                   SET retired_at = ?
                 WHERE source_id = ?
                   AND retired_at IS NULL
                   AND last_seen_run < ?
                """
            )
        try statement.bind(now, at: 1).bind(sourceID, at: 2).bind(runID, at: 3).run()
        return Int(db.changes)
    }

    /// Days whose rollups must be recomputed because a take was just retired.
    private static func rebuildAllDaysRequired(in db: Database) throws -> Bool {
        try db.scalarString("SELECT value FROM meta WHERE key = '\(Schema.rebuildFlagKey)'")
            == "1"
    }

    /// Self-healing check for a rollup that is structurally incomplete.
    ///
    /// A day with dictation but zero dictation-word total cannot be right, and
    /// this is how a database written by an older build (before a column existed)
    /// repairs itself instead of reporting a permanent zero.
    private static func rollupLooksStale(in db: Database) throws -> Bool {
        let suspect =
            try db.scalarInt64(
                "SELECT count(*) FROM daily_rollup WHERE takes_dictate > 0 AND words_dictate = 0"
            ) ?? 0
        // Parenthesised deliberately. Swift binds `??` tighter than `>`, so this
        // is already `(nil ?? 0) > 0`; the parens stop the next reader having to
        // re-derive that. A zero count being falsy is true by coincidence here.
        return suspect > 0
    }

    /// Recomputes `day_local` / `hour_local` for every stored take from its
    /// immutable UTC timestamp, under a new projection timezone.
    private static func reprojectAllDays(in db: Database, timezone: TimeZone) throws {
        let rows =
            try db.query("SELECT source_id, kivi_pk, taken_at FROM take") {
                (sourceID: $0.int64OrZero(0), pk: $0.int64OrZero(1), takenAt: $0.int64OrZero(2))
            }
        let update =
            try db.prepare("UPDATE take SET day_local = ?, hour_local = ? WHERE source_id = ? AND kivi_pk = ?")
        for row in rows {
            try update.reset()
            try update
                .bind(DayKey.string(fromUnixSeconds: row.takenAt, timezone: timezone), at: 1)
                .bind(Int64(DayKey.hour(fromUnixSeconds: row.takenAt, timezone: timezone)), at: 2)
                .bind(row.sourceID, at: 3)
                .bind(row.pk, at: 4)
                .run()
        }
    }

    private static func allKnownDays(in db: Database) throws -> Set<String> {
        Set(
            try db.query("SELECT DISTINCT day_local FROM take") { $0.text(0) ?? "" }
        )
    }

    private static func dirtyDaysFromRetirement(
        retired: Int,
        target: Database,
        sourceID: Int64,
        now: Int64
    ) throws -> Set<String> {
        var days = Set<String>()
        if retired > 0 {
            let affected =
                try target.query(
                    """
                    SELECT DISTINCT day_local FROM take
                     WHERE source_id = ? AND retired_at = ?
                    """,
                    bindings: [.int64(sourceID), .int64(now)]
                ) { $0.text(0) ?? "" }
            days.formUnion(affected)
        }
        return days
    }

    private static func rebuildRollups(in db: Database, days: Set<String>) throws -> Int {
        guard !days.isEmpty else { return 0 }

        // Pass the day set through a temp table so the SQL stays a single,
        // indexable predicate instead of a dynamically built IN list.
        try db.execute("DROP TABLE IF EXISTS temp.dirty_days")
        try db.execute("CREATE TEMP TABLE dirty_days (day_local TEXT PRIMARY KEY) STRICT")
        let insert = try db.prepare("INSERT OR IGNORE INTO dirty_days (day_local) VALUES (?)")
        for day in days {
            try insert.reset()
            try insert.bind(day, at: 1).run()
        }

        try db.execute("DELETE FROM daily_rollup WHERE day_local IN (SELECT day_local FROM dirty_days)")

        try db.execute(
            """
            INSERT INTO daily_rollup
                (day_local, source_id, takes_dictate, takes_clipboard, words, words_dictate,
                 char_count, mic_ms, speech_ms, speech_words, takes_live, takes_retired)
            SELECT t.day_local,
                   t.source_id,
                   COALESCE(SUM(t.mode = 'dictate'), 0),
                   COALESCE(SUM(t.mode = 'clipboard'), 0),
                   COALESCE(SUM(t.word_count), 0),
                   COALESCE(SUM(CASE WHEN t.mode = 'dictate' THEN t.word_count ELSE 0 END), 0),
                   COALESCE(SUM(t.char_count), 0),
                   COALESCE(SUM(CASE WHEN t.mode = 'dictate' THEN COALESCE(t.duration_ms, 0) ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN t.speed_eligible = 1 THEN t.duration_ms ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN t.speed_eligible = 1 THEN t.word_count ELSE 0 END), 0),
                   COALESCE(SUM(t.retired_at IS NULL), 0),
                   COALESCE(SUM(t.retired_at IS NOT NULL), 0)
              FROM take t
             WHERE t.day_local IN (SELECT day_local FROM dirty_days)
             GROUP BY t.day_local, t.source_id
            """
        )

        try db.execute(
            "DELETE FROM daily_app_rollup WHERE day_local IN (SELECT day_local FROM dirty_days)"
        )
        try db.execute(
            """
            INSERT INTO daily_app_rollup
                (day_local, source_id, bundle_key, bundle_id, takes, words,
                 takes_dictate, words_dictate, mic_ms, speech_ms, speech_words, last_seen_at)
            SELECT t.day_local,
                   t.source_id,
                   t.bundle_key,
                   MAX(t.bundle_id),
                   COUNT(*),
                   SUM(t.word_count),
                   COALESCE(SUM(t.mode = 'dictate'), 0),
                   COALESCE(SUM(CASE WHEN t.mode = 'dictate' THEN t.word_count ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN t.mode = 'dictate' THEN COALESCE(t.duration_ms, 0) ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN t.speed_eligible = 1 THEN t.duration_ms ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN t.speed_eligible = 1 THEN t.word_count ELSE 0 END), 0),
                   MAX(t.taken_at)
              FROM take t
             WHERE t.day_local IN (SELECT day_local FROM dirty_days)
               AND t.bundle_key IS NOT NULL
             GROUP BY t.day_local, t.source_id, t.bundle_key
            """
        )

        try db.execute("DROP TABLE IF EXISTS temp.dirty_days")
        return days.count
    }
}
