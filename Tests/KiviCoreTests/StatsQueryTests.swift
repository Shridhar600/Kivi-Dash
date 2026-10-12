import Foundation
import Testing

@testable import KiviCore

@Suite("Stats queries")
struct StatsQueryTests {
    private let ist = TimeZone(identifier: "Asia/Kolkata")!

    /// Seeds a database through the real ingest path so the tests exercise the
    /// same code the app does, not a hand-written fixture.
    private func seeded() throws -> (Database, URL) {
        let url = Fixture.tempFile()
        let db = try Database(path: url.path)
        try Schema.apply(to: db)
        return (db, url)
    }

    private func take(
        _ pk: Int64,
        day: Int,
        hour: Int = 10,
        duration: Double? = 30,
        words: Int = 120,
        app: String? = "com.openai.codex"
    ) -> ExtractedTake {
        let start = DayKey.calendar(timezone: ist).date(
            from: DateComponents(timeZone: ist, year: 2026, month: 10, day: day, hour: hour)
        )!
        let at = Int64(start.timeIntervalSince1970)
        return ExtractedTake(
            kiviPK: pk,
            takenAt: at,
            dayLocal: DayKey.string(fromUnixSeconds: at, timezone: ist),
            hourLocal: hour,
            mode: "dictate",
            bundleID: app,
            bundleKey: app?.lowercased(),
            durationMS: duration.map { Int64($0 * 1000) },
            wordCount: words,
            charCount: words * 6,
            isComplete: true,
            isTruncated: false,
            srcUpdatedAt: at
        )
    }

    private var now: Date {
        DayKey.calendar(timezone: ist).date(
            from: DateComponents(timeZone: ist, year: 2026, month: 10, day: 6, hour: 12)
        )!
    }

    @Test("totals aggregate over the range")
    func totals() throws {
        let (db, url) = try seeded()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try Ingestor.run(
            target: db,
            takes: [
                take(1, day: 3, words: 100, app: "com.openai.codex"),
                take(2, day: 4, words: 50, app: "dev.warp.Warp-Stable"),
                take(3, day: 6, words: 25, app: "com.openai.codex"),
            ],
            timezone: ist,
            now: now
        )

        let week = try StatsQuery(db: db, timezone: ist).totals(for: .week7, now: now)
        #expect(week.words == 175)
        #expect(week.takes == 3)
        #expect(week.micSeconds == 90)
        #expect(week.activeDays == 3)

        let today = try StatsQuery(db: db, timezone: ist).totals(for: .today, now: now)
        #expect(today.words == 25, "Today must only cover today")
        #expect(today.takes == 1)
    }

    /// The headline correctness test: WPM must be a ratio of sums.
    @Test("wpm is a ratio of sums, not a mean of per-take rates")
    func wpmRatioOfSums() throws {
        let (db, url) = try seeded()
        defer { try? FileManager.default.removeItem(at: url) }

        // Take A: 10 words in 10 s  ->  60 wpm
        // Take B: 200 words in 20 s -> 600 wpm
        // Mean of the two rates = 330 wpm. Ratio of sums = 60 * 210 / 30 = 420.
        // They are far enough apart that a wrong implementation cannot pass.
        _ = try Ingestor.run(
            target: db,
            takes: [
                take(1, day: 6, hour: 1, duration: 10, words: 10),
                take(2, day: 6, hour: 2, duration: 20, words: 200),
            ],
            timezone: ist,
            now: now
        )

        let totals = try StatsQuery(db: db, timezone: ist).totals(for: .today, now: now)
        guard let wpm = totals.wpm else {
            Issue.record("expected a wpm value")
            return
        }
        #expect(abs(wpm - 420) < 0.5, "expected 420 wpm, got \(wpm)")
        #expect(totals.speedSampleTakes == 2)
        #expect(totals.speedSampleTotal == 2)
    }

    @Test("wpm is nil rather than zero when nothing is eligible")
    func wpmNilWhenNoSpeech() throws {
        let (db, url) = try seeded()
        defer { try? FileManager.default.removeItem(at: url) }
        let totals = try StatsQuery(db: db, timezone: ist).totals(for: .week7, now: now)
        #expect(totals.wpm == nil)
    }

    @Test("ineligible takes are excluded from the rate but counted as takes")
    func ineligibleTakesExcludedFromRate() throws {
        let (db, url) = try seeded()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try Ingestor.run(
            target: db,
            takes: [
                take(1, day: 6, duration: 30, words: 100),
                take(2, day: 6, hour: 11, duration: 900, words: 900),
            ],
            timezone: ist,
            now: now
        )

        let totals = try StatsQuery(db: db, timezone: ist).totals(for: .today, now: now)
        #expect(totals.takes == 2)
        #expect(totals.speedSampleTakes == 1)
        #expect(totals.micSeconds == 930, "mic time is unfiltered")
        #expect(totals.speechSeconds == 30)
    }

