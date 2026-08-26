//
//  SpeakerIdentityTests.swift
//  KurnTests
//
//  Whether a name the user typed stays on the right person.
//
//  The bug these exist for is silent in both directions, which is what makes it
//  worth testing rather than eyeballing: deleting a `Speaker` row whose label
//  stopped appearing loses the name with no error, and keeping the row under its
//  old label hands the name to a different person with no error either. Neither
//  shows up as a failure anywhere — only as a transcript that quietly attributes
//  words to the wrong human.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

struct SpeakerIdentityTests {

    // MARK: - Fixtures

    /// A unit vector pointing mostly along `axis`, with `noise` mixed in from the
    /// next axis. Small noise = the same voice recorded again; large = someone
    /// else.
    private static func voiceprint(axis: Int, noise: Float = 0, dimension: Int = 8) -> [Float] {
        var vector = [Float](repeating: 0, count: dimension)
        vector[axis % dimension] = 1
        vector[(axis + 1) % dimension] = noise
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : vector
    }

    private static func candidate(_ label: String, axis: Int, noise: Float = 0) -> SpeakerIdentityMatcher.Candidate {
        SpeakerIdentityMatcher.Candidate(label: label, voiceprint: voiceprint(axis: axis, noise: noise))
    }

    // MARK: - Matching

    /// The renumbering case, which is the whole point: the same two voices come
    /// back under swapped labels, and the names have to follow the voices.
    @Test func matchesTheSameVoicesAcrossRenumbering() {
        let mapping = SpeakerIdentityMatcher.match(
            existing: [Self.candidate("Speaker 1", axis: 0), Self.candidate("Speaker 2", axis: 3)],
            incoming: [
                Self.candidate("Speaker 1", axis: 3, noise: 0.05),
                Self.candidate("Speaker 2", axis: 0, noise: 0.05)
            ]
        )
        #expect(mapping["Speaker 1"] == "Speaker 2")
        #expect(mapping["Speaker 2"] == "Speaker 1")
    }

    /// A different voice must not be claimed. Silence here is the correct
    /// answer — "unknown", never "this one will do".
    @Test func doesNotMatchADifferentVoice() {
        let mapping = SpeakerIdentityMatcher.match(
            existing: [Self.candidate("Speaker 1", axis: 0)],
            incoming: [Self.candidate("Speaker 1", axis: 4)]
        )
        #expect(mapping.isEmpty)
    }

    /// One person cannot become two rows, and two cannot collapse into one.
    @Test func matchingIsOneToOne() {
        let mapping = SpeakerIdentityMatcher.match(
            existing: [Self.candidate("A", axis: 0), Self.candidate("B", axis: 0, noise: 0.02)],
            incoming: [Self.candidate("X", axis: 0, noise: 0.01)]
        )
        #expect(mapping.count == 1)
        #expect(Set(mapping.values).count == mapping.count)
    }

