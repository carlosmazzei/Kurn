//
//  TranscriptCorrectionGuardrail.swift
//  KurnCore
//
//  Bounds how much an LLM-proposed correction may change a segment's text
//  before it is rejected. Deliberately not a reuse of
//  `KurnTests/Support/Evaluation/WordErrorRate.swift`/`TextNormalizer` — those
//  are test-target-only, and `TextNormalizer` must never touch stored or
//  displayed transcript text. This operates on raw, unnormalized strings and
//  only needs to bound the *magnitude* of a change, not produce a comparable
//  accuracy metric.
//

import Foundation

public enum TranscriptCorrectionGuardrail {
    public static let maxWordChangeRatio = 0.35
    public static let maxLengthRatio = 1.5
    public static let minLengthRatio = 0.6

    /// Whether `corrected` is close enough to `original` to be a plausible
    /// spelling/punctuation fix rather than a paraphrase, invention, or
    /// emptied/fabricated segment.
    public static func accepts(original: String, corrected: String) -> Bool {
        let originalTrimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let correctedTrimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard correctedTrimmed != originalTrimmed else { return true }
        guard !originalTrimmed.isEmpty, !correctedTrimmed.isEmpty else { return false }

        let lengthRatio = Double(correctedTrimmed.count) / Double(originalTrimmed.count)
        guard lengthRatio <= maxLengthRatio, lengthRatio >= minLengthRatio else { return false }

        // Case and trailing punctuation are normalized for this comparison
        // only (never for the text actually applied) so a plain
        // capitalization or end-of-sentence punctuation fix isn't counted the
        // same as a genuine word substitution — otherwise a two-word spelling
        // fix on a short segment could read as "half the segment changed" and
        // be rejected.
        let originalWords = originalTrimmed.split { $0.isWhitespace }.map { normalizedWord(String($0)) }
        let correctedWords = correctedTrimmed.split { $0.isWhitespace }.map { normalizedWord(String($0)) }

        // Unsegmented scripts (e.g. zh-Hans) split into ~1 "word"; fall back to
        // character-level distance there, same fallback CLAUDE.md documents for
        // `TextNormalizer`'s CER path.
        if originalWords.count > 1 {
            let distance = levenshtein(originalWords, correctedWords)
            return Double(distance) / Double(originalWords.count) <= maxWordChangeRatio
        } else {
            let originalChars = Array(originalTrimmed.lowercased())
            let correctedChars = Array(correctedTrimmed.lowercased())
            let distance = levenshtein(originalChars, correctedChars)
            return Double(distance) / Double(originalChars.count) <= maxWordChangeRatio
        }
    }

    private static func normalizedWord(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }

    /// Two-row DP, distance only (no substitution/insertion/deletion
    /// breakdown — this guardrail only needs the magnitude). Segments are
    /// capped at 30s of speech, so this is cheap regardless of meeting length.
    private static func levenshtein<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    current[j] = previous[j - 1]
                } else {
                    current[j] = 1 + min(previous[j - 1], previous[j], current[j - 1])
                }
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
