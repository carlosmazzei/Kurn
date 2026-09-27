//
//  DiarizationErrorRate.swift
//  KurnTests
//
//  DER = (missed + false alarm + confusion) / total reference speech, the NIST
//  measure every diarization result in the literature is quoted in.
//
//  Two details make it the standard rather than an obvious ratio, and both are
//  implemented here:
//
//  **The speaker mapping is not given.** A diarizer invents its own labels, so
//  "Speaker 1" in the output has no relation to "Ana" in the reference. Scoring
//  against the labels as written would report near-total error for a perfect
//  result. The score is therefore taken over the label mapping that *maximises*
//  agreement — anything else measures the naming, not the diarization.
//
//  **Boundaries are excluded by a collar.** A human annotator cannot place a
//  turn boundary to the millisecond, and neither can a diarizer; without a
//  collar, DER mostly measures disagreement about the exact instant a word
//  ended. The NIST convention is ±0.25 s around every reference boundary, which
//  is the default here.
//
//  The three error types answer different questions, which is why they are kept
//  apart: *missed* is speech the diarizer heard as silence, *false alarm* is
//  silence it heard as speech, and *confusion* is speech given to the wrong
//  person. The third is the one this app's neural diarizer collapses into when
//  its clustering step drives every speaker but one to zero — a meeting scored
//  as one long confusion, with no missed time at all.
//

import Foundation

enum DiarizationErrorRate {

    struct Segment: Equatable, Sendable {
        var label: String
        var start: TimeInterval
        var end: TimeInterval

        init(label: String, start: TimeInterval, end: TimeInterval) {
            self.label = label
            self.start = start
            self.end = max(start, end)
        }

        var duration: TimeInterval { end - start }
    }

    struct Result: Sendable {
        var missed: TimeInterval
        var falseAlarm: TimeInterval
        var confusion: TimeInterval
        /// Denominator: reference speech inside the scored region, counted once
        /// per simultaneous speaker.
        var referenceSpeech: TimeInterval
        /// Reference label → hypothesis label, the assignment the score used.
        var mapping: [String: String]

        var errors: TimeInterval { missed + falseAlarm + confusion }

        var rate: Double {
            guard referenceSpeech > 0 else { return falseAlarm > 0 ? 1 : 0 }
            return errors / referenceSpeech
        }

        var summary: String {
            String(
                format: "DER %.1f%% (missed %.1fs, false alarm %.1fs, confusion %.1fs of %.1fs)",
                rate * 100, missed, falseAlarm, confusion, referenceSpeech
            )
        }
    }

    /// The NIST RT convention, and VoxConverse's. Not universal: DIHARD and
    /// pyannote's published benchmarks (AMI included) score with no collar,
    /// which reads several points higher on the same output — so a figure is
    /// only comparable with its collar stated. `Tools/evaluation/rescore.py`
    /// reports both.
    static let defaultCollar: TimeInterval = 0.25

    static func compare(
        reference: [Segment],
        hypothesis: [Segment],
        collar: TimeInterval = defaultCollar
    ) -> Result {
        let intervals = scoredIntervals(reference: reference, hypothesis: hypothesis, collar: collar)
        guard !intervals.isEmpty else {
            return Result(missed: 0, falseAlarm: 0, confusion: 0, referenceSpeech: 0, mapping: [:])
        }

        // Resolve each scored interval to the speakers active in it, once.
        let active = intervals.map { interval -> (duration: TimeInterval, reference: Set<String>, hypothesis: Set<String>) in
            let midpoint = (interval.start + interval.end) / 2
            return (
                interval.end - interval.start,
                labels(at: midpoint, in: reference),
                labels(at: midpoint, in: hypothesis)
            )
        }

        var overlap: [String: [String: TimeInterval]] = [:]
        for slice in active {
            for referenceLabel in slice.reference {
                for hypothesisLabel in slice.hypothesis {
                    overlap[referenceLabel, default: [:]][hypothesisLabel, default: 0] += slice.duration
                }
            }
        }

        let mapping = bestMapping(
            overlap: overlap,
            referenceLabels: Set(reference.map(\.label)).sorted(),
            hypothesisLabels: Set(hypothesis.map(\.label)).sorted()
        )

        var result = Result(missed: 0, falseAlarm: 0, confusion: 0, referenceSpeech: 0, mapping: mapping)
        for slice in active {
            let referenceCount = slice.reference.count
            let hypothesisCount = slice.hypothesis.count
            result.referenceSpeech += slice.duration * Double(referenceCount)
            result.missed += slice.duration * Double(max(0, referenceCount - hypothesisCount))
            result.falseAlarm += slice.duration * Double(max(0, hypothesisCount - referenceCount))

            // The mapping is injective, so distinct reference speakers can never
            // claim the same hypothesis speaker and `matched` cannot exceed the
            // smaller of the two counts.
            let matched = slice.reference.filter { label in
                guard let mapped = mapping[label] else { return false }
                return slice.hypothesis.contains(mapped)
            }.count
            result.confusion += slice.duration * Double(min(referenceCount, hypothesisCount) - matched)
        }
        return result
    }

    // MARK: - Timeline

