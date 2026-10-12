import Foundation
import Testing

@testable import KiviCore

@Suite("Word counting")
struct WordCountTests {
    @Test("plain text")
    func plain() {
        #expect(WordCount.count("hello world").words == 2)
        #expect(WordCount.count("").words == 0)
        #expect(WordCount.count("one").words == 1)
    }

    /// The test that justifies ICU over whitespace splitting: whitespace would
    /// report 2 here, and every historical row would carry that bias forever,
    /// because a purged transcript can never be recounted.
    @Test("hyphenated compounds are not merged")
    func hyphens() {
        #expect(WordCount.count("state-of-the-art well-known").words == 6)
    }

    @Test("standalone emoji are not words")
    func emoji() {
        #expect(WordCount.count("ok 👋🏽 done 🎉").words == 2)
    }

    @Test("counts characters as grapheme clusters")
    func characters() {
        let counts = WordCount.count("Voice Memos — ünïcodé ✓")
        #expect(counts.chars == 23)
    }

    @Test("long input is fully counted")
    func longInput() {
        let text = Array(repeating: "word ", count: 15_000).joined()
        #expect(WordCount.count(text).words == 15_000)
    }

    @Test("truncation is flagged at the threshold")
    func truncation() {
        #expect(!WordCount.count(String(repeating: "a", count: 9_899)).isTruncated)
        #expect(WordCount.count(String(repeating: "a", count: 9_900)).isTruncated)
    }

    @Test("method label is frozen")
    func methodLabel() {
        #expect(WordCount.method == "icu_v1")
    }
}
