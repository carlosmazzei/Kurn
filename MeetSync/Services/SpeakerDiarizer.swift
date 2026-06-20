//
//  SpeakerDiarizer.swift
//  MeetSync
//
//  Heuristic, on-device speaker diarization. This is intentionally approximate —
//  the UI clearly labels speakers as auto-detected and lets users rename them.
//
//  Approach:
//   1. Read the audio in chunks and compute per-100ms-frame RMS energy + zero
//      crossing rate (a crude voice-timbre proxy).
//   2. Split into speech regions separated by silence gaps (< -40 dBFS for
//      >= 0.5s).
//   3. Assign each region to a speaker by cosine-similarity clustering of its
//      mean feature vector (threshold 0.85), creating a new speaker when no
//      existing centroid is close enough.
//

import AVFoundation
import Foundation

actor SpeakerDiarizer {

    private struct Frame {
        let time: TimeInterval
        let rms: Float
        let dbfs: Float
        let zcr: Float
    }

    private struct Region {
        let start: TimeInterval
        let end: TimeInterval
        let feature: [Float]   // [meanRMS, meanZCR]
    }

    private let frameDuration: TimeInterval = 0.1     // 100 ms frames
    private let silenceFloorDBFS: Float = -40         // below this is "silence"
    private let minSilenceFrames = 5                  // 0.5 s gap splits regions
    private let minRegionFrames = 2                   // ignore < 200 ms blips
    private let similarityThreshold: Float = 0.85
    private let maxSpeakers = 6

    /// Produce ordered speaker turns for the file. On any failure returns a
    /// single turn covering the whole clip so callers always get usable output.
    func diarize(url: URL) async -> [SpeakerTurn] {
        guard let frames = try? readFrames(url: url), !frames.isEmpty else {
            return [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 0)]
        }

        let regions = speechRegions(from: frames)
        guard !regions.isEmpty else {
            let end = frames.last.map { $0.time + frameDuration } ?? 0
            return [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: end)]
        }

        return assignSpeakers(to: regions)
    }

    // MARK: - Feature extraction

    private func readFrames(url: URL) throws -> [Frame] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return [] }

        let channelCount = Int(format.channelCount)
        let samplesPerFrame = max(1, Int(sampleRate * frameDuration))
        let chunkCapacity = AVAudioFrameCount(samplesPerFrame * 50) // ~5 s per read

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: chunkCapacity
        ) else { return [] }

        var frames: [Frame] = []
        var carry: [Float] = []
        var globalSampleIndex = 0

        while true {
            buffer.frameLength = 0
            try file.read(into: buffer)
            let read = Int(buffer.frameLength)
            if read == 0 { break }
            guard let channelData = buffer.floatChannelData else { break }

            var mono = [Float](repeating: 0, count: read)
            for ch in 0..<channelCount {
                let ptr = channelData[ch]
                for i in 0..<read { mono[i] += ptr[i] }
            }
            if channelCount > 1 {
                let inv = 1.0 / Float(channelCount)
                for i in 0..<read { mono[i] *= inv }
            }

            carry.append(contentsOf: mono)

            while carry.count >= samplesPerFrame {
                let slice = Array(carry[0..<samplesPerFrame])
                carry.removeFirst(samplesPerFrame)
                let time = Double(globalSampleIndex) / sampleRate
                frames.append(makeFrame(slice, time: time))
                globalSampleIndex += samplesPerFrame
            }
        }

        if carry.count > samplesPerFrame / 3 {
            let time = Double(globalSampleIndex) / sampleRate
            frames.append(makeFrame(carry, time: time))
        }

        return frames
    }

    private func makeFrame(_ samples: [Float], time: TimeInterval) -> Frame {
        var sumSquares: Float = 0
        var crossings = 0
        var previous: Float = 0
        for (i, s) in samples.enumerated() {
            sumSquares += s * s
            if i > 0, (s >= 0) != (previous >= 0) { crossings += 1 }
            previous = s
        }
        let rms = sqrt(sumSquares / Float(max(1, samples.count)))
        let dbfs = rms > 0 ? 20 * log10(rms) : -160
        let zcr = Float(crossings) / Float(max(1, samples.count))
        return Frame(time: time, rms: rms, dbfs: dbfs, zcr: zcr)
    }

    // MARK: - Segmentation

    private func speechRegions(from frames: [Frame]) -> [Region] {
        var ranges: [(start: Int, end: Int)] = []
        var inSpeech = false
        var regionStart = 0
        var silentRun = 0

        for (i, frame) in frames.enumerated() {
            let isSpeech = frame.dbfs > silenceFloorDBFS
            if isSpeech {
                if !inSpeech {
                    inSpeech = true
                    regionStart = i
                }
                silentRun = 0
            } else if inSpeech {
                silentRun += 1
                if silentRun >= minSilenceFrames {
                    ranges.append((regionStart, i - silentRun))
                    inSpeech = false
                    silentRun = 0
                }
            }
        }
        if inSpeech {
            ranges.append((regionStart, frames.count - 1))
        }

        return ranges
            .filter { $0.end - $0.start + 1 >= minRegionFrames }
            .map { range in
                let slice = frames[range.start...range.end]
                let count = Float(slice.count)
                let meanRMS = slice.reduce(Float(0)) { $0 + $1.rms } / count
                let meanZCR = slice.reduce(Float(0)) { $0 + $1.zcr } / count
                return Region(
                    start: frames[range.start].time,
                    end: frames[range.end].time + frameDuration,
                    feature: [meanRMS, meanZCR]
                )
            }
    }

    // MARK: - Clustering

    private func assignSpeakers(to regions: [Region]) -> [SpeakerTurn] {
        var centroids: [[Float]] = []
        var counts: [Int] = []
        var turns: [SpeakerTurn] = []

        for region in regions {
            let normalized = normalize(region.feature)
            var bestIndex = -1
            var bestSimilarity: Float = -1

            for (i, centroid) in centroids.enumerated() {
                let sim = cosineSimilarity(normalized, normalize(centroid))
                if sim > bestSimilarity {
                    bestSimilarity = sim
                    bestIndex = i
                }
            }

            let speakerIndex: Int
            if bestIndex >= 0,
               bestSimilarity >= similarityThreshold {
                speakerIndex = bestIndex
                // Running average update of the centroid.
                let n = Float(counts[speakerIndex])
                centroids[speakerIndex] = zip(centroids[speakerIndex], region.feature)
                    .map { ($0 * n + $1) / (n + 1) }
                counts[speakerIndex] += 1
            } else if centroids.count < maxSpeakers {
                centroids.append(region.feature)
                counts.append(1)
                speakerIndex = centroids.count - 1
            } else {
                // At capacity: fall back to the nearest centroid.
                speakerIndex = max(0, bestIndex)
                counts[speakerIndex] += 1
            }

            turns.append(
                SpeakerTurn(
                    speakerLabel: "Speaker \(speakerIndex + 1)",
                    start: region.start,
                    end: region.end
                )
            )
        }

        return mergeAdjacent(turns)
    }

    /// Collapse consecutive turns with the same speaker into one span.
    private func mergeAdjacent(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        guard var current = turns.first else { return [] }
        var merged: [SpeakerTurn] = []
        for turn in turns.dropFirst() {
            if turn.speakerLabel == current.speakerLabel {
                current = SpeakerTurn(
                    speakerLabel: current.speakerLabel,
                    start: current.start,
                    end: turn.end
                )
            } else {
                merged.append(current)
                current = turn
            }
        }
        merged.append(current)
        return merged
    }

    private func normalize(_ v: [Float]) -> [Float] {
        let magnitude = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        guard magnitude > 0 else { return v }
        return v.map { $0 / magnitude }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        return dot // both inputs already normalized
    }
}
