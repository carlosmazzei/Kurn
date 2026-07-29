//
//  WordErrorRate.swift
//  KurnTests
//
//  WER = (substitutions + insertions + deletions) / reference tokens.
//
//  The breakdown matters more than the single number when the point is to decide
//  what to change. A pipeline that *drops* speech (VAD gating too aggressive, a
//  quality filter rejecting real segments, a chunk boundary eating a word) shows
//  up as deletions; one that invents it — the hallucination this app spent a
//  whole change filtering — shows up as insertions; a mishearing is a
//  substitution. Three failures with three different fixes, and one aggregate
//  rate cannot tell them apart.
//
//  The alignment is Levenshtein over tokens, carried in two rows: a one-hour
//  meeting is roughly 9,000 words, and a full n×m backtrace matrix for that is
//  ~320 MB. Carrying the running counts forward alongside the distance costs a
//  few words per cell and bounds memory to one row.
//

import Foundation

enum WordErrorRate {

    struct Result: Equatable, Sendable {
        var substitutions: Int
        var insertions: Int
        var deletions: Int
        /// Token count of the reference — the denominator.
        var referenceCount: Int

        var errors: Int { substitutions + insertions + deletions }

        /// Errors per reference token. Can exceed 1 when the hypothesis invents
        /// more than the reference contains, which is not a bug: a run of
        /// hallucinated text is genuinely worse than saying nothing.
        var rate: Double {
            guard referenceCount > 0 else { return errors > 0 ? 1 : 0 }
            return Double(errors) / Double(referenceCount)
        }

        var summary: String {
            String(
                format: "WER %.1f%% (S %d, I %d, D %d over %d)",
                rate * 100, substitutions, insertions, deletions, referenceCount
            )
        }
    }

    /// Compare two transcripts, normalizing both first.
    static func compare(reference: String, hypothesis: String) -> Result {
        compare(
            reference: TextNormalizer.tokens(reference),
            hypothesis: TextNormalizer.tokens(hypothesis)
        )
    }

    /// Compare token sequences that are already normalized.
    static func compare(reference: [String], hypothesis: [String]) -> Result {
        guard !reference.isEmpty else {
            return Result(
                substitutions: 0,
                insertions: hypothesis.count,
                deletions: 0,
                referenceCount: 0
            )
        }
        guard !hypothesis.isEmpty else {
            return Result(
                substitutions: 0,
                insertions: 0,
                deletions: reference.count,
                referenceCount: reference.count
            )
        }

        /// One DP cell: the edit distance plus how that distance was reached.
        struct Cell {
            var distance = 0
            var substitutions = 0
            var insertions = 0
            var deletions = 0
        }

        // Row 0: the hypothesis matched against an empty reference prefix, i.e.
        // every token so far is an insertion.
        var previous = (0...hypothesis.count).map {
            Cell(distance: $0, substitutions: 0, insertions: $0, deletions: 0)
        }
        var current = previous

        for row in 1...reference.count {
            // Column 0: the reference prefix matched against nothing.
            current[0] = Cell(distance: row, substitutions: 0, insertions: 0, deletions: row)

            for column in 1...hypothesis.count {
                let matches = reference[row - 1] == hypothesis[column - 1]

                var diagonal = previous[column - 1]
                if !matches {
                    diagonal.distance += 1
                    diagonal.substitutions += 1
                }
                var deletion = previous[column]
                deletion.distance += 1
                deletion.deletions += 1

                var insertion = current[column - 1]
                insertion.distance += 1
                insertion.insertions += 1

                // Ties resolve towards the diagonal, then deletion. Any choice
                // gives the same distance; this one keeps the breakdown stable
                // across runs, which a regression harness depends on.
                var best = diagonal
                if deletion.distance < best.distance { best = deletion }
                if insertion.distance < best.distance { best = insertion }
                current[column] = best
            }
            swap(&previous, &current)
        }

        let final = previous[hypothesis.count]
        return Result(
            substitutions: final.substitutions,
            insertions: final.insertions,
            deletions: final.deletions,
            referenceCount: reference.count
        )
    }
}
