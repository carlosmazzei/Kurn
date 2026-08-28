//
//  MeetingVocabularyExtractor.swift
//  KurnCore
//
//  Builds a small vocabulary hint from a meeting's own transcript — names,
//  acronyms, and terms that recur across segments — so `LLMTranscriptCorrector`
//  can resolve a misheard word the same way it was rendered correctly
//  elsewhere in the same recording, rather than relying on a static,
//  user-maintained glossary.
//

import Foundation

public enum MeetingVocabularyExtractor {
    public static let maxTerms = 40
    public static let minOccurrences = 2

    /// Extracts distinctive recurring terms (proper nouns, acronyms, terms
    /// with digits) from `segments`' text. Runs over the full segment set,
    /// including segments excluded from correction itself — those are exactly
    /// the ones most likely to already have the term spelled right. Pure and
    /// deterministic: the same input always yields the same ordered output.
    public static func extract(from segments: [TranscriptSegment]) -> [String] {
        var counts: [String: Int] = [:]

        for segment in segments {
            var isSentenceStart = true
            for rawToken in segment.text.split(whereSeparator: { $0.isWhitespace }) {
                defer { isSentenceStart = endsSentence(rawToken) }

                let token = trim(String(rawToken))
                guard !token.isEmpty, let first = token.first else { continue }

                let containsDigit = token.contains { $0.isNumber }
                let isAcronym = token.count >= 2
                    && token.contains { $0.isUppercase }
                    && !token.contains { $0.isLowercase }
                let isCapitalizedMidSentence = !isSentenceStart && first.isUppercase

                guard containsDigit || isAcronym || isCapitalizedMidSentence else { continue }
                counts[token, default: 0] += 1
            }
        }

        return counts
            .filter { $0.value >= minOccurrences }
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }
            .prefix(maxTerms)
            .map(\.key)
    }

    /// Strips leading/trailing punctuation from a raw whitespace-delimited
    /// token, keeping internal characters (apostrophes, hyphens) so
    /// "O'Brien" and "well-known" survive intact.
    private static func trim(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters)
    }

    /// Whether `rawToken` (untrimmed, as split from the source text) ends a
    /// sentence, so the token that follows should not be treated as
    /// mid-sentence capitalization.
    private static func endsSentence(_ rawToken: Substring) -> Bool {
        guard let last = rawToken.last else { return false }
        return last == "." || last == "!" || last == "?"
    }
}
