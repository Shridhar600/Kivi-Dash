import Foundation
import Testing

@testable import KiviCore

/// Regression tests for defects found in adversarial review. Each one encodes a
/// failure that actually happened, so it cannot regress silently.
@Suite("Regressions")
struct RegressionTests {
    private let ist = TimeZone(identifier: "Asia/Kolkata")!

    // MARK: - Non-finite REALs

    @Test("a non-finite REAL does not crash and is treated as unusable")
    func nonFiniteReal() throws {
        let url = Fixture.tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database(path: url.path)
        try db.execute(Fixture.captureDDL)
        try db.execute(
            "INSERT INTO ZCAPTURE (ZCREATEDAT, ZMODE, ZSTATUS, ZFORMATTEDTEXT) VALUES (1e999, 'dictate', 'complete', 'hi')"
        )

        // Note the double optional: the row exists, its *value* must be nil.
        let values = try db.query("SELECT ZCREATEDAT FROM ZCAPTURE") { $0.double(0) }
        #expect(values.count == 1)
        #expect(values == [nil], "a non-finite REAL must read as nil, never as Inf")

        // The conversion that used to trap.
        let converted = DayKey.unixSeconds(fromAppleReference: .infinity)
        #expect(converted == 0)
        #expect(DayKey.unixSeconds(fromAppleReference: .nan) == 0)
        #expect(DayKey.unixSeconds(fromAppleReference: 1e300) == 0)
    }

    @Test("a take with an Inf duration is ignored rather than producing negative mic time")
    func infiniteDuration() throws {
        let url = Fixture.tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database(path: url.path)
        try db.execute(Fixture.captureDDL)
        try db.execute(
            """
            INSERT INTO ZCAPTURE (ZCREATEDAT, ZDURATIONSECONDS, ZMODE, ZSTATUS, ZFORMATTEDTEXT)
            VALUES (812918638, 1e999, 'dictate', 'complete', 'one two three four five six')
            """
        )

        let extracted = try Extractor.extract(from: db, timezone: ist)
        #expect(extracted.count == 1)
        #expect(extracted[0].durationMS == nil, "an unusable duration must not become a number")
        #expect(!extracted[0].isSpeedEligible)
    }

