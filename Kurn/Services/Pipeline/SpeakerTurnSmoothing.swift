//
//  SpeakerTurnSmoothing.swift
//  Kurn
//
//  Post-processing applied to a diarizer's raw speaker turns before they reach
//  `TranscriptFusion`.
//
//  Neural diarizers emit one turn per contiguous run of frames assigned to a
//  cluster, which on real meeting audio means a long tail of sub-second turns:
//  a cough, a back-channel "mhm", or a single misclassified frame in the middle
//  of someone else's sentence. Fused verbatim, each of those flips the speaker
//  label mid-paragraph and makes the transcript look far less accurate than the
//  underlying segmentation actually is.
//
//  Three passes, all pure and order-preserving:
//    1. merge consecutive same-speaker turns separated by a short gap,
//    2. absorb turns too short to be a real utterance into their neighbours,
//    3. drop speakers whose total speaking time is implausibly small.
//

import Foundation

enum SpeakerTurnSmoothing {

    /// Consecutive turns by the same speaker closer together than this are one
    /// turn — the gap is a breath or an inter-word pause, not a handover.
    static let defaultMaxMergeGap: TimeInterval = 0.75

    /// Turns shorter than this are treated as segmentation noise rather than a
    /// real utterance and folded into an adjacent turn.
    static let defaultMinTurnDuration: TimeInterval = 0.7

    /// A speaker whose *total* speaking time across the whole recording is below
    /// this is almost always a phantom cluster (one noisy embedding window), not
    /// a participant.
    static let defaultMinSpeakerTotalDuration: TimeInterval = 3.0

    /// Run all three passes. Labels are renumbered to "Speaker N" in
    /// first-appearance order so the output is contiguous even after speakers
    /// have been dropped.
    ///
    /// Guaranteed never to return an empty array for a non-empty input: every
    /// pass that could remove everything is skipped when it would.
    static func smooth(
        _ turns: [SpeakerTurn],
        maxMergeGap: TimeInterval = defaultMaxMergeGap,
        minTurnDuration: TimeInterval = defaultMinTurnDuration,
        minSpeakerTotalDuration: TimeInterval = defaultMinSpeakerTotalDuration
    ) -> [SpeakerTurn] {
        guard turns.count > 1 else { return turns }

        var result = mergeAdjacent(turns.sorted { $0.start < $1.start }, maxGap: maxMergeGap)
        result = absorbShortTurns(result, minDuration: minTurnDuration)
        result = mergeAdjacent(result, maxGap: maxMergeGap)
        result = dropMarginalSpeakers(result, minTotalDuration: minSpeakerTotalDuration)
        return renumber(result)
    }

    // MARK: - Pass 1: merge

    /// Collapse consecutive same-speaker turns whose gap is at most `maxGap`.
    /// Overlapping turns (gap < 0) always merge.
    static func mergeAdjacent(_ turns: [SpeakerTurn], maxGap: TimeInterval) -> [SpeakerTurn] {
        guard !turns.isEmpty else { return turns }
        var merged: [SpeakerTurn] = [turns[0]]
        for turn in turns.dropFirst() {
            let previous = merged[merged.count - 1]
            if turn.speakerLabel == previous.speakerLabel, turn.start - previous.end <= maxGap {
                merged[merged.count - 1].end = max(previous.end, turn.end)
            } else {
                merged.append(turn)
            }
        }
        return merged
    }

    // MARK: - Pass 2: absorb short turns

    /// Remove turns shorter than `minDuration`, handing their time span to a
    /// neighbour so the timeline keeps its coverage.
    ///
    /// A short turn sandwiched between two turns by the same speaker is the
    /// classic mid-sentence flip and is absorbed by extending that speaker
    /// across it. Otherwise it goes to whichever neighbour it is closer to,
    /// falling back to the longer one on a tie.
    ///
    /// Skipped entirely when *every* turn is short — that's a legitimately
    /// rapid-fire exchange, not noise, and dropping all of it would leave
    /// fusion with nothing.
    static func absorbShortTurns(_ turns: [SpeakerTurn], minDuration: TimeInterval) -> [SpeakerTurn] {
        guard turns.count > 1 else { return turns }
        guard turns.contains(where: { $0.end - $0.start >= minDuration }) else { return turns }

        var result = turns
        var index = 0
        while index < result.count {
            guard result.count > 1, result[index].end - result[index].start < minDuration else {
                index += 1
                continue
            }
            let short = result[index]
            let previous = index > 0 ? result[index - 1] : nil
            let next = index + 1 < result.count ? result[index + 1] : nil

            switch absorbTarget(short: short, previous: previous, next: next) {
            case .previous:
                result[index - 1].end = max(result[index - 1].end, short.end)
                result.remove(at: index)
            case .next:
                result[index + 1].start = min(result[index + 1].start, short.start)
                result.remove(at: index)
            }
        }
        return result
    }

    private enum AbsorbTarget { case previous, next }

    private static func absorbTarget(
        short: SpeakerTurn,
        previous: SpeakerTurn?,
        next: SpeakerTurn?
    ) -> AbsorbTarget {
        guard let previous else { return .next }
        guard let next else { return .previous }
        if previous.speakerLabel == next.speakerLabel { return .previous }
        let gapBefore = short.start - previous.end
        let gapAfter = next.start - short.end
        if gapBefore != gapAfter { return gapBefore < gapAfter ? .previous : .next }
        return (previous.end - previous.start) >= (next.end - next.start) ? .previous : .next
    }

    // MARK: - Pass 3: drop phantom speakers

    /// Remove every turn belonging to a speaker who barely speaks, provided at
    /// least two speakers survive. The removed spans are simply left uncovered:
    /// `TranscriptFusion` attributes text with no containing turn to the nearest
    /// remaining one, which is exactly the desired behaviour here.
    static func dropMarginalSpeakers(
        _ turns: [SpeakerTurn],
        minTotalDuration: TimeInterval
    ) -> [SpeakerTurn] {
        let totals = turns.reduce(into: [String: TimeInterval]()) { totals, turn in
            totals[turn.speakerLabel, default: 0] += max(0, turn.end - turn.start)
        }
        guard totals.count > 2 else { return turns }
        let keep = totals.filter { $0.value >= minTotalDuration }.keys
        guard keep.count >= 2, keep.count < totals.count else { return turns }
        return turns.filter { keep.contains($0.speakerLabel) }
    }

    // MARK: - Relabel

    /// Renumber to "Speaker N" in first-appearance order so the labels stay
    /// contiguous and match every other engine's convention.
    static func renumber(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var nameByOriginal: [String: String] = [:]
        return turns.map { turn in
            let label = nameByOriginal[turn.speakerLabel] ?? {
                let next = "Speaker \(nameByOriginal.count + 1)"
                nameByOriginal[turn.speakerLabel] = next
                return next
            }()
            return SpeakerTurn(speakerLabel: label, start: turn.start, end: turn.end)
        }
    }
}
