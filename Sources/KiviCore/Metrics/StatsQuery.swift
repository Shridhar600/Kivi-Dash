import Foundation

/// Every read the UI is allowed to perform.
///
/// All of it hits the precomputed rollups, never the `take` facts — with two
/// exceptions, both index-assisted: the heatmap, which uses the
/// `(day_local, hour_local)` index, and the speed-eligible take count. Opening
/// the popover must never recompute an aggregate.
public struct StatsQuery {
    private let db: Database
    private let timezone: TimeZone

    public init(db: Database, timezone: TimeZone) {
        self.db = db
        self.timezone = timezone
    }

    /// Inclusive day range for `range`, ending today in the projection timezone.
    public func dayBounds(
        for range: StatsRange,
        now: Date = Date()
    ) throws -> (from: String, to: String)? {
        let today = DayKey.today(now: now, timezone: timezone)
        if let count = range.dayCount {
            let days = DayKey.series(endingAt: today, count: count, timezone: timezone)
            guard let first = days.first else { return nil }
            return (first, today)
        }
        guard
            let earliest = try db.scalarString("SELECT min(day_local) FROM daily_rollup"),
            !earliest.isEmpty
        else { return nil }
        return (earliest, today)
    }

    // MARK: - Totals

    public func totals(for range: StatsRange, now: Date = Date()) throws -> RangeTotals {
        var totals = RangeTotals()
        guard let bounds = try dayBounds(for: range, now: now) else { return totals }

        let row =
            try db.query(
                """
                SELECT COALESCE(SUM(takes_dictate), 0),
                       COALESCE(SUM(words), 0),
                       COALESCE(SUM(words_dictate), 0),
                       COALESCE(SUM(mic_ms), 0),
                       COALESCE(SUM(speech_ms), 0),
                       COALESCE(SUM(speech_words), 0),
                       COALESCE(SUM(takes_retired), 0),
                       COALESCE(SUM(takes_dictate > 0), 0)
                  FROM daily_rollup
                 WHERE day_local >= ? AND day_local <= ?
                """,
                bindings: [.text(bounds.from), .text(bounds.to)]
            ) {
                (
                    takes: Int($0.int64OrZero(0)),
                    words: Int($0.int64OrZero(1)),
                    wordsDictate: Int($0.int64OrZero(2)),
                    micMS: $0.int64OrZero(3),
                    speechMS: $0.int64OrZero(4),
                    speechWords: $0.int64OrZero(5),
                    retired: Int($0.int64OrZero(6)),
                    days: Int($0.int64OrZero(7))
                )
            }.first

        guard let row else { return totals }

        totals.takes = row.takes
        totals.words = row.wordsDictate
        totals.wordsIncludingClipboard = row.words
        totals.micSeconds = Int(row.micMS / 1000)
        totals.speechSeconds = Int(row.speechMS / 1000)
        totals.retiredTakes = row.retired
        totals.activeDays = row.days
        totals.speedSampleTakes = try speedSampleTakes(bounds: bounds)
        totals.speedSampleTotal = row.takes

        // Ratio of sums, never a mean of per-take ratios: a 6-word take must not
        // weigh the same as a 349-word one.
        if row.speechMS > 0 {
            totals.wpm = 60.0 * Double(row.speechWords) / (Double(row.speechMS) / 1000)
        }

        totals.streak = try streak(now: now)
        return totals
    }

    private func speedSampleTakes(bounds: (from: String, to: String)) throws -> Int {
        try db.query(
            """
            SELECT COUNT(*) FROM take
             WHERE day_local >= ? AND day_local <= ?
               AND speed_eligible = 1 AND mode = 'dictate'
            """,
            bindings: [.text(bounds.from), .text(bounds.to)]
        ) { Int($0.int64OrZero(0)) }.first ?? 0
    }