    @Test("a huge-but-finite duration does not crash the process")
    func hugeFiniteDuration() throws {
        let url = Fixture.tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database(path: url.path)
        try db.execute(Fixture.captureDDL)

        // The gap this covers: `Row.double` rejects Inf/NaN, so the `Inf` test
        // above never reached the conversion. 1e300 is perfectly *finite* and
        // sails through that guard — and `Int64(1e303)` is a runtime trap, not a
        // throwable error, so the whole process died with SIGTRAP.
        try db.execute(
            """
            INSERT INTO ZCAPTURE (ZCREATEDAT, ZDURATIONSECONDS, ZMODE, ZSTATUS, ZFORMATTEDTEXT)
            VALUES (812918638, 1e300, 'dictate', 'complete', 'one two three four five six')
            """
        )

        let extracted = try Extractor.extract(from: db, timezone: ist)
        #expect(extracted.count == 1, "the take must still be extracted")
        #expect(extracted[0].durationMS == nil, "an unrepresentable duration must read as unknown")
        #expect(
            extracted[0].wordCount == 6,
            "the words are still known and must not be lost with the duration"
        )
        #expect(!extracted[0].isSpeedEligible)
    }

    @Test("a negative duration is clamped instead of subtracting from mic time")
    func negativeDuration() throws {
        let url = Fixture.tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database(path: url.path)
        try db.execute(Fixture.captureDDL)
        try db.execute(
            """
            INSERT INTO ZCAPTURE (ZCREATEDAT, ZDURATIONSECONDS, ZMODE, ZSTATUS, ZFORMATTEDTEXT)
            VALUES (812918638, -0.9, 'dictate', 'complete', 'one two three four five six')
            """
        )

        let extracted = try Extractor.extract(from: db, timezone: ist)
        #expect(extracted[0].durationMS == 0, "a negative duration must clamp to zero")
    }

    @Test("a take with no timestamp is dropped rather than dated to 2001")
    func nullCreatedAt() throws {
        let url = Fixture.tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database(path: url.path)
        try db.execute(Fixture.captureDDL)
        try db.execute(
            "INSERT INTO ZCAPTURE (ZCREATEDAT, ZMODE, ZSTATUS, ZFORMATTEDTEXT) VALUES (NULL, 'dictate', 'complete', 'one two three')"
        )

        // Defaulting a missing timestamp to zero lands the take on the Apple
        // reference date, 2001-01-01 — a permanent, entirely fictitious rollup row
        // that quietly inflates all-time totals forever.
        let extracted = try Extractor.extract(from: db, timezone: ist)
        #expect(extracted.isEmpty, "an undatable take must not be filed under a made-up day")
    }

    // MARK: - Kivi reinstall

    @Test("a Kivi reinstall does not overwrite recorded history")
    func reinstallKeepsHistory() throws {
        let url = Fixture.tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database(path: url.path)
        try Schema.apply(to: db)

        func take(pk: Int64, words: Int) -> ExtractedTake {
            ExtractedTake(
                kiviPK: pk,
                takenAt: 1_789_000_000,
                dayLocal: "2026-10-06",
                hourLocal: 12,
                mode: "dictate",
                bundleID: "com.openai.codex",
                bundleKey: "com.openai.codex",
                durationMS: 30_000,
                wordCount: words,
                charCount: words * 6,
                isComplete: true,
                isTruncated: false,
                srcUpdatedAt: 1_789_000_000
            )
        }

        // Install A: a 900-word take at Z_PK 1.
        _ = try Ingestor.run(
            target: db,
            takes: [take(pk: 1, words: 900)],
            timezone: ist,
            kiviInstallationID: "install-A"
        )
        #expect(try db.scalarInt64("SELECT sum(word_count) FROM take") == 900)

        // Install B restarts Z_PK at 1. Same pk, different take, newer timestamp.
        _ = try Ingestor.run(
            target: db,
            takes: [take(pk: 1, words: 4)],
            timezone: ist,
            kiviInstallationID: "install-B"
        )

        #expect(
            try db.scalarInt64("SELECT count(*) FROM source_store") == 2,
            "a new installation must open a new source"
        )
        #expect(
            try db.scalarInt64("SELECT sum(word_count) FROM take") == 904,
            "the first install's 900 words must survive, not be overwritten by 4"
        )
        #expect(
            try db.scalarInt64("SELECT word_count FROM take WHERE source_id = 1") == 900,
            "the original take must be untouched"
        )
        #expect(
            try db.scalarInt64("SELECT count(*) FROM take WHERE retired_at IS NOT NULL") == 0,
            "overwriting was silent — nothing was retired"
        )

        // And a re-run of the *same* install must stay idempotent.
        _ = try Ingestor.run(
            target: db,
            takes: [take(pk: 1, words: 4)],
            timezone: ist,
            kiviInstallationID: "install-B"
        )
        #expect(
            try db.scalarInt64("SELECT sum(word_count) FROM take") == 904,
            "a normal re-run must not allocate yet another source"
        )
        #expect(try db.scalarInt64("SELECT count(*) FROM source_store") == 2)
    }

    // MARK: - Snapshot lifecycle

    @Test("a failed snapshot leaves no file behind")
    func failedSnapshotLeavesNothing() throws {
        let url = Fixture.tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database(path: url.path)
        try db.execute(Fixture.captureDDL)

        // Not a database at all: opening/reading it fails after the destination
        // file has already been created.
        let bogus = Fixture.tempFile(".txt")
        defer { try? FileManager.default.removeItem(at: bogus) }
        try Data("not a database".utf8).write(to: bogus)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ks-sweep-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: (any Error).self) {
            try Snapshot.take(from: bogus, into: dir)
        }

        let leftovers =
            (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(leftovers.isEmpty, "a failed snapshot must not leave a file: \(leftovers)")
    }

    @Test("snaphots are private to the user from the moment they are created")
    func snapshotPermissions() throws {
        let source = try Fixture.makeKiviStore([.init(pk: 1)])
        defer { try? FileManager.default.removeItem(at: source) }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ks-perm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = try Snapshot.take(from: source, into: dir)
        defer { Snapshot.discard(snapshot) }

        let attributes = try FileManager.default.attributesOfItem(atPath: snapshot.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        #expect(mode & 0o077 == 0, "snapshot must not be group- or world-readable, got \(String(mode, radix: 8))")
    }

    @Test("orphaned snapshots are swept")
    func sweepOrphans() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ks-orphan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for name in ["kivi-snapshot-a.db", "kivi-snapshot-b.db-shm", "unrelated.txt"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }

        #expect(Snapshot.sweep(directory: dir) == 2)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(remaining == ["unrelated.txt"], "sweep must only touch our own snapshots")
    }

    // MARK: - Facts and rollups stay in agreement

    @Test("an upstream edit that keeps its timestamp is ignored consistently")
    func editsWithoutNewTimestampStayConsistent() throws {
        let url = Fixture.tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database(path: url.path)
        try Schema.apply(to: db)

        func make(pk: Int64, words: Int) -> ExtractedTake {
            let at = Int64(1_700_000_000)
            return ExtractedTake(
                kiviPK: pk,
                takenAt: at,
                dayLocal: "2026-10-03",
                hourLocal: 10,
                mode: "dictate",
                bundleID: "com.openai.codex",
                bundleKey: "com.openai.codex",
                durationMS: 30_000,
                wordCount: words,
                charCount: words * 6,
                isComplete: true,
                isTruncated: false,
                srcUpdatedAt: at
            )
        }

        _ = try Ingestor.run(target: db, takes: [make(pk: 1, words: 100)], timezone: ist)

        // Upstream rewrites the text but does not move ZUPDATEDAT. We must keep
        // our recorded value — and the rollup must still agree with the fact.
        _ = try Ingestor.run(target: db, takes: [make(pk: 1, words: 999)], timezone: ist)

        let fact = try db.scalarInt64("SELECT word_count FROM take") ?? -1
        let rolled = try db.scalarInt64("SELECT words FROM daily_rollup") ?? -1
        #expect(fact == rolled, "rollup \\(rolled) must equal fact \\(fact)")
    }

    // MARK: - Metric honesty

    @Test("spoken words exclude clipboard text")
    func spokenWordsExcludeClipboard() throws {
        let url = Fixture.tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database(path: url.path)
        try Schema.apply(to: db)

        func make(_ pk: Int64, mode: String, words: Int, app: String?) -> ExtractedTake {
            let at = Int64(1_700_000_000)
            return ExtractedTake(
                kiviPK: pk,
                takenAt: at,
                dayLocal: "2026-10-03",
                hourLocal: 10,
                mode: mode,
                bundleID: app,
                bundleKey: app?.lowercased(),
                durationMS: mode == "dictate" ? 30_000 : nil,
                wordCount: words,
                charCount: words * 6,
                isComplete: true,
                isTruncated: false,
                srcUpdatedAt: at
            )
        }

        _ = try Ingestor.run(
            target: db,
            takes: [
                make(1, mode: "dictate", words: 100, app: "com.openai.codex"),
                make(2, mode: "clipboard", words: 5_000, app: nil),
            ],
            timezone: ist
        )

        let totals = try StatsQuery(db: db, timezone: ist).totals(for: .all)
        #expect(totals.words == 100, "spoken words must not include clipboard text")
        #expect(totals.wordsIncludingClipboard == 5_100)
    }

    @Test("active days require dictation, not a stray clipboard paste")
    func activeDaysRequireDictation() throws {
        let url = Fixture.tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database(path: url.path)
        try Schema.apply(to: db)

        let at = Int64(1_700_000_000)
        let clipboardOnly = ExtractedTake(
            kiviPK: 1,
            takenAt: at,
            dayLocal: "2026-10-03",
            hourLocal: 10,
            mode: "clipboard",
            bundleID: nil,
            bundleKey: nil,
            durationMS: nil,
            wordCount: 900,
            charCount: 5_400,
            isComplete: true,
            isTruncated: false,
            srcUpdatedAt: at
        )
        _ = try Ingestor.run(target: db, takes: [clipboardOnly], timezone: ist)

        let totals = try StatsQuery(db: db, timezone: ist).totals(for: .all)
        #expect(totals.activeDays == 0, "a clipboard-only day is not an active dictation day")
        #expect(totals.streak == 0)
    }

    @Test("per-app totals include retired takes so they cannot contradict the headline")
    func appTotalsIncludeRetired() throws {
        let url = Fixture.tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database(path: url.path)
        try Schema.apply(to: db)

        func make(_ pk: Int64, day: Int, words: Int) -> ExtractedTake {
            let start = DayKey.calendar(timezone: ist).date(
                from: DateComponents(timeZone: ist, year: 2026, month: 10, day: day, hour: 10)
            )!
            let at = Int64(start.timeIntervalSince1970)
            return ExtractedTake(
                kiviPK: pk,
                takenAt: at,
                dayLocal: DayKey.string(fromUnixSeconds: at, timezone: ist),
                hourLocal: 10,
                mode: "dictate",
                bundleID: "com.openai.codex",
                bundleKey: "com.openai.codex",
                durationMS: 30_000,
                wordCount: words,
                charCount: words * 6,
                isComplete: true,
                isTruncated: false,
                srcUpdatedAt: at
            )
        }

        _ = try Ingestor.run(target: db, takes: [make(1, day: 3, words: 100)], timezone: ist)
        // Kivi purges it.
        _ = try Ingestor.run(target: db, takes: [], timezone: ist)

        let totals = try StatsQuery(db: db, timezone: ist).totals(for: .all)
        let apps = try StatsQuery(db: db, timezone: ist).apps(for: .all)

        #expect(totals.words == 100, "the retired take stays in the headline")
        #expect(
            apps.reduce(0) { $0 + $1.words } == totals.words,
            "the per-app split must not contradict the headline total"
        )
    }

    // MARK: - Source location

    @Test("picks the store that is actually Kivi's when several exist")
    func picksTheRightStore() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ks-home-\(UUID().uuidString)", isDirectory: true)
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // Another app's store, sorting first alphabetically, with its own schema.
        let decoy = Fixture.tempFile()
        try FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )
        try Database(path: decoy.path).execute("CREATE TABLE unrelated (id INTEGER PRIMARY KEY)")
        defer { try? FileManager.default.removeItem(at: decoy) }
        try FileManager.default.copyItem(at: decoy, to: appSupport.appendingPathComponent("Aardvark.store"))

        let real = try Fixture.makeKiviStore([.init(pk: 1)])
        defer { try? FileManager.default.removeItem(at: real) }
        try FileManager.default.copyItem(at: real, to: appSupport.appendingPathComponent("Kivi.store"))

        let paths = AppPaths(home: home)
        let found = try paths.locateSourceStore()
        #expect(found.lastPathComponent == "Kivi.store")
    }

    @Test("a hyphenated store name is not excluded")
    func hyphenatedStoreName() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ks-home2-\(UUID().uuidString)", isDirectory: true)
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let real = try Fixture.makeKiviStore([.init(pk: 1)])
        defer { try? FileManager.default.removeItem(at: real) }
        try FileManager.default.copyItem(
            at: real,
            to: appSupport.appendingPathComponent("Kivi-Backup.store")
        )

        let found = try AppPaths(home: home).locateSourceStore()
        #expect(found.lastPathComponent == "Kivi-Backup.store")
    }
}