    @Test("daily series is zero-filled and stable in width")
    func seriesZeroFilled() throws {
        let (db, url) = try seeded()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try Ingestor.run(
            target: db,
            takes: [take(1, day: 3, words: 100), take(2, day: 6, words: 40)],
            timezone: ist,
            now: now
        )

        let series = try StatsQuery(db: db, timezone: ist).dailySeries(endingAt: "2026-10-06", count: 7)
        #expect(series.count == 7, "the sparkline must not change width as data arrives")
        #expect(series.first?.day == "2026-09-30")
        #expect(series.last?.day == "2026-10-06")
        #expect(series.map(\.words) == [0, 0, 0, 100, 0, 0, 40])
    }

    @Test("heatmap buckets by local day and hour")
    func heatmapBuckets() throws {
        let (db, url) = try seeded()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try Ingestor.run(
            target: db,
            takes: [
                take(1, day: 6, hour: 2, words: 100),
                take(2, day: 6, hour: 2, words: 50),
                take(3, day: 6, hour: 14, words: 20),
                take(4, day: 5, hour: 9, words: 7),
            ],
            timezone: ist,
            now: now
        )

        let rows = try StatsQuery(db: db, timezone: ist).heatmap(endingAt: "2026-10-06", dayCount: 2)
        #expect(rows.count == 2)
        #expect(rows[0].day == "2026-10-05")
        #expect(rows[0].total == 7)
        #expect(rows[1].total == 170)
        #expect(rows[1].wordsByHour.count == 24)
        #expect(rows[1].wordsByHour[2] == 150, "two takes in the same hour must add up")
        #expect(rows[1].wordsByHour[14] == 20)
        #expect(rows[1].wordsByHour[3] == 0)
    }

    @Test("streak counts consecutive days and allows yesterday")
    func streak() throws {
        let (db, url) = try seeded()
        defer { try? FileManager.default.removeItem(at: url) }

        // 3, 4 and 6 July-equivalent: a gap on the 5th breaks the streak at
        // today, but ending yesterday it still counts the run.
        _ = try Ingestor.run(
            target: db,
            takes: [take(1, day: 3), take(2, day: 4), take(3, day: 5)],
            timezone: ist,
            now: now
        )
        #expect(
            try StatsQuery(db: db, timezone: ist).streak(now: now) == 3,
            "activity ending yesterday still counts as a live streak"
        )

        _ = try Ingestor.run(
            target: db,
            takes: [take(1, day: 3), take(2, day: 4), take(3, day: 5), take(4, day: 6)],
            timezone: ist,
            now: now
        )
        #expect(try StatsQuery(db: db, timezone: ist).streak(now: now) == 4)

