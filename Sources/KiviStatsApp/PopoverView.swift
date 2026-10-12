import AppKit
import KiviCore
import SwiftUI

/// The popover contents: header, hero + sparkline, four stat tiles, the
/// day×hour heatmap, the per-app split, and a status footer.
struct PopoverView: View {
    @Bindable var model: StatsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            incognitoSlot
            Divider().overlay(Theme.line)
            // Deliberately NOT a ScrollView.
            //
            // A ScrollView inside a MenuBarExtra `.window` popover renders its
            // content blank — verified by rendering the popover offscreen with
            // ImageRenderer: fixed-height and maxHeight variants both drew an
            // empty region, while the identical content in a plain VStack drew
            // correctly. The window sizes itself from the content's ideal size,
            // and the scroll view never gets a usable one.
            //
            // Total height is therefore bounded by construction: the heatmap is
            // capped at 7 rows and the app list at 5 entries.
            VStack(spacing: 0) {
                HeroSection(model: model)
                Divider().overlay(Theme.line)
                TilesSection(model: model)
                Divider().overlay(Theme.line)
                HeatmapSection(model: model)
                Divider().overlay(Theme.line)
                AppsSection(model: model)
            }
            Divider().overlay(Theme.line)
            footer
        }
        .frame(width: 352)
        .background(Theme.background)
        .foregroundStyle(Theme.ink)
        // Re-read on every open so the numbers are current; ingest itself is
        // owned by the app, not by this view.
        .task { model.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Text("Kivi-Dash")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            Spacer()
            RangePicker(range: model.range) { model.select($0) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// A single permanent line, and a single fixed height.
    ///
    /// This used to expand on hover, which is a trap: any layout change resizes
    /// the popover window and macOS then repositions the whole panel. Fixed height
    /// means nothing about the coverage indicator can move anything. The height
    /// is reserved even when incognito is off, so the window cannot resize later
    /// either.
    private var incognitoSlot: some View {
        ZStack(alignment: .leading) {
            Color.clear
            if model.incognitoNow {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(red: 0.851, green: 0.643, blue: 0.255))
                        .frame(width: 5, height: 5)
                    Text(summaryText)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dimmest)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
            }
        }
        .frame(height: Self.incognitoSlotHeight)
        .clipped()
    }

    private static let incognitoSlotHeight: CGFloat = 22

    private var summaryText: String {
        guard model.coverage.reported > 0 else { return "Incognito is on" }
        return
            "Incognito is on · holding \(Format.words(model.coverage.held)) of \(Format.words(model.coverage.reported)) takes"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(statusLine)
                .lineLimit(1)
            Spacer()
            Text(rangeFooter)
                .lineLimit(1)
            // With LSUIElement there is no Dock icon and no ⌘Q, and dragging the
            // item off the menu bar is undiscoverable. Quit has to live here.
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(Theme.caption)
                .foregroundStyle(Theme.dimmest)
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.dimmest)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.background)
    }

    private var statusLine: String {
        // A failed read outranks everything: the numbers above are not real, and
        // saying "never ingested" here would dress a broken query up as a fact
        // about the user's dictation.
        if model.loadFailed {
            return "could not read your history"
        }
        // Check the outcome first: on a first run that failed there is no prior
        // success, so a "last success" guard would hide the reason entirely —
        // which is precisely when the detail matters most.
        if model.status.outcome != .ok {
            return model.status.detail.isEmpty
                ? "ingest \(model.status.outcome.rawValue)" : model.status.detail
        }
        if model.isFirstLoad { return "reading your dictation history\u{2026}" }
        guard let last = model.status.lastSuccessAt else { return "never ingested" }
        let minutes = max(0, Int(Date().timeIntervalSince(last) / 60))
        return minutes < 1 ? "updated just now" : "updated \(minutes) min ago"
    }

    private var rangeFooter: String {
        if model.range == .all { return "all time" }
        return model.range.title
    }
}

// MARK: - Range picker

private struct RangePicker: View {
    let range: StatsRange
    let onSelect: (StatsRange) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(StatsRange.allCases, id: \.self) { option in
                Text(option.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(option == range ? Theme.ink : Theme.dimmest)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(option == range ? Color(red: 0.137, green: 0.165, blue: 0.200) : .clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(option) }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 0.051, green: 0.063, blue: 0.078))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1)
        )
    }
}

// MARK: - Sections

private struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Theme.sectionLabel)
            .kerning(0.9)
            .foregroundStyle(Theme.dimmest)
    }
}

private struct HeroSection: View {
    @Bindable var model: StatsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Words spoken · \(model.range.title.lowercased())")
                .padding(.bottom, 9)