extension RegressionTests {
    /// A column added to a populated rollup table defaults to 0, so without a
    /// rebuild the value stays wrong forever on days that never change.
    @Test("adding a rollup column triggers a full backfill")
    func migrationBackfillsRollups() throws {
        let url = Fixture.tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database(path: url.path)

        // An older database: schema without words_dictate, but populated.
        try db.execute(
            "CREATE TABLE daily_rollup (day_local TEXT NOT NULL, source_id INTEGER NOT NULL,"
                + " words INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (day_local, source_id))"
                + " WITHOUT ROWID"
        )
        try db.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT")
        try db.execute(
            "INSERT INTO daily_rollup (day_local, source_id, words) VALUES ('2026-10-03', 1, 4242)"
        )

        try Schema.apply(to: db)
        let flag =
            try db.scalarString("SELECT value FROM meta WHERE key = 'rollup_rebuild_required'")
        #expect(flag == "1", "adding a column to a populated table must request a rebuild")
    }
}

extension RegressionTests {
    /// A rollup with dictation but no dictation-word total is structurally wrong,
    /// and must repair itself rather than reporting zero forever.
    @Test("a rollup missing its dictation-word total repairs itself")
    func staleRollupSelfHeals() throws {
        let url = Fixture.tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database(path: url.path)
        try Schema.apply(to: db)

        func make(_ pk: Int64, words: Int) -> ExtractedTake {
            let at = Int64(1_700_000_000)
            return ExtractedTake(
                kiviPK: pk,
                takenAt: at,
                dayLocal: "2026-10-03",
                hourLocal: 10,
                mode: "dictate",
                bundleID: "com.openai.codex",
                bundleKey: "com.openai.codex",
                durationMS: 30_000,
                wordCount: words,
                charCount: words * 6,
                isComplete: true,
                isTruncated: false,
                srcUpdatedAt: at
            )
        }

        _ = try Ingestor.run(target: db, takes: [make(1, words: 120)], timezone: ist)

        // Simulate the state an older build left behind.
        try db.execute("UPDATE daily_rollup SET words_dictate = 0")

        let result = try Ingestor.run(target: db, takes: [make(1, words: 120)], timezone: ist)

        #expect(result.outcome == .ok)
        #expect(
            try db.scalarInt64("SELECT words_dictate FROM daily_rollup") == 120,
            "a stale rollup must be repaired on the next run"
        )
    }
}

