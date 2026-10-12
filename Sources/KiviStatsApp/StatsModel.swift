import Foundation
import KiviCore
import Observation

/// UI-facing state.
///
/// Main-actor isolated: the ingest task computes a `Sendable` snapshot off the
/// main actor and `await`s `apply(_:)`. No locks, no `Sendable` gymnastics —
/// the compiler enforces the hop for us.
@MainActor
@Observable
final class StatsModel {
    var range: StatsRange = .week7
    var totals = RangeTotals()
    var series: [DailyPoint] = []
    var heatmap: [HeatmapRow] = []
    var apps: [AppShare] = []
    var coverage = Coverage()
    var status = IngestStatus()
    var incognitoNow = false
    var isFirstLoad = true
    /// Distinguishes "never ingested" from "really zero", and both from
    /// "the read failed" — see `Snapshot.loadFailed`.
    var loadFailed = false
    var loadError = ""

    private let paths: AppPaths
    private let scheduler: IngestScheduler
    private var refreshTask: Task<Void, Never>?

    init(paths: AppPaths = AppPaths(), intervalSeconds: UInt64 = IngestInterval.defaultSeconds) {
        self.paths = paths
        self.scheduler = IngestScheduler(
            pipeline: IngestPipeline(paths: paths),
            intervalSeconds: intervalSeconds
        )
    }

    var health: HealthLevel {
        status.level(staleAfter: TimeInterval(IngestInterval.defaultSeconds))
    }

    func start() {
        // Re-read after every ingest so the menu bar health icon reflects the
        // latest run. Without this the icon only changes when the popover is
        // opened, which can be never.
        let scheduler = self.scheduler
        Task { @MainActor [weak self] in
            await scheduler.setIngestObserver { [weak self] in
                await MainActor.run { self?.refresh() }
            }
            await scheduler.start()
        }
        refresh()
    }

    /// Reads the precomputed rollups. Never recomputes an aggregate, never
    /// touches the `take` facts except for the indexed heatmap group-by.
    func refresh() {
        refreshTask?.cancel()
        let paths = self.paths
        let range = self.range

        refreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) { () -> Snapshot in
                Snapshot.load(paths: paths, range: range)
            }.value
            guard !Task.isCancelled else { return }
            self?.apply(snapshot)
        }
    }

    private func apply(_ snapshot: Snapshot) {
        totals = snapshot.totals
        series = snapshot.series
        heatmap = snapshot.heatmap
        apps = snapshot.apps
        coverage = snapshot.coverage
        status = snapshot.status
        incognitoNow = snapshot.incognitoNow
        loadFailed = snapshot.loadFailed
        loadError = snapshot.loadError
        isFirstLoad = false
    }

    func select(_ newRange: StatsRange) {
        range = newRange
        refresh()
    }

    /// A `Sendable` value type carrying everything the UI draws.
    struct Snapshot: Sendable {
        var totals = RangeTotals()
        var series: [DailyPoint] = []
        var heatmap: [HeatmapRow] = []
        var apps: [AppShare] = []
        var coverage = Coverage()
        var status = IngestStatus()
        var incognitoNow = false
        /// True when the read failed — a corrupt database, a lock it could not
        /// take, a query that threw. This must never look identical to a genuine
        /// all-zero day: "you have dictated nothing" and "I could not read your
        /// numbers" are opposite answers, and only one of them is true.
        var loadFailed = false
        var loadError = ""

        static func load(paths: AppPaths, range: StatsRange) -> Snapshot {
            var snapshot = Snapshot()

            // Read-only, and no schema migration here. Running DDL on the read
            // path meant opening the popover during an ingest blocked on the
            // write lock for the busy timeout and then silently rendered zeros.
            // Migration belongs to the ingest path, which already does it.
            guard let db = try? Database(path: paths.database.path, readOnly: true) else {
                // No database yet is a normal first run, not a failure.
                return snapshot
            }

            let query = StatsQuery(db: db, timezone: .current)
            let today = DayKey.today(timezone: .current)

            // One `do` around every read. Individually swallowing each error with
            // `try?` would let a partial failure render a plausible-looking panel
            // built from whichever queries happened to succeed — and a total
            // failure would render a confident all-zeros dashboard.
            do {
                snapshot.totals = try query.totals(for: range)
                snapshot.series =
                    try query.dailySeries(endingAt: today, count: range.dayCount ?? 30)
                // Always the last 7 days, whatever the selected range. Tying this to
                // the range collapsed it to a single row on "Today", which shrank the
                // popover and made the whole panel appear to slide.
                snapshot.heatmap = try query.heatmap(endingAt: today, dayCount: 7)
                snapshot.apps = try query.apps(for: range)
                snapshot.coverage = try query.coverage()
                snapshot.status = try query.ingestStatus()
                snapshot.incognitoNow = try query.incognitoNow()
            } catch {
                snapshot.loadFailed = true
                snapshot.loadError = String(describing: error)
            }
            return snapshot
        }
    }
}
