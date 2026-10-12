import Foundation

/// Local-calendar-day helpers.
///
/// All day bucketing happens in a **projection timezone** recorded in the
/// `meta` table as `tz_projection`, never in UTC and never implicitly in the
/// current zone. `taken_at` (UTC) is the immutable truth; `day_local` is a cached
/// projection of it. Recording the zone is what makes a timezone change a
/// deliberate, visible re-bucketing rather than silent data corruption.
public enum DayKey {
    /// Apple reference date → unix epoch.
    public static let appleReferenceOffset: Double = 978_307_200

    /// Converts an Apple reference date to unix seconds.
    ///
    /// Defensive by necessity: this is data from another app's REAL column, and
    /// `Int64(Double)` traps on `Inf`/`NaN` or an out-of-range value. A trap
    /// cannot be caught, so it would abort the app on every launch.
    public static func unixSeconds(fromAppleReference value: Double) -> Int64 {
        guard value.isFinite else { return 0 }
        let unix = (value + appleReferenceOffset).rounded(.down)
        guard unix > -9.0e18, unix < 9.0e18 else { return 0 }
        return Int64(unix)
    }

    public static func calendar(timezone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        return calendar
    }

    /// `YYYY-MM-DD` in the given timezone.
    public static func string(fromUnixSeconds seconds: Int64, timezone: TimeZone) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let parts = calendar(timezone: timezone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    public static func hour(fromUnixSeconds seconds: Int64, timezone: TimeZone) -> Int {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        return calendar(timezone: timezone).component(.hour, from: date)
    }

    /// Midnight-to-midnight, i.e. the start of the given `YYYY-MM-DD`.
    public static func startOfDay(_ key: String, timezone: TimeZone) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 0
        return calendar(timezone: timezone).date(from: components)
    }

    /// Today in the projection timezone.
    public static func today(now: Date = Date(), timezone: TimeZone) -> String {
        string(fromUnixSeconds: Int64(now.timeIntervalSince1970), timezone: timezone)
    }

    /// The last `count` day keys ending at `endKey`, oldest first, with no gaps.
    ///
    /// The sparkline and heatmap need every day present even when nothing was
    /// dictated, otherwise the chart silently changes width as data arrives.
    public static func series(endingAt endKey: String, count: Int, timezone: TimeZone) -> [String] {
        guard count > 0, let end = startOfDay(endKey, timezone: timezone),
            let calendar = Optional(calendar(timezone: timezone))
        else { return [] }

        var keys: [String] = []
        keys.reserveCapacity(count)
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: end) else { continue }
            keys.append(string(fromUnixSeconds: Int64(day.timeIntervalSince1970), timezone: timezone))
        }
        return keys
    }

}