            if model.isFirstLoad {
                Text("Reading…")
                    .font(Theme.hero)
                    .kerning(-1.2)
                    .foregroundStyle(Theme.dim)
            } else {
                Text(Format.words(model.totals.words))
                    .font(Theme.hero)
                    .kerning(-1.2)
                    .foregroundStyle(Theme.ink)
            }

            Sparkline(points: model.series)
                .frame(height: 34)
                .opacity(model.series.isEmpty ? 0 : 1)
                .padding(.top, 11)
                .padding(.bottom, 5)

            HStack {
                Text(peakLabel)
                Spacer()
                Text(model.series.last.map { Format.shortDay($0.day) } ?? "")
            }
            .font(Theme.axis)
            .foregroundStyle(Theme.dimmest)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    private var peakLabel: String {
        guard let peak = model.series.max(by: { $0.words < $1.words }), peak.words > 0 else {
            return "no dictation in this range"
        }
        return "peak \(Format.shortDay(peak.day)) · \(Format.words(peak.words))"
    }
}

private struct Sparkline: View {
    let points: [DailyPoint]

    var body: some View {
        let peak = max(1, points.map(\.words).max() ?? 1)

        HStack(alignment: .bottom, spacing: 3) {
            ForEach(points) { point in
                let fraction = Double(point.words) / Double(peak)
                HoverTip(
                    title: "\(Format.words(point.words)) words",
                    detail: "\(Format.shortDay(point.day)) · \(point.takes) takes",
                    preferBelow: true
                ) {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(point.words > 0 ? Theme.accent : Color(red: 0.114, green: 0.137, blue: 0.161))
                            .frame(
                                width: geo.size.width,
                                height: max(3, geo.size.height * fraction)
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct TilesSection: View {
    @Bindable var model: StatsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                tile("Takes", value: Format.words(model.totals.takes))
                tile("Mic time", value: Format.duration(seconds: model.totals.micSeconds))
            }
            HStack(alignment: .top, spacing: 12) {
                speedTile
                tile("Streak", value: "\(model.totals.streak)", unit: model.totals.streak == 1 ? "day" : "days")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    private func tile(_ label: String, value: String, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(text: label)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(Theme.statValue).kerning(-0.4)
                if let unit {
                    Text(unit).font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The denominator is shown because a rate computed from 85% of your takes
    /// is a different claim than one computed from all of them.
    private var speedTile: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(text: "Speed")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(model.totals.wpm.map { String(format: "%.0f", $0) } ?? "—")
                    .font(Theme.statValue)
                    .kerning(-0.4)
                Text("wpm").font(.system(size: 11)).foregroundStyle(Theme.dim)
            }
            // Always rendered, even when empty: a conditional line here changes
            // the tile's height on a day with no takes, which resizes the window.
            Text(
                model.totals.takes > 0
                    ? "\(model.totals.speedSampleTakes) of \(model.totals.takes) takes" : " "
            )
            .font(.system(size: 9))
            .foregroundStyle(Theme.dimmest)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(
            "Words per minute of mic-open time. Short takes, takes over five minutes, and truncated takes are excluded from this figure but still counted as takes."
        )
    }
}

private struct HeatmapSection: View {
    @Bindable var model: StatsModel

    var body: some View {
        let peak = max(1, model.heatmap.map(\.total).max() ?? 1)

        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "When you dictate · last 7 days")
                .padding(.bottom, 9)

            ForEach(Array(model.heatmap.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 7) {
                    Text(Format.shortDay(row.day))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.dimmest)
                        .frame(width: 38, alignment: .trailing)

                    HStack(spacing: 1.5) {
                        ForEach(0..<24, id: \.self) { hour in
                            let words = row.wordsByHour[hour]
                            if words > 0 {
                                HoverTip(
                                    title: "\(Format.words(words)) words",
                                    detail: "\(Format.shortDay(row.day)) · \(hourLabel(hour))",
                                    // There is deliberately no scroll view
                                    // (see the note at the top of this file), so
                                    // the top row has no room above it.
                                    preferBelow: index == 0
                                ) {
                                    cell(Double(words) / Double(peak))
                                }
                            } else {
                                // Empty hours are inert: no dead tooltips across
                                // quiet parts of the day.
                                cell(0)
                            }
                        }
                    }
                    // The row needs a bounded height: `aspectRatio(1, .fit)`
                    // cannot resolve a square from an unbounded height proposal
                    // and collapses every cell to zero width.
                    .frame(height: 10)

                    Text(Format.words(row.total))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim)
                        .frame(width: 40, alignment: .trailing)
                }
                .padding(.bottom, 4)
            }

            hourAxis
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    private func cell(_ fraction: Double) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Theme.heat(fraction))
            .aspectRatio(1, contentMode: .fit)
    }

    private func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00–%02d:00", hour, hour + 1)
    }

    /// Mirrors the row layout exactly — same 38pt label column, same 1.5pt cell
    /// spacing, same 40pt total column — so each hour label sits under the cell
    /// it names. A differently-sized axis puts every label in the wrong place.
    private var hourAxis: some View {
        HStack(spacing: 7) {
            Color.clear.frame(width: 38, height: 0)
            // Same 24-column geometry as the rows, so each label sits under the
            // cell it names. `fixedSize` + `lineLimit` matter: a cell is only ~8pt
            // wide and would otherwise wrap "06" onto two lines. Labels are only
            // drawn every 6 hours, which is far enough apart to overlap safely.
            HStack(spacing: 1.5) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(axisHours.contains(hour) ? String(format: "%02d", hour) : "")
                        .font(Theme.axis)
                        .foregroundStyle(Theme.dimmest)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                }
            }
            Color.clear.frame(width: 40, height: 0)
        }
        .padding(.top, 6)
    }

    /// Axis labels chosen so they do not collide at this cell width.
    private var axisHours: [Int] { [0, 6, 12, 18] }
}

