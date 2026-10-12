import SwiftUI

/// One accent colour, no rainbow. Values chosen to sit quietly next to the
/// system menu bar rather than shout.
enum Theme {
    static let background = Color(red: 0.063, green: 0.075, blue: 0.090)
    static let line = Color(red: 0.137, green: 0.157, blue: 0.184)
    static let ink = Color(red: 0.914, green: 0.929, blue: 0.949)
    static let dim = Color(red: 0.545, green: 0.584, blue: 0.647)
    static let dimmest = Color(red: 0.361, green: 0.400, blue: 0.455)
    static let accent = Color(red: 0.369, green: 0.878, blue: 0.541)

    /// Heatmap ramp. The lowest step is the empty background, so a day you never
    /// dictated on is visibly a different colour from one you dictated a single
    /// word on.
    static let heatEmpty = Color(red: 0.078, green: 0.094, blue: 0.113)
    static func heat(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.001: heatEmpty
        case ..<0.15: Color(red: 0.118, green: 0.290, blue: 0.173)
        case ..<0.40: Color(red: 0.173, green: 0.420, blue: 0.235)
        case ..<0.70: Color(red: 0.239, green: 0.561, blue: 0.306)
        default: Color(red: 0.341, green: 0.769, blue: 0.435)
        }
    }

    static let sectionLabel = Font.system(size: 9.5, weight: .semibold)
    static let hero = Font.system(size: 34, weight: .semibold)
    static let statValue = Font.system(size: 17, weight: .semibold)
    static let axis = Font.system(size: 9)
    static let caption = Font.system(size: 10)
}

@MainActor
enum Format {
    // Constructing a DateFormatter or NumberFormatter is expensive, and these are
    // called ~190 times per body pass (including for tooltips that are not shown),
    // so they are built once.
    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d"
        return formatter
    }()

    /// Day keys are plain `YYYY-MM-DD` with no zone, so they are resolved against
    /// the current calendar.
    private static let currentCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    static func words(_ value: Int) -> String {
        decimal.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 1h 31m / 12m / 48s
    static func duration(seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    /// "Sat 3"
    static func shortDay(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return key }
        guard
            let date = currentCalendar.date(
                from: DateComponents(year: parts[0], month: parts[1], day: parts[2])
            )
        else { return key }
        // Reuses the cached formatter. This used to build a fresh `Calendar` and
        // a fresh `DateFormatter` on every call, and it runs once per heatmap cell
        // — 168 times per render — which is precisely the cost the caching above
        // exists to avoid.
        return dayFormatter.string(from: date)
    }
}
