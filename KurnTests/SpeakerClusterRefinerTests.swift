//
//  SpeakerClusterRefinerTests.swift
//  KurnTests
//

import Foundation
import Testing
@testable import Kurn

struct SpeakerClusterRefinerTests {

    // MARK: - Fixtures

    /// Deterministic pseudo-random generator so the synthetic embeddings are
    /// identical on every run (no flaky clustering).
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    /// Build embedding windows around `centers`, cycling through the speakers so
    /// the timeline alternates, with a little jitter on every dimension.
    private static func windows(
        centers: [[Float]],
        perSpeaker: Int,
        jitter: Float,
        windowDuration: TimeInterval = 1.5,
        seed: UInt64 = 42
    ) -> (windows: [SpeakerEmbeddingWindow], truth: [Int]) {
        var generator = SeededGenerator(seed: seed)
        var windows: [SpeakerEmbeddingWindow] = []
        var truth: [Int] = []
        var time: TimeInterval = 0
        for index in 0..<(perSpeaker * centers.count) {
            let speaker = index % centers.count
            let embedding = centers[speaker].map { value -> Float in
                value + Float.random(in: -jitter...jitter, using: &generator)
            }
            windows.append(
                SpeakerEmbeddingWindow(start: time, end: time + windowDuration, embedding: embedding)
            )
            truth.append(speaker)
            time += windowDuration
        }
        return (windows, truth)
    }

    private static func orthogonalCenters(_ count: Int, dimension: Int = 16) -> [[Float]] {
        (0..<count).map { speaker in
            (0..<dimension).map { $0 % count == speaker ? Float(1) : Float(0) }
        }
    }

    /// Cluster ids are arbitrary; compare partitions instead of raw labels.
    private static func isSamePartition(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var forward: [Int: Int] = [:]
        var backward: [Int: Int] = [:]
        for (left, right) in zip(lhs, rhs) {
            if let mapped = forward[left], mapped != right { return false }
            if let mapped = backward[right], mapped != left { return false }
            forward[left] = right
            backward[right] = left
        }
        return true
    }

    // MARK: - clusterLabels

    @Test func recoversTwoWellSeparatedSpeakers() throws {
        let (windows, truth) = Self.windows(
            centers: Self.orthogonalCenters(2), perSpeaker: 20, jitter: 0.05
        )
        let labels = try #require(SpeakerClusterRefiner.clusterLabels(for: windows))
        #expect(Set(labels).count == 2)
        #expect(Self.isSamePartition(labels, truth))
    }

    @Test func recoversThreeWellSeparatedSpeakers() throws {
        let (windows, truth) = Self.windows(
            centers: Self.orthogonalCenters(3), perSpeaker: 15, jitter: 0.05
        )
        let labels = try #require(SpeakerClusterRefiner.clusterLabels(for: windows))
        #expect(Set(labels).count == 3)
        #expect(Self.isSamePartition(labels, truth))
    }

    @Test func singleSpeakerIsNotSplit() {
        let (windows, _) = Self.windows(
            centers: Self.orthogonalCenters(1), perSpeaker: 40, jitter: 0.25
        )
        // One voice with only jitter around it: any partition's centroids stay
        // far closer than `minSpeakerSeparation`, so the refiner must decline
        // rather than invent speakers. (Silhouette alone would not catch this —
        // splitting a single blob in half still scores respectably.)
        #expect(SpeakerClusterRefiner.clusterLabels(for: windows) == nil)
    }

