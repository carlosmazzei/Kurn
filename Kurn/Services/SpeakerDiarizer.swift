//
//  SpeakerDiarizer.swift
//  Kurn
//
//  Heuristic, on-device speaker diarization. This is intentionally approximate —
//  the UI clearly labels speakers as auto-detected and lets users rename them.
//
//  Approach:
//   1. Read the audio in chunks and compute per-100ms-frame RMS energy (for
//      voice-activity detection) plus pitch (F0), zero-crossing rate, and
//      spectral tilt (crude voice-timbre proxies).
//   2. Split into speech regions separated by silence gaps (< -40 dBFS for
//      >= 0.5s).
//   3. Assign each region to a speaker by weighted-Euclidean clustering of
//      its mean timbre feature vector, creating a new speaker when no
//      existing centroid is close enough. Cosine similarity isn't usable
//      here: the feature dimensions are all non-negative and pitch dominates
//      the magnitude, so two very different voices end up with cosine ~0.99
//      and collapse into a single speaker. RMS/volume is deliberately
//      excluded from this vector — it reflects mic distance and speaking
//      loudness, not who is speaking.
//

import AVFoundation
import Foundation

actor SpeakerDiarizer: Diarizing {

    private struct Frame {
        let time: TimeInterval
        let rms: Float
        let dbfs: Float
        let zcr: Float
        let pitch: Float       // Hz, 0 when unvoiced/no clear periodicity
        let highBand: Float    // 0...1, energy fraction above the first-difference cutoff
    }

    private struct Region {
        let start: TimeInterval
        let end: TimeInterval
        let feature: [Float]   // [normalizedPitch, meanZCR, meanHighBand]
    }

    private let frameDuration: TimeInterval = 0.1     // 100 ms frames
    private let silenceFloorDBFS: Float = -40         // below this is "silence"
    private let minSilenceFrames = 5                  // 0.5 s gap splits regions
    private let minRegionFrames = 2                   // ignore < 200 ms blips
    /// Weighted-Euclidean distance below which a region joins an existing
    /// centroid. Tuned empirically: same-speaker regions cluster well under
    /// 0.15, different-pitched speakers land around 0.30+.
    private let distanceThreshold: Float = 0.22
    /// Per-dimension weights for the distance metric. Pitch is the strongest
    /// discriminator and gets the most weight; ZCR varies on a small absolute
    /// scale (~0.02–0.15) so it's amplified; high-band sits in between.
    private let featureWeights: [Float] = [1.0, 3.0, 1.5]
    private let maxSpeakers = 8

    // Pitch estimation (autocorrelation) is run on a decimated copy of each
    // frame so its cost stays linear in audio duration instead of exploding
    // with native sample rate.
    private let pitchAnalysisRate: Double = 4000
    private let minPitchHz: Float = 80
    private let maxPitchHz: Float = 400
    private let voicingThreshold: Float = 0.3
    private let pitchNormalizer: Float = 300          // brings Hz into ~[0,1.3] to match other dims

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

        let turns = assignSpeakers(to: regions)
        let uniqueSpeakers = Set(turns.map { $0.speakerLabel }).count
        AppLog.transcription.log("SpeakerDiarizer: regions=\(regions.count, privacy: .public) turns=\(turns.count, privacy: .public) speakers=\(uniqueSpeakers, privacy: .public)")
        return turns
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

            // Walk the buffer with a read index and trim once per chunk, instead
            // of calling removeFirst() per frame (which shifts the whole buffer
            // every time, making this quadratic in the carry length).
            var consumed = 0
            while carry.count - consumed >= samplesPerFrame {
                let slice = Array(carry[consumed..<consumed + samplesPerFrame])
                consumed += samplesPerFrame
                let time = Double(globalSampleIndex) / sampleRate
                frames.append(makeFrame(slice, time: time, sampleRate: sampleRate))
                globalSampleIndex += samplesPerFrame
            }
            if consumed > 0 { carry.removeFirst(consumed) }
        }

        if carry.count > samplesPerFrame / 3 {
            let time = Double(globalSampleIndex) / sampleRate
            frames.append(makeFrame(carry, time: time, sampleRate: sampleRate))
        }

        return frames
    }

    private func makeFrame(_ samples: [Float], time: TimeInterval, sampleRate: Double) -> Frame {
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
        let pitch = estimatePitch(samples, nativeSampleRate: sampleRate)
        let highBand = highBandRatio(samples)
        return Frame(time: time, rms: rms, dbfs: dbfs, zcr: zcr, pitch: pitch, highBand: highBand)
    }

    /// Crude F0 estimate via normalized autocorrelation on a decimated copy of
    /// the frame. Decimation keeps the lag search small (and thus the cost
    /// roughly linear in audio duration) since human F0 is well under the
    /// decimated Nyquist rate. Returns 0 when no clear periodicity is found
    /// (silence, noise, or unvoiced speech).
    private func estimatePitch(_ samples: [Float], nativeSampleRate: Double) -> Float {
        let stride = max(1, Int(nativeSampleRate / pitchAnalysisRate))
        var decimated: [Float] = []
        decimated.reserveCapacity(samples.count / stride + 1)
        var i = 0
        while i < samples.count {
            decimated.append(samples[i])
            i += stride
        }

        let rate = nativeSampleRate / Double(stride)
        let minLag = Int(rate / Double(maxPitchHz))
        let maxLag = Int(rate / Double(minPitchHz))
        guard minLag > 0, maxLag > minLag, decimated.count > maxLag + 1 else { return 0 }

        var energy: Float = 0
        for s in decimated { energy += s * s }
        guard energy > 1e-6 else { return 0 }

        var bestLag = -1
        var bestCorrelation: Float = 0
        for lag in minLag...maxLag {
            var correlation: Float = 0
            for idx in 0..<(decimated.count - lag) {
                correlation += decimated[idx] * decimated[idx + lag]
            }
            let normalized = correlation / energy
            if normalized > bestCorrelation {
                bestCorrelation = normalized
                bestLag = lag
            }
        }

        guard bestLag > 0, bestCorrelation > voicingThreshold else { return 0 }
        return Float(rate / Double(bestLag))
    }

    /// Fraction of frame energy above a first-difference high-pass filter — a
    /// cheap proxy for spectral tilt/brightness, which differs between voices
    /// independently of pitch.
    private func highBandRatio(_ samples: [Float]) -> Float {
        guard samples.count > 1 else { return 0 }
        var totalEnergy: Float = 0
        var highEnergy: Float = 0
        var previous = samples[0]
        totalEnergy += previous * previous
        for i in 1..<samples.count {
            let s = samples[i]
            totalEnergy += s * s
            let diff = s - previous
            highEnergy += diff * diff
            previous = s
        }
        guard totalEnergy > 0 else { return 0 }
        return min(1, highEnergy / totalEnergy)
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
                let meanZCR = slice.reduce(Float(0)) { $0 + $1.zcr } / count
                let meanHighBand = slice.reduce(Float(0)) { $0 + $1.highBand } / count

                let voicedPitches = slice.compactMap { $0.pitch > 0 ? $0.pitch : nil }
                let meanPitch = voicedPitches.isEmpty
                    ? 0
                    : voicedPitches.reduce(0, +) / Float(voicedPitches.count)
                let normalizedPitch = min(1.5, meanPitch / pitchNormalizer)

                return Region(
                    start: frames[range.start].time,
                    end: frames[range.end].time + frameDuration,
                    feature: [normalizedPitch, meanZCR, meanHighBand]
                )
            }
    }

    // MARK: - Clustering

    private func assignSpeakers(to regions: [Region]) -> [SpeakerTurn] {
        var centroids: [[Float]] = []
        var counts: [Int] = []
        var turns: [SpeakerTurn] = []

        for region in regions {
            var bestIndex = -1
            var bestDistance: Float = .greatestFiniteMagnitude

            for (i, centroid) in centroids.enumerated() {
                let dist = weightedDistance(region.feature, centroid)
                if dist < bestDistance {
                    bestDistance = dist
                    bestIndex = i
                }
            }

            let speakerIndex: Int
            if bestIndex >= 0, bestDistance <= distanceThreshold {
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

    /// Weighted Euclidean distance: emphasises pitch (the strongest natural
    /// discriminator between voices) and amplifies the small-scale ZCR
    /// dimension so it isn't drowned out by larger features.
    private func weightedDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, a.count <= featureWeights.count else { return .greatestFiniteMagnitude }
        var sumSquares: Float = 0
        for i in 0..<a.count {
            let delta = (a[i] - b[i]) * featureWeights[i]
            sumSquares += delta * delta
        }
        return sqrt(sumSquares)
    }
}
