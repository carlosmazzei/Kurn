//
//  SpeakerIdentityMatcher.swift
//  Kurn
//
//  Decides which speaker in a new diarization is which speaker from the last
//  one, by voice rather than by name.
//
//  This exists because `"Speaker 2"` identifies nobody. The diarizer assigns
//  those labels in order of first appearance, freshly on every run, so they are
//  not stable across a re-transcription — and the app was using them as the
//  identity of a `Speaker` row that carries a name the user typed. Both
//  available readings of that are wrong: dropping the row when its label stops
//  appearing loses the name, and keeping the row under the same label hands the
//  name to whoever the diarizer now happens to call Speaker 2. There is no
//  correct answer available from labels alone, which is why this asks the
//  embeddings instead.
//
//  Pure and separate from SwiftData so the decision can be tested as the
//  arithmetic it is.
//

import Accelerate
import Foundation

enum SpeakerIdentityMatcher {

    /// One speaker's stored voice, as persisted on `Speaker.voiceprintData`.
    struct Candidate: Sendable, Equatable {
        var label: String
        var voiceprint: [Float]
    }

    /// Cosine distance below which two voiceprints are the same person.
    ///
    /// Inherited rather than invented: it is `SpeakerClusterRefiner`'s own
    /// `minSpeakerSeparation`, which is in turn anchored to FluidAudio's
    /// agglomerative `threshold = 0.6` calibration for "these are one speaker".
    /// Reusing it keeps one definition of same-voice in the app rather than two
    /// that can drift apart.
    static var sameSpeakerDistance: Double { SpeakerClusterRefiner.minSpeakerSeparation }

    /// Map stored speakers onto the labels a fresh diarization produced.
    ///
    /// Greedy by increasing distance and strictly one-to-one: the closest pair
    /// in the whole matrix is taken first, both sides are then spent, and the
    /// process repeats. Two people cannot be merged into one row, and one person
    /// cannot claim two.
    ///
    /// - Returns: stored label → new label, for the pairs close enough to be the
    ///   same voice. Anything not confidently matched is simply absent, which the
    ///   caller must treat as "unknown", never as "no longer present".
    static func match(existing: [Candidate], incoming: [Candidate]) -> [String: String] {
        let storedVectors = usableVectors(existing)
        let freshVectors = usableVectors(incoming)
        guard !storedVectors.isEmpty, !freshVectors.isEmpty else { return [:] }

        var pairs: [(existing: String, incoming: String, distance: Double)] = []
        for stored in storedVectors {
            for fresh in freshVectors where fresh.vector.count == stored.vector.count {
                var dot: Double = 0
                vDSP_dotprD(stored.vector, 1, fresh.vector, 1, &dot, vDSP_Length(stored.vector.count))
                let distance = 1 - dot
                guard distance.isFinite, distance < sameSpeakerDistance else { continue }
                pairs.append((stored.label, fresh.label, distance))
            }
        }

        // Sorted by distance, then by label, so an exact tie does not depend on
        // dictionary iteration order — a diarization run must produce the same
        // speaker rows twice.
        pairs.sort {
            $0.distance == $1.distance
                ? ($0.existing, $0.incoming) < ($1.existing, $1.incoming)
                : $0.distance < $1.distance
        }

        var mapping: [String: String] = [:]
        var claimed: Set<String> = []
        for pair in pairs where mapping[pair.existing] == nil && !claimed.contains(pair.incoming) {
            mapping[pair.existing] = pair.incoming
            claimed.insert(pair.incoming)
        }
        return mapping
    }

    private static func usableVectors(_ candidates: [Candidate]) -> [(label: String, vector: [Double])] {
        candidates.compactMap { candidate in
            guard !candidate.voiceprint.isEmpty,
                  candidate.voiceprint.allSatisfy(\.isFinite) else { return nil }
            return (candidate.label, SpeakerClusterRefiner.normalized(candidate.voiceprint))
        }
    }
}

/// Averages the diarizer's per-window embeddings into one vector per speaker.
///
/// The windows are what the model actually produced; a speaker's voiceprint is
/// their mean, over the windows falling inside the turns attributed to them. It
/// is deliberately computed *after* smoothing and any collapse rescue, so the
/// vector describes the speaker as finally reported rather than as first
/// clustered.
enum SpeakerVoiceprints {

    /// A window counts towards a turn when its midpoint is inside it — the same
    /// rule the rest of the pipeline uses to attribute a span to a turn, and the
    /// one that keeps a window straddling a handover from being counted twice.
    static func centroids(
        turns: [SpeakerTurn],
        windows: [SpeakerEmbeddingWindow]
    ) -> [String: [Float]] {
        guard !turns.isEmpty, !windows.isEmpty else { return [:] }
        guard let dimension = windows.first(where: { !$0.embedding.isEmpty })?.embedding.count else {
            return [:]
        }

        var sums: [String: [Double]] = [:]
        var counts: [String: Int] = [:]
        for window in windows where window.embedding.count == dimension {
            guard window.embedding.allSatisfy(\.isFinite) else { continue }
            let midpoint = (window.start + window.end) / 2
            guard let turn = turns.first(where: { midpoint >= $0.start && midpoint < $0.end }) else { continue }

            let normalized = SpeakerClusterRefiner.normalized(window.embedding)
            var running = sums[turn.speakerLabel] ?? [Double](repeating: 0, count: dimension)
            for index in 0..<dimension { running[index] += normalized[index] }
            sums[turn.speakerLabel] = running
            counts[turn.speakerLabel, default: 0] += 1
        }

        return sums.reduce(into: [:]) { result, entry in
            guard let count = counts[entry.key], count > 0 else { return }
            let mean = entry.value.map { $0 / Double(count) }
            // Re-normalized so cosine distance against it is a plain dot
            // product, matching how `SpeakerIdentityMatcher` compares.
            var norm: Double = 0
            vDSP_svesqD(mean, 1, &norm, vDSP_Length(mean.count))
            guard norm > 0, norm.isFinite else { return }
            let scale = 1.0 / norm.squareRoot()
            result[entry.key] = mean.map { Float($0 * scale) }
        }
    }
}
