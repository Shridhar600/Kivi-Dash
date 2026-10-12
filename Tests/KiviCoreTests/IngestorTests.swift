import Foundation
import Testing

@testable import KiviCore

@Suite("Ingestor")
struct IngestorTests {
    private let ist = TimeZone(identifier: "Asia/Kolkata")!

    private func freshTarget() throws -> (Database, URL) {
        let url = Fixture.tempFile()
        let db = try Database(path: url.path)
        try Schema.apply(to: db)
        return (db, url)
    }

    private func take(
        _ pk: Int64,
        day: Int = 3,
        hour: Int = 2,
        minutes: Double = 0.5,
        duration: Double? = 30,
        words: Int = 100,
        app: String? = "com.openai.codex",
        mode: String = "dictate"
    ) -> ExtractedTake {
        let calendar = DayKey.calendar(timezone: ist)
        let start = calendar.date(
            from: DateComponents(timeZone: ist, year: 2026, month: 10, day: day, hour: hour)
        )!
        let takenAt = Int64(start.timeIntervalSince1970)
        return ExtractedTake(
            kiviPK: pk,
            takenAt: takenAt,
            dayLocal: DayKey.string(fromUnixSeconds: takenAt, timezone: ist),
            hourLocal: hour,
            mode: mode,
            bundleID: app,
            bundleKey: app?.lowercased(),
            durationMS: duration.map { Int64($0 * 1000) },
            wordCount: words,
            charCount: words * 6,
            isComplete: true,
            isTruncated: false,
            srcUpdatedAt: takenAt
        )
    }

    // MARK: - First run and idempotence