    /// Consecutive local days with at least one dictation, ending today or
    /// yesterday. Yesterday is allowed so the streak does not appear to break
    /// before you have dictated today.
    public func streak(now: Date = Date()) throws -> Int {
        let days =
            try db.query(
                "SELECT day_local FROM daily_rollup WHERE takes_dictate > 0 ORDER BY day_local DESC"
            ) { $0.text(0) ?? "" }

        guard !days.isEmpty else { return 0 }

        let today = DayKey.today(now: now, timezone: timezone)
        let yesterday =
            DayKey.series(endingAt: today, count: 2, timezone: timezone).first ?? today

        guard days[0] == today || days[0] == yesterday else { return 0 }

        let calendar = DayKey.calendar(timezone: timezone)
        var count = 1
        for index in 1..<days.count {
            guard
                let previous = DayKey.startOfDay(days[index - 1], timezone: timezone),
                let current = DayKey.startOfDay(days[index], timezone: timezone),
                let expected = calendar.date(byAdding: .day, value: -1, to: previous)
            else { break }
            guard expected == current else { break }
            count += 1
        }
        return count
    }

    // MARK: - Series

    /// One point per day, zero-filled, oldest first — so the sparkline keeps a
    /// stable width as data arrives.
    public func dailySeries(endingAt endKey: String, count: Int) throws -> [DailyPoint] {
        let keys = DayKey.series(endingAt: endKey, count: count, timezone: timezone)
        let stored =
            try db.query(
                "SELECT day_local, words_dictate, takes_dictate FROM daily_rollup"
                    + " WHERE day_local >= ? AND day_local <= ?",
                bindings: [.text(keys.first ?? ""), .text(endKey)]
            ) { (day: $0.text(0) ?? "", words: Int($0.int64OrZero(1)), takes: Int($0.int64OrZero(2))) }

        let index = Dictionary(stored.map { ($0.day, ($0.words, $0.takes)) }, uniquingKeysWith: { a, _ in a })
        return keys.map { key in
            let value = index[key] ?? (0, 0)
            return DailyPoint(day: key, words: value.0, takes: value.1)
        }
    }

    public func heatmap(endingAt endKey: String, dayCount: Int) throws -> [HeatmapRow] {
        let keys = DayKey.series(endingAt: endKey, count: dayCount, timezone: timezone)
        guard let first = keys.first, let last = keys.last else { return [] }

        let rows =
            try db.query(
                """
                SELECT day_local, hour_local, SUM(word_count)
                  FROM take
                 WHERE day_local >= ? AND day_local <= ? AND mode = 'dictate'
                 GROUP BY day_local, hour_local
                """,
                bindings: [.text(first), .text(last)]
            ) { (day: $0.text(0) ?? "", hour: Int($0.int64OrZero(1)), words: Int($0.int64OrZero(2))) }

        var byDay: [String: [Int: Int]] = [:]
        for row in rows {
            byDay[row.day, default: [:]][row.hour] = row.words
        }

        return keys.map { key in
            let hours = byDay[key] ?? [:]
            return HeatmapRow(
                day: key,
                wordsByHour: (0..<24).map { hours[$0] ?? 0 }
            )
        }
    }

    // MARK: - Apps

    public func apps(for range: StatsRange, now: Date = Date()) throws -> [AppShare] {
        guard let bounds = try dayBounds(for: range, now: now) else { return [] }

        // Dictation-only, to match the headline. `words` here counts every mode,
        // including Kivi's separate clipboard-history captures, so summing this
        // column would contradict the "Words spoken" figure directly above it.
        // Clipboard captures are still ingested and still counted — they are just
        // not what this list is about.
        return
            try db.query(
                """
                SELECT bundle_key,
                       MAX(bundle_id),
                       SUM(words_dictate),
                       SUM(takes_dictate),
                       COALESCE(SUM(speech_words), 0),
                       COALESCE(SUM(speech_ms), 0)
                  FROM daily_app_rollup
                 WHERE day_local >= ? AND day_local <= ?
                 GROUP BY bundle_key
                 ORDER BY SUM(words_dictate) DESC
                """,
                bindings: [.text(bounds.from), .text(bounds.to)]
            ) { row in
                let speechMS = row.int64OrZero(5)
                return AppShare(
                    bundleKey: row.text(0) ?? "",
                    bundleID: row.text(1) ?? "",
                    words: Int(row.int64OrZero(2)),
                    takes: Int(row.int64OrZero(3)),
                    wpm: speechMS > 0
                        ? 60.0 * Double(row.int64OrZero(4)) / (Double(speechMS) / 1000)
                        : nil
                )
            }
    }

