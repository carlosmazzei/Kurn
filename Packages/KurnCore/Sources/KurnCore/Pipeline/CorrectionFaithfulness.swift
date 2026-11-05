//
//  CorrectionFaithfulness.swift
//  KurnCore
//
//  The correction stage lets a critic's inferred vocabulary steer
//  the corrector, which is exactly the situation in which a model starts
//  writing what the meeting *should* have said instead of what was said.
//  `TranscriptCorrectionGuardrail` bounds how *much* a segment may change;
//  this bounds *what* may come in: every word the correction introduces must
//  be traceable to the audio (it sounds like — is spelled close to — a word or
//  a pair of adjacent words the ASR wrote) or to vocabulary grounded in this
//  meeting. A word with no such connection is invented, and the whole
//  correction of that segment is rejected.
//
//  Pure, deterministic and Apple-free. Spelling closeness is the only
//  phonetic proxy available without a language-specific model; it is
//  deliberately generous (`maxRelativeDistance`) because the guardrail
//  already caps the magnitude of the change.
//

import Foundation

public enum CorrectionFaithfulness {
    /// Normalized edit distance under which a new word counts as a respelling
    /// of an original one ("fetur" → "feature", "cubernetes" → "kubernetes").
    public static let maxRelativeDistance = 0.45

    /// Whether every word in `corrected` that is not already in `original` is
    /// connected to what was said: close to an original word, close to two
    /// adjacent original words joined (a split the ASR introduced), part of an
    /// original word split apart, or one of `allowedTerms`.
    public static func accepts(original: String, corrected: String, allowedTerms: [String]) -> Bool {
        let originalWords = words(original)
        let originalSet = Set(originalWords)
        let joinedPairs = zip(originalWords, originalWords.dropFirst()).map { $0 + $1 }
        let allowed = Set(allowedTerms.flatMap(words))

        for word in words(corrected) where !originalSet.contains(word) && !allowed.contains(word) {
            let connected = originalWords.contains { isRespelling(word, of: $0) || $0.contains(word) }
                || joinedPairs.contains { isRespelling(word, of: $0) }
            guard connected else { return false }
        }
        return true
    }

    /// Lowercased word tokens with surrounding punctuation removed. Scripts
    /// written without spaces come back as one token per run, which only makes
    /// the check stricter for them — never more permissive.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }
    }

    static func isRespelling(_ candidate: String, of source: String) -> Bool {
        let longest = max(candidate.count, source.count)
        guard longest > 0 else { return true }
        // Very short words are function words or numbers; a one-letter change
        // there is a different word ("in" → "on"), so they must match closely.
        let budget = longest <= 3 ? 1 : Int((Double(longest) * maxRelativeDistance).rounded(.down))
        return editDistance(Array(candidate), Array(source), limit: budget) <= budget
    }

    /// Levenshtein distance, stopping early once every cell of a row exceeds
    /// `limit` (the answer is then just "more than `limit`").
    static func editDistance(_ lhs: [Character], _ rhs: [Character], limit: Int) -> Int {
        if abs(lhs.count - rhs.count) > limit { return limit + 1 }
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
