//
//  SpeakerClusterRefiner.swift
//  Kurn
//
//  Pure re-clustering of speaker embeddings, used to rescue the FluidAudio
//  neural diarizer when its VBx step collapses every cluster into a single
//  speaker.
//
//  Why this exists: FluidAudio's offline pipeline ends with a variational-Bayes
//  step whose mixture weights routinely go to ~1e-20 for every component but one
//  on far-field / single-mic recordings. Everything downstream of that (centroid
//  computation, segment reconstruction) then sees exactly one speaker, so the
//  whole meeting comes back as "Speaker 1" even though the segmentation model
//  and the agglomerative init both clearly found several voices.
//
//  The per-window speaker embeddings that VBx clustered are available on the
//  result (`OfflineDiarizerConfig.exposeChunkEmbeddings`), so the collapse can be
//  undone without re-running any CoreML model: cluster those embeddings again
//  here with plain average-linkage agglomerative clustering, choose the speaker
//  count by silhouette score, and re-attribute the diarizer's own segment
//  boundaries to the new clusters.
//
//  Everything in this file is pure and synchronous so it can be unit tested
//  without audio or models.
//

import Accelerate
import Foundation
import KurnCore

/// One speaker embedding together with the time range it was extracted from.
/// Mirrors FluidAudio's `ChunkEmbedding` without depending on it, so the
/// clustering logic stays testable and the package import stays confined to
/// `FluidAudioDiarizer`.
struct SpeakerEmbeddingWindow: Sendable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var embedding: [Float]

    var duration: TimeInterval { max(0, end - start) }
}

enum SpeakerClusterRefiner {

    // MARK: - Tuning

    /// Upper bound on the speaker count the sweep will consider. Meetings with
    /// more distinct voices than this still work — they just get capped, which
    /// is far less damaging than the alternative failure (one bucket for
    /// everyone).
    static let defaultMaxSpeakers = 8

    /// Windows shorter than this are dropped before clustering: a fraction of a
    /// second of speech produces an embedding dominated by phonetic content
    /// rather than voice identity, which blurs the clusters.
    static let minWindowDuration: TimeInterval = 0.8

    /// Minimum number of usable windows before splitting is even attempted.
    /// Below this the silhouette score is too noisy to trust.
    static let minWindowsForSplit = 12

    /// Cap on how many windows enter the O(n²) distance matrix. Windows beyond
    /// the cap are subsampled with a uniform stride (so the whole meeting stays
    /// represented) and re-attached afterwards by nearest centroid.
    static let clusteringSampleCap = 512

    /// Mean silhouette a candidate split must reach to be accepted. Silhouette
    /// runs in `[-1, 1]`; ~0.15 is the conventional floor for "there is real
    /// structure here".
    static let minAcceptableSilhouette: Double = 0.15

    /// Minimum cosine distance (`1 - cosine similarity`) between two cluster
    /// centroids for them to count as different people.
    ///
    /// Silhouette alone is not enough of a guard: it measures *relative*
    /// separation, and splitting a single speaker's embedding cloud in half
    /// scores respectably even though both halves are the same voice. This is
    /// the absolute check, and 0.4 is not arbitrary — it is the same-speaker
    /// calibration FluidAudio's own agglomerative step uses on these
    /// embeddings (`clustering.threshold = 0.6` cosine *similarity*). Below it,
    /// the pipeline itself would have called the two clusters one speaker.
    static let minSpeakerSeparation: Double = 0.4

    /// Clusters holding fewer sampled windows than this are outliers rather than
    /// participants, and a candidate speaker count containing one is rejected.
    static let minWindowsPerCluster = 2

    // MARK: - Entry point