/// Resolves bundle identifiers to display names once per identifier.
@MainActor
final class AppNameCache {
    static let shared = AppNameCache()
    private var cache: [String: String] = [:]

    func name(for bundleID: String) -> String {
        if let cached = cache[bundleID] { return cached }
        let resolved =
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { url -> String? in
                (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
            }
        // `localizedName` frequently carries the extension ("ChatGPT.app").
        let name = (resolved ?? fallback(bundleID))
            .replacingOccurrences(of: ".app", with: "", options: [.caseInsensitive])

        cache[bundleID] = name
        return name
    }

    /// Only reached for apps that are no longer installed.
    private func fallback(_ bundleID: String) -> String {
        let parts = bundleID.split(separator: ".")
        guard let last = parts.last else { return bundleID }
        return
            last
            .replacingOccurrences(of: "-stable", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}

private struct AppsSection: View {
    @Bindable var model: StatsModel

    var body: some View {
        let peak = max(1, model.apps.map(\.words).max() ?? 1)

        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(
                text: model.apps.count > appsSectionSlots
                    ? "Where words land · top \(appsSectionSlots)" : "Where words land"
            )
            .padding(.bottom, 9)

            if model.apps.isEmpty {
                Text("No dictation recorded in this range.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dimmest)
            }

            ForEach(model.apps.prefix(appsSectionSlots), id: \.bundleKey) { app in
                appRow(app, peak: peak)
            }

            if model.apps.count > appsSectionSlots {
                Text("+ \(model.apps.count - appsSectionSlots) more")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.dimmest)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        // A fixed section height, so the popover never resizes when the range
        // changes and macOS therefore never repositions it. Padded per-row
        // instead would drift, because a real row and a blank slot are not the
        // same height.
        .frame(height: appsSectionHeight, alignment: .top)
    }

    private var appsSectionSlots: Int { 5 }

    private var appsSectionHeight: CGFloat { 13 + 9 + CGFloat(appsSectionSlots) * 34 + 13 }

    private func appRow(_ app: AppShare, peak: Int) -> some View {
        HoverTip(
            title: "\(Format.words(app.words)) words",
            detail: "\(app.bundleID) · \(app.takes) takes"
                + (app.wpm.map { " · \(String(format: "%.0f", $0)) wpm" } ?? "")
        ) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(displayName(app.bundleID))
                            .font(.system(size: 11.5))
                        Text("\(app.takes) takes")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.dimmest)
                    }
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color(red: 0.078, green: 0.094, blue: 0.113))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(Color(red: 0.482, green: 0.525, blue: 0.592))
                                    .frame(
                                        width: geo.size.width * Double(app.words) / Double(peak)
                                    )
                            }
                    }
                    .frame(height: 4)
                }
                Spacer(minLength: 0)
                Text(Format.words(app.words))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(.vertical, 3)
    }

    /// Show the app's real name where it is installed.
    ///
    /// Deriving it from the bundle id is not good enough: it turns
    /// `com.anthropic.claudefordesktop` into "Claude" (wrong) and
    /// `ai.opencode.desktop` into "Desktop" (meaningless). Cached, because the
    /// lookup is not free and the answer cannot change while we are open.
    private func displayName(_ bundleID: String) -> String {
        AppNameCache.shared.name(for: bundleID)
    }
}