    // MARK: - Coverage

    public func coverage() throws -> Coverage {
        let generation =
            try db.query(
                "SELECT COALESCE(MAX(generation), 0) FROM coverage_generation"
            ) { Int($0.int64OrZero(0)) }.first ?? 0

        var coverage = Coverage()
        coverage.generation = generation
        guard generation > 0 else { return coverage }

        let latest =
            try db.query(
                """
                SELECT cs.install_id, cs.take_success, cg.base_success, cg.started_at
                  FROM counter_sample cs
                  JOIN coverage_generation cg
                    ON cg.source_id = cs.source_id AND cg.generation = cs.generation
                 WHERE cs.generation = ?
                 ORDER BY cs.taken_at DESC
                 LIMIT 1
                """,
                bindings: [.int64(Int64(generation))]
            ) { ($0.text(0), $0.int64(1), $0.int64(2), $0.int64(3)) }.first

        guard let latest else { return coverage }

        coverage.installID = latest.0
        // Absolute, not the delta since this generation began. If we start
        // watching after Kivi has already counted 546 takes, a delta reads as
        // zero coverage when in fact we hold every one of them.
        coverage.reported = max(0, Int(latest.1 ?? 0))
        // Counted across every source, not one: a Kivi reinstall opens a new
        // `source_id` rather than overwriting the old one, and the takes held
        // from the previous install still count towards what we have on record.
        coverage.held =
            try db.query("SELECT COUNT(*) FROM take WHERE retired_at IS NULL") {
                Int($0.int64OrZero(0))
            }.first ?? 0

        return coverage
    }

    /// Incognito state as of the last ingest, read from our own sample table.
    ///
    /// The UI must not re-read Kivi's preferences: ingest already samples them,
    /// and the UI path is supposed to touch only our rollups.
    public func incognitoNow() throws -> Bool {
        try db.query("SELECT incognito_now FROM counter_sample ORDER BY taken_at DESC LIMIT 1") {
            ($0.int64(0) ?? 0) == 1
        }.first ?? false
    }

    // MARK: - Status

    public func ingestStatus() throws -> IngestStatus {
        var status = IngestStatus()
        let latest =
            try db.query(
                """
                SELECT outcome, COALESCE(detail, ''), started_at, rows_new,
                       rows_retired, days_rebuilt
                  FROM ingest_run ORDER BY run_id DESC LIMIT 1
                """
            ) {
                (
                    outcome: $0.text(0) ?? "", detail: $0.text(1) ?? "", at: $0.int64(2),
                    new: Int($0.int64OrZero(3)), retired: Int($0.int64OrZero(4)),
                    days: Int($0.int64OrZero(5))
                )
            }.first

        if let latest {
            status.outcome = IngestResult.Outcome(rawValue: latest.outcome) ?? .failedError
            status.detail = latest.detail
            status.lastAttemptAt = latest.at.map { Date(timeIntervalSince1970: Double($0)) }
            status.rowsNew = latest.new
            status.rowsRetired = latest.retired
            status.daysRebuilt = latest.days
        }

        let lastGood =
            try db.query(
                "SELECT MAX(started_at) FROM ingest_run WHERE outcome = 'ok'"
            ) { $0.int64(0) }.first ?? nil

        status.lastSuccessAt = lastGood.map { Date(timeIntervalSince1970: Double($0)) }
        return status
    }
}