    /// The timeline split at every boundary either side declares, with the
    /// collar zones around reference boundaries removed.
    private static func scoredIntervals(
        reference: [Segment],
        hypothesis: [Segment],
        collar: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        var boundaries = Set<TimeInterval>()
        for segment in reference + hypothesis {
            boundaries.insert(segment.start)
            boundaries.insert(segment.end)
        }

        var exclusions: [(start: TimeInterval, end: TimeInterval)] = []
        if collar > 0 {
            for segment in reference {
                for boundary in [segment.start, segment.end] {
                    exclusions.append((boundary - collar, boundary + collar))
                    // Split the timeline at the collar edges too, so an interval
                    // is never half-scored.
                    boundaries.insert(boundary - collar)
                    boundaries.insert(boundary + collar)
                }
            }
        }

        let sorted = boundaries.sorted()
        var intervals: [(start: TimeInterval, end: TimeInterval)] = []
        for (start, end) in zip(sorted, sorted.dropFirst()) where end > start {
            let midpoint = (start + end) / 2
            let excluded = exclusions.contains { midpoint > $0.start && midpoint < $0.end }
            if !excluded { intervals.append((start, end)) }
        }
        return intervals
    }

    private static func labels(at time: TimeInterval, in segments: [Segment]) -> Set<String> {
        var result: Set<String> = []
        for segment in segments where time >= segment.start && time < segment.end {
            result.insert(segment.label)
        }
        return result
    }

    // MARK: - Speaker mapping

    /// The one-to-one reference→hypothesis assignment maximising matched
    /// duration — the mapping NIST `md-eval` and `pyannote.metrics` score
    /// under, found with the Hungarian (Kuhn–Munkres) algorithm in O(n³).
    ///
    /// It replaced an exhaustive search capped at seven speakers per side with
    /// a greedy fallback above that. Greedy is not optimal: taking the single
    /// largest overlap first can block two assignments that together match
    /// more, and every second it loses is scored as confusion. Checked against
    /// `pyannote.metrics` on random 8–12-speaker timelines, the greedy branch
    /// over-reported DER in three cases out of four, by up to ~8 points — and
    /// eight or more labels is not exotic: VoxConverse runs to 21 reference
    /// speakers, and the heuristic diarizer alone can emit eight.
    static func bestMapping(
        overlap: [String: [String: TimeInterval]],
        referenceLabels: [String],
        hypothesisLabels: [String]
    ) -> [String: String] {
        guard !referenceLabels.isEmpty, !hypothesisLabels.isEmpty else { return [:] }

        // Square cost matrix, padded with zero-gain rows/columns: a padded
        // pairing is "left unassigned", which is how an unequal speaker count
        // is expressed. Costs are negated gains because the algorithm minimises.
        let size = max(referenceLabels.count, hypothesisLabels.count)
        var cost = Array(repeating: Array(repeating: 0.0, count: size), count: size)
        for (row, referenceLabel) in referenceLabels.enumerated() {
            for (column, hypothesisLabel) in hypothesisLabels.enumerated() {
                cost[row][column] = -(overlap[referenceLabel]?[hypothesisLabel] ?? 0)
            }
        }

        let assignedRow = hungarianAssignment(cost: cost)

        var mapping: [String: String] = [:]
        for column in 0..<hypothesisLabels.count {
            let row = assignedRow[column]
            guard row >= 0, row < referenceLabels.count else { continue }
            let referenceLabel = referenceLabels[row]
            let hypothesisLabel = hypothesisLabels[column]
            // A zero-overlap pairing matches nothing; leaving it out keeps the
            // mapping to the assignments that actually carry agreement.
            guard (overlap[referenceLabel]?[hypothesisLabel] ?? 0) > 0 else { continue }
            mapping[referenceLabel] = hypothesisLabel
        }
        return mapping
    }

    /// Minimum-cost perfect assignment on a square matrix (the classic
    /// potentials formulation, 1-based internally). Returns, for each column,
    /// the row assigned to it.
    private static func hungarianAssignment(cost: [[Double]]) -> [Int] {
        let size = cost.count
        var rowPotential = [Double](repeating: 0, count: size + 1)
        var columnPotential = [Double](repeating: 0, count: size + 1)
        // `rowOfColumn[j]` is the row matched to column j; column 0 is the
        // virtual source of each augmenting path.
        var rowOfColumn = [Int](repeating: 0, count: size + 1)
        var previousColumn = [Int](repeating: 0, count: size + 1)

        for row in 1...size {
            rowOfColumn[0] = row
            var column = 0
            var minimumSlack = [Double](repeating: .infinity, count: size + 1)
            var visited = [Bool](repeating: false, count: size + 1)
            repeat {
                visited[column] = true
                let currentRow = rowOfColumn[column]
                var delta = Double.infinity
                var nextColumn = 0
                for candidate in 1...size where !visited[candidate] {
                    let reduced = cost[currentRow - 1][candidate - 1]
                        - rowPotential[currentRow] - columnPotential[candidate]
                    if reduced < minimumSlack[candidate] {
                        minimumSlack[candidate] = reduced
                        previousColumn[candidate] = column
                    }
                    if minimumSlack[candidate] < delta {
                        delta = minimumSlack[candidate]
                        nextColumn = candidate
                    }
                }
                for candidate in 0...size {
                    if visited[candidate] {
                        rowPotential[rowOfColumn[candidate]] += delta
                        columnPotential[candidate] -= delta
                    } else {
                        minimumSlack[candidate] -= delta
                    }
                }
                column = nextColumn
            } while rowOfColumn[column] != 0

            // Flip the augmenting path back to the source.
            repeat {
                let previous = previousColumn[column]
                rowOfColumn[column] = rowOfColumn[previous]
                column = previous
            } while column != 0
        }

        return (1...size).map { rowOfColumn[$0] - 1 }
    }
}