    /// Cluster `windows` into speakers and return one 0-based cluster id per
    /// input window.
    ///
    /// Returns `nil` when the data doesn't support a confident split — too few
    /// usable windows, or no candidate speaker count reaching
    /// `minAcceptableSilhouette`. A `nil` result means "keep whatever the
    /// caller already had"; it is never a failure to report to the user.
    static func clusterLabels(
        for windows: [SpeakerEmbeddingWindow],
        maxSpeakers: Int = defaultMaxSpeakers
    ) -> [Int]? {
        let usableIndices = windows.indices.filter { isUsable(windows[$0]) }
        guard usableIndices.count >= minWindowsForSplit else { return nil }

        let vectors = usableIndices.map { normalized(windows[$0].embedding) }
        guard let dimension = vectors.first?.count, dimension > 0 else { return nil }
        guard vectors.allSatisfy({ $0.count == dimension }) else { return nil }

        let sampleIndices = stridedSample(count: vectors.count, cap: clusteringSampleCap)
        let sample = sampleIndices.map { vectors[$0] }

        let ceiling = max(2, min(maxSpeakers, sample.count - 1))
        let distances = cosineDistanceMatrix(sample)
        let snapshots = averageLinkageSnapshots(
            distances: distances, count: sample.count, upTo: ceiling
        )

        var best: (labels: [Int], centroids: [[Double]], score: Double)?
        for (clusterCount, labels) in snapshots.sorted(by: { $0.key < $1.key }) where clusterCount >= 2 {
            let candidateCentroids = centroids(of: sample, labels: labels)
            guard isPlausibleSplit(labels: labels, clusterCount: clusterCount, centroids: candidateCentroids) else {
                continue
            }
            let score = meanSilhouette(labels: labels, clusterCount: clusterCount, distances: distances)
            guard score >= minAcceptableSilhouette else { continue }
            if score > (best?.score ?? -.greatestFiniteMagnitude) {
                best = (labels, candidateCentroids, score)
            }
        }

        guard let winner = best, !winner.centroids.isEmpty else { return nil }
        let winningCentroids = winner.centroids

        // Assign *every* window (including the ones dropped as too short or
        // skipped by the stride) to its nearest centroid, so the caller gets a
        // label for each input index.
        var labels = [Int](repeating: 0, count: windows.count)
        for (position, windowIndex) in usableIndices.enumerated() {
            labels[windowIndex] = nearestCentroid(to: vectors[position], centroids: winningCentroids)
        }
        for index in windows.indices where !isUsable(windows[index]) {
            let vector = normalized(windows[index].embedding)
            labels[index] = vector.count == dimension
                ? nearestCentroid(to: vector, centroids: winningCentroids)
                : 0
        }
        return labels
    }

    /// Re-attribute existing diarizer turns to the clusters in `labels`.
    ///
    /// Turn boundaries are kept as-is — they come from the neural segmentation
    /// model and are the part of the pipeline that works. Only the speaker
    /// *identity* is replaced, by an overlap-weighted vote of the embedding
    /// windows falling inside each turn. Output labels are renumbered to
    /// "Speaker N" in first-appearance order, matching every other engine.
    static func reassign(
        turns: [SpeakerTurn],
        windows: [SpeakerEmbeddingWindow],
        labels: [Int]
    ) -> [SpeakerTurn] {
        guard !turns.isEmpty, windows.count == labels.count, !windows.isEmpty else { return turns }
        let clusterCount = (labels.max() ?? 0) + 1
        guard clusterCount > 1 else { return turns }

        let ordered = turns.sorted { $0.start < $1.start }
        var rawLabels: [Int] = []
        rawLabels.reserveCapacity(ordered.count)

        for turn in ordered {
            var votes = [TimeInterval](repeating: 0, count: clusterCount)
            for (index, window) in windows.enumerated() {
                let overlap = min(turn.end, window.end) - max(turn.start, window.start)
                if overlap > 0 { votes[labels[index]] += overlap }
            }
            if let winner = argmax(votes), votes[winner] > 0 {
                rawLabels.append(winner)
            } else {
                rawLabels.append(nearestWindowLabel(to: turn, windows: windows, labels: labels))
            }
        }

        return relabelInFirstAppearanceOrder(turns: ordered, clusters: rawLabels)
    }

    /// Renumber arbitrary cluster ids to "Speaker N" in first-appearance order.
    static func relabelInFirstAppearanceOrder(turns: [SpeakerTurn], clusters: [Int]) -> [SpeakerTurn] {
        var nameByCluster: [Int: String] = [:]
        return zip(turns, clusters).map { turn, cluster in
            let label = nameByCluster[cluster] ?? {
                let next = "Speaker \(nameByCluster.count + 1)"
                nameByCluster[cluster] = next
                return next
            }()
            return SpeakerTurn(speakerLabel: label, start: turn.start, end: turn.end)
        }
    }

    // MARK: - Window filtering

    private static func isUsable(_ window: SpeakerEmbeddingWindow) -> Bool {
        window.duration >= minWindowDuration
            && !window.embedding.isEmpty
            && window.embedding.allSatisfy { $0.isFinite }
    }

