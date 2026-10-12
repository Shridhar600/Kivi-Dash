import Foundation

/// Word counting for transcripts, in memory only.
///
/// ICU segmentation via `.byWords` rather than whitespace splitting:
/// * `"state-of-the-art well-known"` — whitespace says 2, ICU says 6.
/// * `"今天天气很好"` — whitespace says 1.
/// * `"ok 👋🏽 done 🎉"` — whitespace counts standalone emoji as words.
///
/// Known limitation, documented rather than hidden: ICU word-break is not an
/// orthographic segmenter for space-less Tamil and will not break a run of
/// Tamil text into words either. It is still strictly better than whitespace.
public enum WordCount {
    /// Frozen per archive. If the algorithm ever changes, old rows keep their
    /// label so the mix is visible rather than silently compared as one method.
    public static let method = "icu_v1"

    /// Text at or above this length is assumed truncated by the source app and
    /// is excluded from speed statistics.
    public static let truncationThreshold = 9_900

    public struct Counts: Sendable, Equatable {
        public let words: Int
        public let chars: Int
        public let isTruncated: Bool

        public init(words: Int, chars: Int) {
            self.words = words
            self.chars = chars
            self.isTruncated = chars >= WordCount.truncationThreshold
        }
    }

    public static func count(_ text: String) -> Counts {
        var words = 0
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, _, _, _ in
            words += 1
        }
        return Counts(words: words, chars: text.count)
    }
}
