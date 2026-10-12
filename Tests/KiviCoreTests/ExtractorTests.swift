import Foundation
import Testing

@testable import KiviCore

@Suite("Extractor")
struct ExtractorTests {
    private let ist = TimeZone(identifier: "Asia/Kolkata")!

    private func extract(_ takes: [Fixture.Take]) throws -> [ExtractedTake] {
        let url = try Fixture.makeKiviStore(takes)
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database(path: url.path, readOnly: true)
        return try Extractor.extract(from: db, timezone: ist)
    }

    @Test("counts words and projects day and hour in the given timezone")
    func basic() throws {
        let results = try extract([.init(pk: 1, durationSeconds: 30, text: "one two three four five")])
        #expect(results.count == 1)
        #expect(results[0].wordCount == 5)
        #expect(results[0].charCount == 23)
        #expect(results[0].mode == "dictate")
        #expect(results[0].bundleKey == "dev.warp.warp-stable", "bundle ids must be lower-cased")
        #expect(results[0].bundleID == "dev.warp.Warp-Stable", "verbatim spelling is preserved")
        #expect(results[0].durationMS == 30_000)
        #expect(results[0].isSpeedEligible)
    }

    /// 44% of real rows land on a different calendar date in UTC vs local, so
    /// this is not an edge case.
    @Test("buckets by local day, not UTC day")
    func localDayBucketing() throws {
        // 23:30 IST on the 3rd is 18:00 UTC on the 3rd, but a take at 00:30 IST
        // is the *previous* UTC day. Bucketing in UTC would misfile it.
        let calendar = DayKey.calendar(timezone: ist)
        let components = DateComponents(
            timeZone: ist,
            year: 2026,
            month: 10,
            day: 3,
            hour: 23,
            minute: 30
        )
        let date = calendar.date(from: components)!
        let appleReference = date.timeIntervalSince1970 - DayKey.appleReferenceOffset

        let results = try extract([
            .init(pk: 1, createdAtAppleReference: appleReference, text: "late night take here")
        ])
        #expect(results[0].dayLocal == "2026-10-03")
        #expect(results[0].hourLocal == 23)
    }

    @Test("clipboard rows have no bundle and no duration")
    func clipboard() throws {
        let results = try extract([
            .init(pk: 1, durationSeconds: nil, appBundleID: nil, mode: "clipboard", text: "copied text")
        ])
        #expect(results[0].mode == "clipboard")
        #expect(results[0].bundleKey == nil)
        #expect(results[0].durationMS == nil)
        #expect(!results[0].isSpeedEligible)
    }

    @Test("an unknown mode is preserved rather than dropped")
    func unknownMode() throws {
        let results = try extract([.init(pk: 1, durationSeconds: 10, mode: "whisper")])
        #expect(results[0].mode == "other:whisper")
    }

    @Test("NULL text yields zero counts and is excluded from speed")
    func nullText() throws {
        let results = try extract([.init(pk: 1, durationSeconds: 30, text: nil)])
        #expect(results[0].wordCount == 0)
        #expect(results[0].charCount == 0)
        #expect(!results[0].isSpeedEligible)
    }

    @Test("speed eligibility follows the frozen rule")
    func speedEligibility() throws {
        let cases: [(Double?, Int, Bool)] = [
            (30, 100, true),  // normal
            (4.9, 100, false),  // too short to be reliable
            (300, 100, true),  // boundary, inclusive
            (301, 100, false),  // orb left open
            (30, 4, false),  // too few words
            (nil, 100, false),  // clipboard-style null
        ]
        for (duration, words, expected) in cases {
            let text = Array(repeating: "word", count: max(words, 1)).joined(separator: " ")
            let results = try extract([
                .init(pk: 1, durationSeconds: duration, text: text)
            ])
            #expect(results[0].isSpeedEligible == expected, "duration \(duration), words \(words)")
        }
    }

    @Test("truncated text is excluded from speed")
    func truncated() throws {
        let long = String(repeating: "word ", count: 2_500)  // 12 500 chars
        let results = try extract([.init(pk: 1, durationSeconds: 30, text: long)])
        #expect(results[0].isTruncated)
        #expect(!results[0].isSpeedEligible)
    }

    @Test("Apple reference dates convert to the right epoch")
    func epochConversion() throws {
        let expected = DateComponents(
            timeZone: ist,
            year: 2026,
            month: 10,
            day: 6,
            hour: 0,
            minute: 13,
            second: 58
        )
        let date = DayKey.calendar(timezone: ist).date(from: expected)!
        let appleReference = date.timeIntervalSince1970 - DayKey.appleReferenceOffset

        let results = try extract([.init(pk: 1, createdAtAppleReference: appleReference, text: "hi")])
        #expect(abs(results[0].takenAt - Int64(date.timeIntervalSince1970)) <= 1)
        #expect(results[0].dayLocal == "2026-10-06")
    }
}