    @Test func nearlyIdenticalCentroidsAreNotAPlausibleSplit() {
        let centroids = [
            SpeakerClusterRefiner.normalized([1, 0.02]),
            SpeakerClusterRefiner.normalized([1, -0.02])
        ]
        #expect(
            !SpeakerClusterRefiner.isPlausibleSplit(
                labels: [0, 0, 1, 1], clusterCount: 2, centroids: centroids
            )
        )
    }

    @Test func wellSeparatedCentroidsAreAPlausibleSplit() {
        let centroids = [
            SpeakerClusterRefiner.normalized([1, 0]),
            SpeakerClusterRefiner.normalized([0, 1])
        ]
        #expect(
            SpeakerClusterRefiner.isPlausibleSplit(
                labels: [0, 0, 1, 1], clusterCount: 2, centroids: centroids
            )
        )
    }

    @Test func aSingletonOutlierClusterIsNotAPlausibleSplit() {
        let centroids = [
            SpeakerClusterRefiner.normalized([1, 0]),
            SpeakerClusterRefiner.normalized([0, 1])
        ]
        #expect(
            !SpeakerClusterRefiner.isPlausibleSplit(
                labels: [0, 0, 0, 1], clusterCount: 2, centroids: centroids
            )
        )
    }

    @Test func tooFewWindowsDeclinesToSplit() {
        let (windows, _) = Self.windows(
            centers: Self.orthogonalCenters(2), perSpeaker: 3, jitter: 0.05
        )
        #expect(windows.count < SpeakerClusterRefiner.minWindowsForSplit)
        #expect(SpeakerClusterRefiner.clusterLabels(for: windows) == nil)
    }

    @Test func shortWindowsAreIgnoredButStillLabelled() throws {
        var (windows, _) = Self.windows(
            centers: Self.orthogonalCenters(2), perSpeaker: 20, jitter: 0.05
        )
        // A sub-threshold window is too brief to embed reliably, so it must not
        // steer clustering — but it still needs a label so the caller can index
        // labels by window position.
        windows.append(
            SpeakerEmbeddingWindow(
                start: 100, end: 100.1, embedding: Self.orthogonalCenters(2)[1]
            )
        )
        let labels = try #require(SpeakerClusterRefiner.clusterLabels(for: windows))
        #expect(labels.count == windows.count)
        #expect(labels.last == labels[1])
    }

    @Test func speakerCountIsCappedAtMaximum() throws {
        let (windows, _) = Self.windows(
            centers: Self.orthogonalCenters(6, dimension: 6), perSpeaker: 8, jitter: 0.03
        )
        let labels = try #require(SpeakerClusterRefiner.clusterLabels(for: windows, maxSpeakers: 3))
        #expect(Set(labels).count <= 3)
    }

    @Test func nonFiniteEmbeddingsDoNotCrashClustering() {
        var (windows, _) = Self.windows(
            centers: Self.orthogonalCenters(2), perSpeaker: 20, jitter: 0.05
        )
        windows[0].embedding[0] = .nan
        windows[1].embedding[1] = .infinity
        let labels = SpeakerClusterRefiner.clusterLabels(for: windows)
        #expect(labels?.count == windows.count)
    }

    // MARK: - Helpers

    @Test func stridedSampleKeepsEveryIndexWhenUnderCap() {
        #expect(SpeakerClusterRefiner.stridedSample(count: 5, cap: 10) == [0, 1, 2, 3, 4])
    }

    @Test func stridedSampleSpreadsAcrossTheWholeRange() {
        let sample = SpeakerClusterRefiner.stridedSample(count: 100, cap: 10)
        #expect(sample.count == 10)
        #expect(sample.first == 0)
        #expect(sample.last == 90)
        #expect(sample == sample.sorted())
    }

    @Test func normalizedVectorHasUnitLength() {
        let unit = SpeakerClusterRefiner.normalized([3, 4, 0])
        let norm = unit.reduce(0) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(norm - 1.0) < 1e-9)
    }

    @Test func normalizedZeroVectorStaysZero() {
        #expect(SpeakerClusterRefiner.normalized([0, 0, 0]) == [0, 0, 0])
    }

    @Test func cosineDistanceIsZeroForIdenticalAndOneForOrthogonal() {
        let vectors = [
            SpeakerClusterRefiner.normalized([1, 0]),
            SpeakerClusterRefiner.normalized([1, 0]),
            SpeakerClusterRefiner.normalized([0, 1])
        ]
        let matrix = SpeakerClusterRefiner.cosineDistanceMatrix(vectors)
        #expect(abs(matrix[0 * 3 + 1]) < 1e-9)
        #expect(abs(matrix[0 * 3 + 2] - 1.0) < 1e-9)
        // Symmetric, zero diagonal.
        #expect(matrix[2 * 3 + 0] == matrix[0 * 3 + 2])
        #expect(matrix[1 * 3 + 1] == 0)
    }

    @Test func averageLinkageSeparatesTwoTightGroups() throws {
        let vectors = [
            SpeakerClusterRefiner.normalized([1, 0]),
            SpeakerClusterRefiner.normalized([0.99, 0.05]),
            SpeakerClusterRefiner.normalized([0, 1]),
            SpeakerClusterRefiner.normalized([0.05, 0.99])
        ]
        let distances = SpeakerClusterRefiner.cosineDistanceMatrix(vectors)
        let snapshots = SpeakerClusterRefiner.averageLinkageSnapshots(
            distances: distances, count: 4, upTo: 3
        )
        let two = try #require(snapshots[2])
        #expect(two[0] == two[1])
        #expect(two[2] == two[3])
        #expect(two[0] != two[2])
        #expect(snapshots[1] == [0, 0, 0, 0])
    }

    @Test func silhouetteIsHigherForTheCorrectPartition() {
        let vectors = [
            SpeakerClusterRefiner.normalized([1, 0]),
            SpeakerClusterRefiner.normalized([0.99, 0.05]),
            SpeakerClusterRefiner.normalized([0, 1]),
            SpeakerClusterRefiner.normalized([0.05, 0.99])
        ]
        let distances = SpeakerClusterRefiner.cosineDistanceMatrix(vectors)
        let good = SpeakerClusterRefiner.meanSilhouette(
            labels: [0, 0, 1, 1], clusterCount: 2, distances: distances
        )
        let bad = SpeakerClusterRefiner.meanSilhouette(
            labels: [0, 1, 0, 1], clusterCount: 2, distances: distances
        )
        #expect(good > bad)
        #expect(good > SpeakerClusterRefiner.minAcceptableSilhouette)
    }

    // MARK: - reassign

    @Test func reassignAttributesTurnsByOverlap() {
        let turns = [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 10),
            SpeakerTurn(speakerLabel: "Speaker 1", start: 10, end: 20)
        ]
        let windows = [
            SpeakerEmbeddingWindow(start: 0, end: 9, embedding: [1, 0]),
            SpeakerEmbeddingWindow(start: 11, end: 20, embedding: [0, 1])
        ]
        let result = SpeakerClusterRefiner.reassign(turns: turns, windows: windows, labels: [0, 1])
        #expect(result.map(\.speakerLabel) == ["Speaker 1", "Speaker 2"])
        // Boundaries are the diarizer's and must survive untouched.
        #expect(result.map(\.start) == [0, 10])
        #expect(result.map(\.end) == [10, 20])
    }

    @Test func reassignFallsBackToNearestWindowWhenNothingOverlaps() {
        let turns = [SpeakerTurn(speakerLabel: "Speaker 1", start: 30, end: 31)]
        let windows = [
            SpeakerEmbeddingWindow(start: 0, end: 5, embedding: [1, 0]),
            SpeakerEmbeddingWindow(start: 25, end: 29, embedding: [0, 1])
        ]
        let result = SpeakerClusterRefiner.reassign(turns: turns, windows: windows, labels: [0, 1])
        #expect(result.count == 1)
        #expect(result[0].speakerLabel == "Speaker 1")
    }

    @Test func reassignIsANoOpForASingleCluster() {
        let turns = [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 5)]
        let windows = [SpeakerEmbeddingWindow(start: 0, end: 5, embedding: [1, 0])]
        #expect(SpeakerClusterRefiner.reassign(turns: turns, windows: windows, labels: [0]) == turns)
    }

    @Test func reassignNumbersSpeakersInFirstAppearanceOrder() {
        let turns = [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 5),
            SpeakerTurn(speakerLabel: "Speaker 1", start: 5, end: 10),
            SpeakerTurn(speakerLabel: "Speaker 1", start: 10, end: 15)
        ]
        let windows = [
            SpeakerEmbeddingWindow(start: 0, end: 5, embedding: [0, 1]),
            SpeakerEmbeddingWindow(start: 5, end: 10, embedding: [1, 0]),
            SpeakerEmbeddingWindow(start: 10, end: 15, embedding: [0, 1])
        ]
        // Cluster ids 2, 0, 2 must come back as Speaker 1, Speaker 2, Speaker 1.
        let result = SpeakerClusterRefiner.reassign(
            turns: turns, windows: windows, labels: [2, 0, 2]
        )
        #expect(result.map(\.speakerLabel) == ["Speaker 1", "Speaker 2", "Speaker 1"])
    }
}