    @Test func missingVoiceprintsMatchNothing() {
        #expect(SpeakerIdentityMatcher.match(existing: [], incoming: [Self.candidate("A", axis: 0)]).isEmpty)
        #expect(
            SpeakerIdentityMatcher.match(
                existing: [SpeakerIdentityMatcher.Candidate(label: "A", voiceprint: [])],
                incoming: [Self.candidate("A", axis: 0)]
            ).isEmpty
        )
    }

    /// Two runs over the same input must produce the same rows; a mapping that
    /// depended on dictionary order would reshuffle speakers between saves.
    @Test func matchingIsDeterministic() {
        let existing = [Self.candidate("A", axis: 0), Self.candidate("B", axis: 0, noise: 0.03)]
        let incoming = [Self.candidate("X", axis: 0, noise: 0.01), Self.candidate("Y", axis: 0, noise: 0.02)]
        let first = SpeakerIdentityMatcher.match(existing: existing, incoming: incoming)
        for _ in 0..<5 {
            #expect(SpeakerIdentityMatcher.match(existing: existing, incoming: incoming) == first)
        }
    }

    // MARK: - Voiceprints from the diarizer's windows

    @Test func averagesTheWindowsInsideEachTurn() {
        let turns = [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 10),
            SpeakerTurn(speakerLabel: "Speaker 2", start: 10, end: 20)
        ]
        let windows = [
            SpeakerEmbeddingWindow(start: 0, end: 2, embedding: Self.voiceprint(axis: 0)),
            SpeakerEmbeddingWindow(start: 2, end: 4, embedding: Self.voiceprint(axis: 0, noise: 0.1)),
            SpeakerEmbeddingWindow(start: 12, end: 14, embedding: Self.voiceprint(axis: 4))
        ]

        let centroids = SpeakerVoiceprints.centroids(turns: turns, windows: windows)
        #expect(centroids.count == 2)
        // Unit length, so cosine distance against it is a plain dot product.
        let norm = (centroids["Speaker 1"] ?? []).reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(norm - 1) < 1e-5)
        // The two speakers' centroids are far enough apart to be distinguished.
        let mapping = SpeakerIdentityMatcher.match(
            existing: [SpeakerIdentityMatcher.Candidate(label: "old", voiceprint: centroids["Speaker 1"] ?? [])],
            incoming: [
                SpeakerIdentityMatcher.Candidate(label: "one", voiceprint: centroids["Speaker 1"] ?? []),
                SpeakerIdentityMatcher.Candidate(label: "two", voiceprint: centroids["Speaker 2"] ?? [])
            ]
        )
        #expect(mapping["old"] == "one")
    }

    /// A window straddling a handover is counted once, on the side its midpoint
    /// falls — the same rule the rest of the pipeline attributes spans with.
    @Test func aWindowBelongsToOneTurnOnly() {
        let turns = [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 10),
            SpeakerTurn(speakerLabel: "Speaker 2", start: 10, end: 20)
        ]
        let windows = [SpeakerEmbeddingWindow(start: 9, end: 13, embedding: Self.voiceprint(axis: 0))]
        let centroids = SpeakerVoiceprints.centroids(turns: turns, windows: windows)
        #expect(centroids.count == 1)
        #expect(centroids["Speaker 2"] != nil)
    }

    @Test func noWindowsMeansNoVoiceprints() {
        let turns = [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 10)]
        #expect(SpeakerVoiceprints.centroids(turns: turns, windows: []).isEmpty)
        #expect(SpeakerVoiceprints.centroids(turns: [], windows: []).isEmpty)
    }

    @Test func voiceprintRoundTripsThroughTheModel() {
        let vector = Self.voiceprint(axis: 2, noise: 0.3)
        let speaker = Speaker(label: "Speaker 1", color: "#FFFFFF", voiceprintData: VectorData.encode(vector))
        let decoded = speaker.voiceprint ?? []
        #expect(decoded.count == vector.count)
        #expect(zip(decoded, vector).allSatisfy { abs($0 - $1) < 1e-6 })
        #expect(Speaker(label: "Speaker 1", color: "#FFFFFF").voiceprint == nil)
    }

    // MARK: - closestMatch (D6: cross-meeting lookup)

    /// `match` assumes each side is addressable by a unique label, which is
    /// false across the whole store — "Speaker 1" is the label of countless
    /// different people in countless different meetings. `closestMatch` is
    /// what a cross-meeting lookup uses instead: nearest single candidate to
    /// one voiceprint, over an arbitrary pool with no uniqueness assumption.
    @Test func closestMatchFindsTheNearestCandidateUnderThreshold() {
        let match = SpeakerIdentityMatcher.closestMatch(
            to: Self.voiceprint(axis: 0, noise: 0.05),
            among: [
                (value: "far", voiceprint: Self.voiceprint(axis: 4)),
                (value: "near", voiceprint: Self.voiceprint(axis: 0))
            ]
        )
        #expect(match == "near")
    }

    @Test func closestMatchReturnsNilWhenNothingIsCloseEnough() {
        let match = SpeakerIdentityMatcher.closestMatch(
            to: Self.voiceprint(axis: 0),
            among: [(value: "other", voiceprint: Self.voiceprint(axis: 4))]
        )
        #expect(match == nil)
    }

    @Test func closestMatchReturnsNilForAnEmptyPoolOrVoiceprint() {
        let empty: [(value: String, voiceprint: [Float])] = []
        #expect(SpeakerIdentityMatcher.closestMatch(to: Self.voiceprint(axis: 0), among: empty) == nil)

        let poolWithNoUsableVoiceprint: [(value: String, voiceprint: [Float])] = [(value: "x", voiceprint: [])]
        #expect(SpeakerIdentityMatcher.closestMatch(to: Self.voiceprint(axis: 0), among: poolWithNoUsableVoiceprint) == nil)

        #expect(
            SpeakerIdentityMatcher.closestMatch(
                to: [],
                among: [(value: "x", voiceprint: Self.voiceprint(axis: 0))]
            ) == nil
        )
    }

    /// The exact case `match` cannot handle: two different candidates that
    /// happen to carry the same label (as "Speaker 1" does across different
    /// meetings). `closestMatch` compares by voiceprint only, so the
    /// duplicate label never collapses them into one dictionary entry.
    @Test func closestMatchHandlesDuplicateLabelsAcrossCandidates() {
        struct Row: Equatable { let meetingID: Int; let label: String }
        let match = SpeakerIdentityMatcher.closestMatch(
            to: Self.voiceprint(axis: 0, noise: 0.05),
            among: [
                (value: Row(meetingID: 1, label: "Speaker 1"), voiceprint: Self.voiceprint(axis: 4)),
                (value: Row(meetingID: 2, label: "Speaker 1"), voiceprint: Self.voiceprint(axis: 0))
            ]
        )
        #expect(match == Row(meetingID: 2, label: "Speaker 1"))
    }
}
