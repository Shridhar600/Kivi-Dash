import Foundation

public enum StatsRange: String, CaseIterable, Sendable {
    case today
    case week7
    case all

    /// Number of days shown, or nil for "everything we hold".
    public var dayCount: Int? {
        switch self {
        case .today: 1
        case .week7: 7
        case .all: nil
        }
    }

    public var title: String {
        switch self {
        case .today: "Today"
        case .week7: "7 days"
        case .all: "All time"
        }
    }
}

public struct RangeTotals: Sendable, Equatable {
    public init() {}

    /// Words **dictated**. This is the figure any label reading "words spoken"
    /// must use: clipboard history routinely contributes more text than speech,
    /// and calling that "spoken" over-claims.
    public var words: Int = 0

    /// Words across every mode, including clipboard captures.
    public var wordsIncludingClipboard: Int = 0
    public var takes: Int = 0
    public var micSeconds: Int = 0
    public var speechSeconds: Int = 0
    /// Duration-weighted words per minute of *mic-open time*, over eligible
    /// takes only. `nil` rather than 0 when there is nothing to divide.
    public var wpm: Double?
    /// Takes that contributed to `wpm`, out of `takes`. The denominator is not
    /// optional: a rate computed from 85% of your takes is a different claim
    /// than one computed from all of them.
    public var speedSampleTakes: Int = 0
    public var speedSampleTotal: Int = 0
    public var activeDays: Int = 0
    public var streak: Int = 0
    public var retiredTakes: Int = 0

}

public struct DailyPoint: Sendable, Equatable, Identifiable {
    public init(day: String, words: Int, takes: Int) {
        self.day = day
        self.words = words
        self.takes = takes
    }

    public var day: String
    public var words: Int
    public var takes: Int

    public var id: String { day }
}

public struct HeatmapRow: Sendable, Equatable, Identifiable {
    public init(day: String, wordsByHour: [Int]) {
        self.day = day
        self.wordsByHour = wordsByHour
    }

    public var day: String
    /// Words per hour, index 0–23. Missing hours are zero.
    public var wordsByHour: [Int]

    public var id: String { day }
    public var total: Int { wordsByHour.reduce(0, +) }
}

public struct AppShare: Sendable, Equatable, Identifiable {
    public init(bundleKey: String, bundleID: String, words: Int, takes: Int, wpm: Double?) {
        self.bundleKey = bundleKey
        self.bundleID = bundleID
        self.words = words
        self.takes = takes
        self.wpm = wpm
    }

    public var bundleKey: String
    public var bundleID: String
    public var words: Int
    public var takes: Int
    public var wpm: Double?

    public var id: String { bundleKey }
}

public struct Coverage: Sendable, Equatable {
    public init() {}

    /// Takes we actually hold for the current counter generation.
    public var held: Int = 0
    /// Takes Kivi reports as successful since the generation began.
    public var reported: Int = 0
    public var generation: Int = 0
    public var installID: String?

    /// Never rendered as "22% of your dictation" — see the copy in the UI.
    public var fraction: Double? {
        guard reported > 0 else { return nil }
        return min(1, Double(held) / Double(reported))
    }
}

public enum HealthLevel: Sendable, Equatable {
    case ok
    case stale
    case transientFailure
    case needsAttention

    /// SF Symbol shown on the status item.
    public var symbolName: String {
        switch self {
        case .ok: "chart.bar.fill"
        case .stale: "chart.bar"
        case .transientFailure: "exclamationmark.triangle"
        case .needsAttention: "exclamationmark.octagon"
        }
    }
}

public struct IngestStatus: Sendable, Equatable {
    public init() {}

    public var outcome: IngestResult.Outcome = .ok
    public var detail: String = ""
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    public var rowsNew: Int = 0
    public var rowsRetired: Int = 0
    public var daysRebuilt: Int = 0

    /// Stale means no successful ingest in more than two intervals. Shown quietly:
    /// the numbers on screen are still the last known good ones.
    ///
    /// `now` is injectable so the staleness test does not depend on the wall
    /// clock. Reading `Date()` here made the result a function of when the suite
    /// happened to run: a fixture dated a few days ago is `.ok` on the day it is
    /// written and `.stale` forever after, so the test rotted into a failure that
    /// looked like a product bug.
    public func level(staleAfter interval: TimeInterval, now: Date = Date()) -> HealthLevel {
        switch outcome {
        case .ok:
            guard let lastSuccessAt else { return .stale }
            return now.timeIntervalSince(lastSuccessAt) > interval * 2 ? .stale : .ok
        case .skippedNoSource, .skippedBusy:
            return .transientFailure
        case .failedSchema, .failedEmpty, .failedError:
            return .needsAttention
        }
    }
}