extension RegressionTests {
    /// Day attribution is a projection of an immutable UTC timestamp, and 44% of
    /// takes fall on a different calendar date in UTC vs local — so a zone change
    /// has to recompute every day rather than leave two read paths disagreeing.
    @Test("a timezone change re-buckets every day")
    func timezoneChangeRebuckets() throws {
        let url = Fixture.tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database(path: url.path)
        try Schema.apply(to: db)

        // 2026-10-03 23:30 in Kolkata is 2026-10-04 in Tokyo.
        let ist = TimeZone(identifier: "Asia/Kolkata")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!

        // One instant: 23:30 on 3 Oct in Kolkata, which is already the 4th in Tokyo.
        let instant = DayKey.calendar(timezone: ist).date(
            from: DateComponents(timeZone: ist, year: 2026, month: 10, day: 3, hour: 23)
        )!
        let at = Int64(instant.timeIntervalSince1970)

        func make(_ pk: Int64, timezone: TimeZone, words: Int) -> ExtractedTake {
            ExtractedTake(
                kiviPK: pk,
                takenAt: at,
                dayLocal: DayKey.string(fromUnixSeconds: at, timezone: timezone),
                hourLocal: DayKey.hour(fromUnixSeconds: at, timezone: timezone),
                mode: "dictate",
                bundleID: "com.openai.codex",
                bundleKey: "com.openai.codex",
                durationMS: 30_000,
                wordCount: words,
                charCount: words * 6,
                isComplete: true,
                isTruncated: false,
                srcUpdatedAt: at
            )
        }

        let kolkataTake = make(1, timezone: ist, words: 100)
        _ = try Ingestor.run(target: db, takes: [kolkataTake], timezone: ist)

        #expect(try db.scalarString("SELECT value FROM meta WHERE key = 'tz_projection'") == "Asia/Kolkata")
        #expect(try db.scalarInt64("SELECT count(*) FROM daily_rollup WHERE day_local='2026-10-03'") == 1)

        // Same instant, re-projected: the take must move to the 4th.
        let tokyoTake = make(1, timezone: tokyo, words: 100)
        #expect(tokyoTake.takenAt == kolkataTake.takenAt, "the instant must not change")
        #expect(tokyoTake.dayLocal == "2026-10-04")

        let result = try Ingestor.run(target: db, takes: [tokyoTake], timezone: tokyo)

        #expect(result.outcome == .ok)
        #expect(try db.scalarString("SELECT value FROM meta WHERE key = 'tz_projection'") == "Asia/Tokyo")
        #expect(
            try db.scalarInt64("SELECT count(*) FROM daily_rollup WHERE day_local='2026-10-04'") == 1,
            "the day must be re-bucketed in the rollup too"
        )

        // The move must be a *move*. If the dirty set is collected after the
        // re-projection, the old day is orphaned: it keeps its rollup row, and
        // the single take is counted on both days — so lifetime totals, the
        // streak and the sparkline permanently double count. Assert the whole
        // shape, not just that the destination appeared.
        #expect(
            try db.scalarInt64("SELECT count(*) FROM daily_rollup WHERE day_local='2026-10-03'") == 0,
            "the vacated day must lose its rollup row"
        )
        #expect(
            try db.scalarInt64("SELECT count(*) FROM daily_rollup") == 1,
            "re-projecting must not change how many days exist"
        )
        #expect(
            try db.scalarInt64("SELECT sum(words) FROM daily_rollup") == 100,
            "one take of 100 words must be counted once, not once per bucket"
        )
    }
}