    /// Uniform stride down to at most `cap` entries, always keeping the first
    /// and spreading the rest across the whole timeline.
    static func stridedSample(count: Int, cap: Int) -> [Int] {
        guard count > cap, cap > 0 else { return Array(0..<count) }
        var indices: [Int] = []
        indices.reserveCapacity(cap)
        for position in 0..<cap {
            indices.append(min(count - 1, position * count / cap))
        }
        return indices
    }

    // MARK: - Vector helpers

    /// L2-normalize to `Double` so cosine similarity is a plain dot product and
    /// the clustering math stays in one precision.
    static func normalized(_ embedding: [Float]) -> [Double] {
        let values = embedding.map(Double.init)
        var norm: Double = 0
        vDSP_svesqD(values, 1, &norm, vDSP_Length(values.count))
        guard norm > 0, norm.isFinite else { return values }
        var scale = 1.0 / norm.squareRoot()
        var output = [Double](repeating: 0, count: values.count)
        vDSP_vsmulD(values, 1, &scale, &output, 1, vDSP_Length(values.count))
        return output
    }

    /// Flattened `count × count` matrix of cosine distances (`1 - cosine`) for
    /// unit-normalized vectors.
    static func cosineDistanceMatrix(_ vectors: [[Double]]) -> [Double] {
        let count = vectors.count
        var matrix = [Double](repeating: 0, count: count * count)
        guard let dimension = vectors.first?.count else { return matrix }
        for i in 0..<count {
            for other in (i + 1)..<count {
                var dot: Double = 0
                vDSP_dotprD(vectors[i], 1, vectors[other], 1, &dot, vDSP_Length(dimension))
                let distance = max(0, 1 - dot)
                matrix[i * count + other] = distance
                matrix[other * count + i] = distance
            }
        }
        return matrix
    }

    /// Whether a candidate labelling describes plausibly *different people*:
    /// every cluster large enough to be a participant, and every pair of
    /// centroids at least `minSpeakerSeparation` apart.
    static func isPlausibleSplit(
        labels: [Int],
        clusterCount: Int,
        centroids: [[Double]]
    ) -> Bool {
        guard clusterCount > 1, centroids.count == clusterCount else { return false }
        var sizes = [Int](repeating: 0, count: clusterCount)
        for label in labels { sizes[label] += 1 }
        guard sizes.allSatisfy({ $0 >= minWindowsPerCluster }) else { return false }

        for i in 0..<clusterCount {
            for other in (i + 1)..<clusterCount {
                guard centroids[i].count == centroids[other].count, !centroids[i].isEmpty else { return false }
                var dot: Double = 0
                vDSP_dotprD(centroids[i], 1, centroids[other], 1, &dot, vDSP_Length(centroids[i].count))
                if 1 - dot < minSpeakerSeparation { return false }
            }
        }
        return true
    }

    private static func centroids(of vectors: [[Double]], labels: [Int]) -> [[Double]] {
        guard let dimension = vectors.first?.count else { return [] }
        let clusterCount = (labels.max() ?? -1) + 1
        guard clusterCount > 0 else { return [] }
        var sums = [[Double]](repeating: [Double](repeating: 0, count: dimension), count: clusterCount)
        var counts = [Int](repeating: 0, count: clusterCount)
        for (vector, label) in zip(vectors, labels) {
            for index in 0..<dimension { sums[label][index] += vector[index] }
            counts[label] += 1
        }
        return (0..<clusterCount).map { cluster -> [Double] in
            guard counts[cluster] > 0 else { return sums[cluster] }
            let mean = sums[cluster].map { $0 / Double(counts[cluster]) }
            var norm: Double = 0
            vDSP_svesqD(mean, 1, &norm, vDSP_Length(dimension))
            guard norm > 0 else { return mean }
            let scale = 1.0 / norm.squareRoot()
            return mean.map { $0 * scale }
        }
    }

    private static func nearestCentroid(to vector: [Double], centroids: [[Double]]) -> Int {
        var bestIndex = 0
        var bestSimilarity = -Double.greatestFiniteMagnitude
        for (index, centroid) in centroids.enumerated() where centroid.count == vector.count {
            var dot: Double = 0
            vDSP_dotprD(vector, 1, centroid, 1, &dot, vDSP_Length(vector.count))
            if dot > bestSimilarity {
                bestSimilarity = dot
                bestIndex = index
            }
        }
        return bestIndex
    }

    // MARK: - Agglomerative clustering

