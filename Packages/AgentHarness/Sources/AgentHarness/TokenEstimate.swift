import Foundation

/// Rough, deliberately pessimistic token count for prompt planning. Not a
/// tokenizer: it only has to keep a request inside a model's window, never
/// to match a vendor's bill.
public enum TokenEstimate {
    /// Latin, Greek and Cyrillic text including the transcript's
    /// `[mm:ss] Speaker N:` framing, which tokenizes worse than prose.
    static let charactersPerTokenAlphabetic = 3.5
    /// Scripts without spaces between words (Han, kana, Hangul, Thai…) cost
    /// about one token per character in current tokenizers, often less;
    /// counting one keeps the estimate on the safe side.
    static let charactersPerTokenIdeographic = 1.0
    /// Everything else (Arabic, Hebrew, Devanagari, emoji…), which current
    /// tokenizers split more finely than Latin.
    static let charactersPerTokenOther = 2.0

    public static func tokens(in text: String) -> Int {
        Int(estimate(text).rounded(.up))
    }

    /// Characters (grapheme clusters, matching `String.count`, which the
    /// block splitters measure in) per estimated token in `text`.
    public static func charactersPerToken(in text: String) -> Double {
        let tokens = estimate(text)
        guard tokens > 0 else { return charactersPerTokenAlphabetic }
        return Double(text.count) / tokens
    }

    private static func estimate(_ text: String) -> Double {
        var alphabetic = 0
        var ideographic = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if scalar.value < 0x0530 {
                alphabetic += 1
            } else if isIdeographic(scalar) {
                ideographic += 1
            } else {
                other += 1
            }
        }
        return Double(alphabetic) / charactersPerTokenAlphabetic
            + Double(ideographic) / charactersPerTokenIdeographic
            + Double(other) / charactersPerTokenOther
    }

    private static func isIdeographic(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0E00...0x0EFF,   // Thai, Lao
             0x1100...0x11FF,   // Hangul Jamo
             0x2E80...0x9FFF,   // CJK radicals, punctuation, kana, unified ideographs
             0xA960...0xA97F,   // Hangul Jamo Extended-A
             0xAC00...0xD7FF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0xFF00...0xFFEF,   // Half/full-width forms
             0x20000...0x3FFFF: // CJK extensions B…H
            return true
        default:
            return false
        }
    }
}
