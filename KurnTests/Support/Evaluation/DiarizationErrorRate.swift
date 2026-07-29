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

    /// NIST's convention, and what published DER figures assume.
    static let defaultCollar: TimeInterval = 0.25

    /// Above this many speakers on either side, the optimal mapping is found
    /// greedily instead of exhaustively. 7! is 5,040 assignments — instant — and
    /// a meeting with more than seven distinct speakers is outside what this app
    /// diarizes anyway (`SpeakerDiarizer` caps at 8).
    private static let exhaustiveLimit = 7

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
    /// duration.
    static func bestMapping(
        overlap: [String: [String: TimeInterval]],
        referenceLabels: [String],
        hypothesisLabels: [String]
    ) -> [String: String] {
        guard !referenceLabels.isEmpty, !hypothesisLabels.isEmpty else { return [:] }
        if referenceLabels.count <= exhaustiveLimit, hypothesisLabels.count <= exhaustiveLimit {
            return exhaustiveMapping(
                overlap: overlap,
                referenceLabels: referenceLabels,
                hypothesisLabels: hypothesisLabels
            )
        }
        return greedyMapping(
            overlap: overlap,
            referenceLabels: referenceLabels,
            hypothesisLabels: hypothesisLabels
        )
    }

    private static func exhaustiveMapping(
        overlap: [String: [String: TimeInterval]],
        referenceLabels: [String],
        hypothesisLabels: [String]
    ) -> [String: String] {
        var best: [String: String] = [:]
        var bestScore: TimeInterval = -1
        var assignment: [String: String] = [:]
        var used: Set<String> = []

        func search(_ index: Int, _ score: TimeInterval) {
            guard index < referenceLabels.count else {
                if score > bestScore {
                    bestScore = score
                    best = assignment
                }
                return
            }
            let referenceLabel = referenceLabels[index]
            // Leaving a reference speaker unassigned is a legitimate option when
            // the hypothesis found fewer speakers than there were.
            search(index + 1, score)
            for hypothesisLabel in hypothesisLabels where !used.contains(hypothesisLabel) {
                let gain = overlap[referenceLabel]?[hypothesisLabel] ?? 0
                guard gain > 0 else { continue }
                used.insert(hypothesisLabel)
                assignment[referenceLabel] = hypothesisLabel
                search(index + 1, score + gain)
                assignment[referenceLabel] = nil
                used.remove(hypothesisLabel)
            }
        }

        search(0, 0)
        return best
    }

    private static func greedyMapping(
        overlap: [String: [String: TimeInterval]],
        referenceLabels: [String],
        hypothesisLabels: [String]
    ) -> [String: String] {
        var pairs: [(reference: String, hypothesis: String, gain: TimeInterval)] = []
        for referenceLabel in referenceLabels {
            for hypothesisLabel in hypothesisLabels {
                let gain = overlap[referenceLabel]?[hypothesisLabel] ?? 0
                if gain > 0 { pairs.append((referenceLabel, hypothesisLabel, gain)) }
            }
        }
        // Sorted by gain, then by name, so an exact tie does not depend on
        // dictionary iteration order.
        pairs.sort {
            $0.gain == $1.gain
                ? ($0.reference, $0.hypothesis) < ($1.reference, $1.hypothesis)
                : $0.gain > $1.gain
        }

        var mapping: [String: String] = [:]
        var usedHypothesis: Set<String> = []
        for pair in pairs where mapping[pair.reference] == nil && !usedHypothesis.contains(pair.hypothesis) {
            mapping[pair.reference] = pair.hypothesis
            usedHypothesis.insert(pair.hypothesis)
        }
        return mapping
    }
}