    @Test("first run loads takes and builds rollups")
    func firstRun() throws {
        let (db, url) = try freshTarget()
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try Ingestor.run(
            target: db,
            takes: [take(1), take(2, day: 4, hour: 14)],
            timezone: ist,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(result.outcome == .ok)
        #expect(result.rowsSeen == 2)
        #expect(result.rowsNew == 2)
        #expect(result.daysRebuilt == 2)
        #expect(try db.scalarInt64("SELECT count(*) FROM take") == 2)
        #expect(try db.scalarInt64("SELECT count(*) FROM daily_rollup") == 2)
        #expect(try db.scalarInt64("SELECT words FROM daily_rollup WHERE day_local='2026-10-03'") == 100)
    }

    /// Re-running with no source change must write nothing.
    @Test("re-running unchanged is a no-op")
    func idempotent() throws {
        let (db, url) = try freshTarget()
        defer { try? FileManager.default.removeItem(at: url) }

        let batch = [take(1), take(2, day: 4, hour: 14)]
        let first = try Ingestor.run(target: db, takes: batch, timezone: ist)
        let snapshotAfterFirst = try db.query("SELECT * FROM daily_rollup ORDER BY day_local") {
            "\($0.text(0) ?? "")|\($0.int64OrZero(4))|\($0.int64OrZero(5))"
        }

        let second = try Ingestor.run(target: db, takes: batch, timezone: ist)

        #expect(second.outcome == .ok)
        #expect(second.rowsNew == 0, "nothing new should be reported")
        #expect(second.rowsRetired == 0)
        #expect(try db.scalarInt64("SELECT count(*) FROM take") == 2, "no duplicate facts")
        #expect(try db.scalarInt64("SELECT count(*) FROM daily_rollup") == 2)

        let snapshotAfterSecond = try db.query("SELECT * FROM daily_rollup ORDER BY day_local") {
            "\($0.text(0) ?? "")|\($0.int64OrZero(4))|\($0.int64OrZero(5))"
        }
        #expect(snapshotAfterFirst == snapshotAfterSecond, "rollup changed on a no-op run")
        _ = first
    }

    @Test("a new take rebuilds only its own day")
    func lateArrival() throws {
        let (db, url) = try freshTarget()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try Ingestor.run(target: db, takes: [take(1), take(2, day: 4)], timezone: ist)
        let result = try Ingestor.run(
            target: db,
            takes: [take(1), take(2, day: 4), take(3, day: 4, words: 50)],
            timezone: ist
        )

        #expect(result.rowsNew == 1)
        #expect(result.daysRebuilt == 1, "only the affected day should be recomputed")
        #expect(try db.scalarInt64("SELECT words FROM daily_rollup WHERE day_local='2026-10-04'") == 150)
    }

    /// The durability guarantee: Kivi deletes rows, our totals do not shrink.
    @Test("a take deleted upstream stays in our totals")
    func retiredTakeStillCounted() throws {
        let (db, url) = try freshTarget()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try Ingestor.run(target: db, takes: [take(1, words: 100), take(2, words: 40)], timezone: ist)
        #expect(try db.scalarInt64("SELECT words FROM daily_rollup WHERE day_local='2026-10-03'") == 140)

        // Source now only reports one of them.
        let result = try Ingestor.run(target: db, takes: [take(1, words: 100)], timezone: ist)

        #expect(result.rowsRetired == 1)
        #expect(
            try db.scalarInt64("SELECT words FROM daily_rollup WHERE day_local='2026-10-03'") == 140,
            "retiring a take must not reduce the day's word total"
        )
        #expect(
            try db.scalarInt64(
                "SELECT takes_retired FROM daily_rollup WHERE day_local='2026-10-03'"
            ) == 1
        )
        #expect(
            try db.scalarInt64("SELECT takes_live FROM daily_rollup WHERE day_local='2026-10-03'") == 1
        )
    }

    /// When the take comes back, it is un-retired.
    @Test("a reappearing take is un-retired")
    func unretire() throws {
        let (db, url) = try freshTarget()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try Ingestor.run(target: db, takes: [take(1), take(2)], timezone: ist)
        _ = try Ingestor.run(target: db, takes: [take(1)], timezone: ist)
        #expect(try db.scalarInt64("SELECT takes_retired FROM daily_rollup") == 1)

        _ = try Ingestor.run(target: db, takes: [take(1), take(2)], timezone: ist)
        #expect(try db.scalarInt64("SELECT takes_retired FROM daily_rollup") == 0)
        #expect(try db.scalarInt64("SELECT takes_live FROM daily_rollup") == 2)
    }

    // MARK: - Guards

    @Test("an empty source with existing history refuses to write")
    func emptySourceRefused() throws {
        let (db, url) = try freshTarget()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try Ingestor.run(target: db, takes: [take(1)], timezone: ist)
        let result = try Ingestor.run(target: db, takes: [], timezone: ist)

        #expect(result.outcome == .failedEmpty)
        #expect(try db.scalarInt64("SELECT count(*) FROM take") == 1, "no facts may be destroyed")
        #expect(try db.scalarInt64("SELECT words FROM daily_rollup") == 100)
    }

    @Test("an empty source with no history yet is simply empty, not a failure")
    func emptySourceFirstRun() throws {
        let (db, url) = try freshTarget()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try Ingestor.run(target: db, takes: [], timezone: ist)
        #expect(result.outcome == .ok)
    }

    @Test("a failure is recorded as a diagnostic row")
    func failuresAreRecorded() throws {
        let (db, url) = try freshTarget()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try Ingestor.run(target: db, takes: [take(1)], timezone: ist)
        _ = try Ingestor.run(target: db, takes: [], timezone: ist)

        let outcomes =
            try db.query("SELECT outcome FROM ingest_run ORDER BY run_id") { $0.text(0) ?? "" }
        #expect(outcomes == ["ok", "failedEmpty"])
    }

    // MARK: - Metric correctness

    @Test("speed eligibility excludes short, long and untrustworthy takes")
    func speedEligibility() throws {
        let (db, url) = try freshTarget()
        defer { try? FileManager.default.removeItem(at: url) }

        let batch = [
            take(1, day: 3, duration: 30, words: 100),  // eligible
            take(2, day: 4, duration: 400, words: 100),  // orb left open
            take(3, day: 5, duration: 2, words: 100),  // accidental
            take(4, day: 6, duration: 30, words: 3),  // too few words
        ]
        _ = try Ingestor.run(target: db, takes: batch, timezone: ist)

        // Aggregate across every day: these four takes deliberately span four
        // days so the eligibility filter is tested without intra-day folding.
        let rollup =
            try db.query(
                "SELECT SUM(takes_dictate), SUM(mic_ms), SUM(speech_ms), SUM(speech_words)"
                    + " FROM daily_rollup"
            ) {
                (
                    takes: $0.int64OrZero(0), mic: $0.int64OrZero(1),
                    speech: $0.int64OrZero(2), words: $0.int64OrZero(3)
                )
            }
            .first!

        #expect(rollup.takes == 4, "all takes still count towards the take total")
        #expect(rollup.mic == 462_000, "mic time is unfiltered: 30+400+2+30 seconds")
        #expect(rollup.speech == 30_000, "only the eligible take contributes to speech time")
        #expect(rollup.words == 100)
    }

    @Test("clipboard rows are counted but never as speech")
    func clipboardRows() throws {
        let (db, url) = try freshTarget()
        defer { try? FileManager.default.removeItem(at: url) }

        var clipboard = take(2, words: 5_000)
        clipboard = ExtractedTake(
            kiviPK: clipboard.kiviPK,
            takenAt: clipboard.takenAt,
            dayLocal: clipboard.dayLocal,
            hourLocal: clipboard.hourLocal,
            mode: "clipboard",
            bundleID: nil,
            bundleKey: nil,
            durationMS: nil,
            wordCount: 5_000,
            charCount: 30_000,
            isComplete: true,
            isTruncated: false,
            srcUpdatedAt: clipboard.srcUpdatedAt
        )

        _ = try Ingestor.run(target: db, takes: [take(1, words: 100), clipboard], timezone: ist)

        let row =
            try db.query(
                "SELECT takes_dictate, takes_clipboard, mic_ms, words FROM daily_rollup"
            ) { (d: $0.int64OrZero(0), c: $0.int64OrZero(1), mic: $0.int64OrZero(2), w: $0.int64OrZero(3)) }
            .first!

        #expect(row.d == 1)
        #expect(row.c == 1)
        #expect(row.mic == 30_000, "clipboard rows contribute no mic time")
        #expect(row.w == 5_100, "words are tracked separately from speech")
    }

    @Test("per-app rollup groups case-insensitively and stays consistent with day totals")
    func appRollup() throws {
        let (db, url) = try freshTarget()
        defer { try? FileManager.default.removeItem(at: url) }

        let batch = [
            take(1, day: 3, words: 10, app: "dev.warp.Warp-Stable"),
            take(2, day: 4, words: 20, app: "dev.warp.warp-stable"),
            take(3, day: 5, words: 30, app: "com.openai.codex"),
        ]
        _ = try Ingestor.run(target: db, takes: batch, timezone: ist)

        // daily_app_rollup is one row per day per app, so aggregate for a range view.
        let apps =
            try db.query(
                "SELECT bundle_key, MAX(bundle_id), SUM(words) FROM daily_app_rollup"
                    + " GROUP BY bundle_key ORDER BY bundle_key"
            ) { (key: $0.text(0) ?? "", id: $0.text(1) ?? "", words: $0.int64OrZero(2)) }

        #expect(apps.count == 2, "two spellings of Warp must collapse into one app")
        #expect(apps[0].key == "com.openai.codex")
        #expect(apps[0].words == 30)
        #expect(apps[1].key == "dev.warp.warp-stable")
        #expect(apps[1].words == 30, "10 words on day 3 plus 20 on day 4")

        // Retire the day-4 Warp take upstream.
        //
        // The retired take STAYS in the per-app split, and that is deliberate:
        // day totals count retired takes too, so dropping them here would make the
        // app list sum to less than the headline above it — the same contradiction
        // in the other direction.
        //
        // (This test previously claimed the opposite, and passed only because the
        // day-4 row vanished from the aggregate rather than because retired takes
        // were filtered. A maintainer "fixing" the code to match that message
        // would have broken the consistency guarantee.)
        _ = try Ingestor.run(
            target: db,
            takes: [
                take(1, day: 3, words: 10, app: "dev.warp.Warp-Stable"),
                take(3, day: 5, words: 30, app: "com.openai.codex"),
            ],
            timezone: ist
        )
        let after =
            try db.query("SELECT bundle_key, words FROM daily_app_rollup ORDER BY bundle_key") {
                ($0.text(0) ?? "", $0.int64OrZero(1))
            }
        #expect(
            after.contains { $0.0 == "dev.warp.warp-stable" && $0.1 == 10 },
            "with day 4 emptied of live takes, Warp's day-3 row is untouched"
        )
        #expect(
            try db.scalarInt64("SELECT SUM(words) FROM daily_rollup") == 60,
            "day totals must still include the retired take"
        )
        #expect(
            try db.scalarInt64("SELECT SUM(words) FROM daily_app_rollup") == 60,
            "the per-app split must sum to the day total — retired takes stay in both"
        )
    }

    @Test("the per-app split uses the same dictation-only basis as the headline")
    func appRollupMatchesHeadlineBasis() throws {
        let (db, url) = try freshTarget()
        defer { try? FileManager.default.removeItem(at: url) }

        // One dictation and one clipboard capture into the same app. The headline
        // counts only the first; the per-app list has to agree, or the numbers a
        // few rows apart contradict each other.
        _ = try Ingestor.run(
            target: db,
            takes: [
                take(1, day: 3, words: 100, app: "com.openai.codex"),
                take(2, day: 3, words: 5000, app: "com.openai.codex", mode: "clipboard"),
            ],
            timezone: ist
        )

        let headlineWords = try db.scalarInt64("SELECT SUM(words_dictate) FROM daily_rollup")
        let appWords = try db.scalarInt64("SELECT SUM(words_dictate) FROM daily_app_rollup")
        let appTakes = try db.scalarInt64("SELECT SUM(takes_dictate) FROM daily_app_rollup")

        #expect(headlineWords == 100, "the headline is dictation-only")
        #expect(
            appWords == headlineWords,
            "the per-app split must sum to the headline, not to a different basis"
        )
        #expect(appTakes == 1, "the clipboard capture is not a dictation take")

        // Clipboard captures are still ingested and still recorded — just not
        // counted as speech.
        #expect(try db.scalarInt64("SELECT SUM(words) FROM daily_rollup") == 5100)
    }

    @Test("timezone projection decides the day, not UTC")
    func timezoneProjection() throws {
        let (db, url) = try freshTarget()
        defer { try? FileManager.default.removeItem(at: url) }

        let calendar = DayKey.calendar(timezone: ist)
        let instant = calendar.date(
            from: DateComponents(timeZone: ist, year: 2026, month: 10, day: 3, hour: 23, minute: 30)
        )!

        _ = try Ingestor.run(
            target: db,
            takes: [take(1, day: 3, hour: 23)],
            timezone: ist,
            now: instant
        )

        #expect(try db.scalarInt64("SELECT count(*) FROM daily_rollup WHERE day_local='2026-10-03'") == 1)
    }

    @Test("a take edited upstream is re-read once its update time advances")
    func editedTake() throws {
        let (db, url) = try freshTarget()
        defer { try? FileManager.default.removeItem(at: url) }

        let original = take(1, words: 100)
        _ = try Ingestor.run(target: db, takes: [original], timezone: ist)
        #expect(try db.scalarInt64("SELECT words FROM daily_rollup") == 100)

        // Same pk, newer src_updated_at, different text.
        let edited = ExtractedTake(
            kiviPK: original.kiviPK,
            takenAt: original.takenAt,
            dayLocal: original.dayLocal,
            hourLocal: original.hourLocal,
            mode: original.mode,
            bundleID: original.bundleID,
            bundleKey: original.bundleKey,
            durationMS: original.durationMS,
            wordCount: 250,
            charCount: 1_500,
            isComplete: true,
            isTruncated: false,
            srcUpdatedAt: original.srcUpdatedAt + 60
        )
        let result = try Ingestor.run(target: db, takes: [edited], timezone: ist)

        #expect(result.outcome == .ok)
        #expect(try db.scalarInt64("SELECT words FROM daily_rollup") == 250)
        #expect(try db.scalarInt64("SELECT count(*) FROM take") == 1, "no duplicate fact")
    }

    @Test("source store records version and schema hash")
    func sourceStoreMetadata() throws {
        let (db, url) = try freshTarget()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try Ingestor.run(
            target: db,
            takes: [take(1)],
            timezone: ist,
            storePath: "/tmp/Kivi.store",
            kiviAppVersion: "2026.09.25.1212",
            kiviModelVersion: "1",
            schemaHash: "abc123",
            kiviInstallationID: "7AC70A09",
            incognitoNow: true,
            takeSuccess: 546
        )

        let rows =
            try db.query(
                "SELECT store_path, kivi_app_version, schema_hash, max_pk_seen FROM source_store"
            ) { ($0.text(0) ?? "", $0.text(1) ?? "", $0.text(2) ?? "", $0.int64OrZero(3)) }

        #expect(rows.count == 1)
        #expect(rows[0].0 == "/tmp/Kivi.store")
        #expect(rows[0].1 == "2026.09.25.1212")
        #expect(rows[0].2 == "abc123")
        #expect(rows[0].3 == 1)

        let run =
            try db.query("SELECT incognito_at_run, take_success_at_run FROM ingest_run") {
                ($0.int64OrZero(0), $0.int64OrZero(1))
            }.first!
        #expect(run.0 == 1)
        #expect(run.1 == 546)
    }

    @Test("no text ever reaches the facts table")
    func noTextPersisted() throws {
        let (db, url) = try freshTarget()
        defer { try? FileManager.default.removeItem(at: url) }

        let marker = "SECRET-TRANSCRIPT-MARKER"
        let source = try Fixture.makeKiviStore([
            .init(pk: 1, durationSeconds: 30, text: "a take containing \(marker) inside it")
        ])
        defer { try? FileManager.default.removeItem(at: source) }

        let snapshotDB = try Database(path: source.path, readOnly: true)
        let extracted = try Extractor.extract(from: snapshotDB, timezone: ist)
        _ = try Ingestor.run(target: db, takes: extracted, timezone: ist)

        // Serialise every row of every table and assert the marker is absent.
        let tables =
            try db.query("SELECT name FROM sqlite_master WHERE type='table'") { $0.text(0) ?? "" }
        for table in tables {
            let columns =
                try db.query("PRAGMA table_info(\(table))") { $0.text(1) ?? "" }
            guard !columns.isEmpty else { continue }
            let projection =
                columns.map { "quote(\"\($0)\")" }.joined(separator: " || ' | ' || ")
            let dump = try db.query("SELECT \(projection) FROM \(table)") { $0.text(0) ?? "" }
            for row in dump where row.contains(marker) {
                Issue.record("transcript text leaked into table \(table): \(row)")
            }
        }
    }
}