        // Nothing today but activity yesterday: still a streak of 3.
        let yesterday = DayKey.calendar(timezone: ist).date(
            from: DateComponents(timeZone: ist, year: 2026, month: 10, day: 5, hour: 12)
        )!
        let fresh = try seeded()
        defer { try? FileManager.default.removeItem(at: fresh.1) }
        _ = try Ingestor.run(
            target: fresh.0,
            takes: [take(1, day: 3), take(2, day: 4), take(3, day: 5)],
            timezone: ist,
            now: yesterday
        )
        #expect(try StatsQuery(db: fresh.0, timezone: ist).streak(now: yesterday) == 3)
    }

    @Test("apps are ranked by words and merged case-insensitively")
    func appRanking() throws {
        let (db, url) = try seeded()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try Ingestor.run(
            target: db,
            takes: [
                take(1, day: 6, words: 300, app: "com.openai.codex"),
                take(2, day: 6, hour: 11, words: 100, app: "dev.warp.Warp-Stable"),
                take(3, day: 6, hour: 12, words: 100, app: "dev.warp.warp-stable"),
            ],
            timezone: ist,
            now: now
        )

        let apps = try StatsQuery(db: db, timezone: ist).apps(for: .today, now: now)
        #expect(apps.count == 2)
        #expect(apps[0].bundleKey == "com.openai.codex")
        #expect(apps[0].words == 300)
        #expect(apps[1].bundleKey == "dev.warp.warp-stable")
        #expect(apps[1].words == 200)
        #expect(apps[1].takes == 2)
    }

    @Test("coverage reports held versus Kivi's own count")
    func coverage() throws {
        let (db, url) = try seeded()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try Ingestor.run(
            target: db,
            takes: [take(1, day: 6), take(2, day: 6, hour: 11)],
            timezone: ist,
            now: now
        )
        try CoverageSampler.record(
            .init(
                installID: "ABC",
                takeStarted: 640,
                takeSuccess: 546,
                takeCancelled: 35,
                takeFailEmpty: 44,
                pasteVerified: 348,
                incognitoNow: true,
                privacyMode: true
            ),
            in: db,
            now: now
        )
        _ = try Ingestor.run(
            target: db,
            takes: [take(1, day: 6), take(2, day: 6, hour: 11)],
            timezone: ist,
            now: now,
            takeSuccess: 546
        )

        let coverage = try StatsQuery(db: db, timezone: ist).coverage()
        #expect(coverage.generation == 1)
        #expect(coverage.installID == "ABC")
        #expect(coverage.reported == 546)
        #expect(coverage.held == 2)
        guard let fraction = coverage.fraction else {
            Issue.record("expected a coverage fraction")
            return
        }
        #expect(fraction < 0.01, "two held out of 546 is a tiny fraction")
    }

    @Test("a counter reset starts a new generation instead of charting a cliff")
    func counterResetCreatesGeneration() throws {
        let (db, url) = try seeded()
        defer { try? FileManager.default.removeItem(at: url) }

        try CoverageSampler.record(
            .init(
                installID: "ABC",
                takeStarted: 640,
                takeSuccess: 546,
                takeCancelled: nil,
                takeFailEmpty: nil,
                pasteVerified: nil,
                incognitoNow: false,
                privacyMode: true
            ),
            in: db,
            now: now
        )
        try CoverageSampler.record(
            .init(
                installID: "ABC",
                takeStarted: 5,
                takeSuccess: 4,
                takeCancelled: nil,
                takeFailEmpty: nil,
                pasteVerified: nil,
                incognitoNow: false,
                privacyMode: true
            ),
            in: db,
            now: now.addingTimeInterval(60)
        )

        let generations =
            try db.query("SELECT generation, reset_reason FROM coverage_generation ORDER BY generation") {
                (Int($0.int64OrZero(0)), $0.text(1))
            }
        #expect(generations.count == 2, "a reset must open a new generation")
        #expect(generations[1].0 == 2)
        #expect(generations[1].1 == "counter_regressed")
    }

    @Test("a changed installation id also starts a new generation")
    func installChangeCreatesGeneration() throws {
        let (db, url) = try seeded()
        defer { try? FileManager.default.removeItem(at: url) }

        try CoverageSampler.record(
            .init(
                installID: "OLD",
                takeStarted: 100,
                takeSuccess: 90,
                takeCancelled: nil,
                takeFailEmpty: nil,
                pasteVerified: nil,
                incognitoNow: false,
                privacyMode: true
            ),
            in: db,
            now: now
        )
        try CoverageSampler.record(
            .init(
                installID: "NEW",
                takeStarted: 3,
                takeSuccess: 2,
                takeCancelled: nil,
                takeFailEmpty: nil,
                pasteVerified: nil,
                incognitoNow: false,
                privacyMode: true
            ),
            in: db,
            now: now.addingTimeInterval(60)
        )

        let rows = try db.query("SELECT reset_reason FROM coverage_generation WHERE generation = 2") {
            $0.text(0)
        }
        #expect(rows == ["installation_id_changed"])
    }

    @Test("status distinguishes healthy from stale and from failure")
    func statusLevels() throws {
        let (db, url) = try seeded()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try Ingestor.run(target: db, takes: [take(1, day: 6)], timezone: ist, now: now)
        var status = try StatsQuery(db: db, timezone: ist).ingestStatus()
        #expect(status.outcome == .ok)
        // `now` is pinned to the fixture clock so this cannot rot as wall time
        // advances: the ingest ran "now", so evaluating staleness at "now" is ok.
        #expect(status.level(staleAfter: 1800, now: now) == .ok)

        status.lastSuccessAt = now.addingTimeInterval(-7200)
        #expect(status.level(staleAfter: 1800, now: now) == .stale)

        status.outcome = .failedSchema
        #expect(status.level(staleAfter: 1800, now: now) == .needsAttention)
        #expect(status.level(staleAfter: 1800, now: now).symbolName == "exclamationmark.octagon")

        status.outcome = .skippedBusy
        #expect(status.level(staleAfter: 1800, now: now) == .transientFailure)
    }

    @Test("range day bounds cover exactly the requested window")
    func dayBounds() throws {
        let (db, url) = try seeded()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try Ingestor.run(target: db, takes: [take(1, day: 3)], timezone: ist, now: now)
        let query = StatsQuery(db: db, timezone: ist)

        guard let today = try query.dayBounds(for: .today, now: now),
            let week = try query.dayBounds(for: .week7, now: now),
            let all = try query.dayBounds(for: .all, now: now)
        else {
            Issue.record("expected all three ranges to have bounds")
            return
        }
        #expect(today.from == "2026-10-06" && today.to == "2026-10-06")
        #expect(week.from == "2026-09-30")
        #expect(all.from == "2026-10-03", "all-time starts at our earliest day")
    }
}