    /// Average-linkage agglomerative clustering over a precomputed distance
    /// matrix, returning the label assignment for every cluster count from
    /// `upTo` down to 1.
    ///
    /// Cluster-to-cluster distances are updated with the Lance-Williams formula
    /// for average linkage, so no point-level rescan is needed per merge. The
    /// naive "scan the active matrix for the minimum" search is O(k²) per merge
    /// — fine for the `clusteringSampleCap`-sized inputs this runs on, and far
    /// simpler than a nearest-neighbour chain.
    static func averageLinkageSnapshots(
        distances: [Double],
        count: Int,
        upTo maxClusters: Int
    ) -> [Int: [Int]] {
        guard count > 1 else { return count == 1 ? [1: [0]] : [:] }

        var matrix = distances
        var active = [Bool](repeating: true, count: count)
        var sizes = [Int](repeating: 1, count: count)
        var members: [[Int]] = (0..<count).map { [$0] }
        var activeCount = count
        var snapshots: [Int: [Int]] = [:]

        if activeCount <= maxClusters {
            snapshots[activeCount] = labels(from: members, active: active, count: count)
        }

        while activeCount > 1 {
            var bestA = -1
            var bestB = -1
            var bestDistance = Double.greatestFiniteMagnitude
            for i in 0..<count where active[i] {
                for other in (i + 1)..<count where active[other] {
                    let distance = matrix[i * count + other]
                    if distance < bestDistance {
                        bestDistance = distance
                        bestA = i
                        bestB = other
                    }
                }
            }
            guard bestA >= 0, bestB >= 0 else { break }

            let sizeA = sizes[bestA]
            let sizeB = sizes[bestB]
            let total = Double(sizeA + sizeB)
            for other in 0..<count where active[other] && other != bestA && other != bestB {
                let merged = (Double(sizeA) * matrix[bestA * count + other]
                    + Double(sizeB) * matrix[bestB * count + other]) / total
                matrix[bestA * count + other] = merged
                matrix[other * count + bestA] = merged
            }
            members[bestA].append(contentsOf: members[bestB])
            members[bestB] = []
            sizes[bestA] = sizeA + sizeB
            active[bestB] = false
            activeCount -= 1

            if activeCount <= maxClusters {
                snapshots[activeCount] = labels(from: members, active: active, count: count)
            }
        }

        return snapshots
    }

    private static func labels(from members: [[Int]], active: [Bool], count: Int) -> [Int] {
        var result = [Int](repeating: 0, count: count)
        var next = 0
        for cluster in 0..<members.count where active[cluster] {
            for point in members[cluster] { result[point] = next }
            next += 1
        }
        return result
    }

    // MARK: - Silhouette

    /// Mean silhouette coefficient of a labelling, in `[-1, 1]`. Points in
    /// singleton clusters contribute 0, per the standard definition.
    static func meanSilhouette(labels: [Int], clusterCount: Int, distances: [Double]) -> Double {
        let count = labels.count
        guard count > 1, clusterCount > 1 else { return 0 }

        var clusterSizes = [Int](repeating: 0, count: clusterCount)
        for label in labels { clusterSizes[label] += 1 }

        var total = 0.0
        for i in 0..<count {
            var sums = [Double](repeating: 0, count: clusterCount)
            for other in 0..<count where other != i {
                sums[labels[other]] += distances[i * count + other]
            }
            let own = labels[i]
            guard clusterSizes[own] > 1 else { continue }
            let cohesion = sums[own] / Double(clusterSizes[own] - 1)
            var separation = Double.greatestFiniteMagnitude
            for cluster in 0..<clusterCount where cluster != own && clusterSizes[cluster] > 0 {
                separation = Swift.min(separation, sums[cluster] / Double(clusterSizes[cluster]))
            }
            guard separation.isFinite else { continue }
            let denominator = Swift.max(cohesion, separation)
            if denominator > 0 { total += (separation - cohesion) / denominator }
        }
        return total / Double(count)
    }

    // MARK: - Small helpers

    private static func argmax(_ values: [TimeInterval]) -> Int? {
        values.enumerated().max { $0.element < $1.element }?.offset
    }

    private static func nearestWindowLabel(
        to turn: SpeakerTurn,
        windows: [SpeakerEmbeddingWindow],
        labels: [Int]
    ) -> Int {
        let midpoint = (turn.start + turn.end) / 2
        var bestLabel = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, window) in windows.enumerated() {
            let distance: TimeInterval
            if midpoint < window.start {
                distance = window.start - midpoint
            } else if midpoint > window.end {
                distance = midpoint - window.end
            } else {
                distance = 0
            }
            if distance < bestDistance {
                bestDistance = distance
                bestLabel = labels[index]
            }
        }
        return bestLabel
    }
}
