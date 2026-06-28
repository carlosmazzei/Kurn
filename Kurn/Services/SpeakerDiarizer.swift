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

    // Segmentation tunables come from `EnergyVAD` so the app has one VAD
    // algorithm and one set of thresholds (the diarizer just feeds it richer
    // per-frame features afterwards).
    private let frameDuration = EnergyVAD.frameDuration       // 100 ms frames
    private let silenceFloorDBFS = EnergyVAD.silenceFloorDBFS // below this is "silence"
    private let minSilenceFrames = EnergyVAD.minSilenceFrames // 0.5 s gap splits regions
    private let minRegionFrames = EnergyVAD.minRegionFrames   // ignore < 200 ms blips
    /// Weighted-Euclidean distance below which a region joins an existing
    /// centroid. Tuned empirically: same-speaker regions cluster well under
    /// 0.15, different-pitched speakers land around 0.30+. Lowered to 0.16
    /// (just above the same-speaker band) for more sensitivity on far-field
    /// audio, where different voices' timbre features partly converge and a
    /// looser threshold under-splits — this is the engine that auto-detects
    /// without a forced speaker count (FluidAudio's VBx collapses to 1 here).
    private let distanceThreshold: Float = 0.16
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

    /// Produce ordered speaker turns for the file, segmenting speech with the
    /// built-in energy VAD. On any failure returns a single turn covering the
    /// whole clip so callers always get usable output.
    func diarize(url: URL) async -> [SpeakerTurn] {
        guard let frames = loadFrames(url: url), !frames.isEmpty else {
            return [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 0)]
        }
        return finalize(regions: speechRegions(from: frames), frames: frames)
    }

    /// Same as `diarize(url:)` but uses speech regions produced by an external
    /// VAD engine (e.g. FluidAudio Silero) instead of the built-in energy VAD,
    /// then layers this engine's timbre features over those regions.
    func diarize(url: URL, speechRegions externalRegions: [SpeechRegion]) async -> [SpeakerTurn] {
        guard let frames = loadFrames(url: url), !frames.isEmpty else {
            return [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 0)]
        }
        // This engine assigns one speaker per region and clusters *across*
        // regions — it never splits within a region — so it can only find as many
        // speakers as the segmentation hands it. An upstream VAD that fails and
        // returns a single whole-clip region (see `FluidAudioVAD`'s fallback)
        // would therefore cap the result at one speaker. When the external VAD is
        // that degenerate, fall back to the built-in energy VAD's silence-gap
        // segmentation so diarization stays useful regardless of the VAD engine.
        let regions: [Region]
        if externalRegions.count <= 1 {
            regions = speechRegions(from: frames)
            AppLog.transcription.atInfo.info("SpeakerDiarizer: external VAD gave \(externalRegions.count, privacy: .public) region(s); self-segmented into \(regions.count, privacy: .public)")
        } else {
            regions = featureRegions(from: frames, speechRegions: externalRegions)
        }
        return finalize(regions: regions, frames: frames)
    }

    /// Cluster the feature regions into speaker turns, falling back to a single
    /// whole-clip turn when there are none.
    private func finalize(regions: [Region], frames: [Frame]) -> [SpeakerTurn] {
        guard !regions.isEmpty else {
            let end = frames.last.map { $0.time + frameDuration } ?? 0
            AppLog.transcription.atInfo.info("SpeakerDiarizer: no speech regions — single whole-clip turn")
            return [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: end)]
        }

        let turns = assignSpeakers(to: regions)
        let uniqueSpeakers = Set(turns.map { $0.speakerLabel }).count
        AppLog.transcription.atInfo.info("SpeakerDiarizer: regions=\(regions.count, privacy: .public) turns=\(turns.count, privacy: .public) speakers=\(uniqueSpeakers, privacy: .public)")
        return turns
    }

    // MARK: - Feature extraction

    /// Read frames, logging the concrete decode error instead of swallowing it
    /// (a bare `try?` previously hid an AAC decode failure that collapsed
    /// diarization to one speaker). Returns nil on failure so callers fall back.
    private func loadFrames(url: URL) -> [Frame]? {
        do {
            return try readFrames(url: url)
        } catch {
            AppLog.transcription.atError.error("SpeakerDiarizer: readFrames failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public) — single-speaker fallback")
            return nil
        }
    }

    /// Sample rate the audio is decoded to for analysis. 16 kHz is ample for
    /// speech F0 (≤ 400 Hz) and the timbre proxies, and decoding to a fixed rate
    /// keeps pitch/feature behaviour identical regardless of the source format.
    private let analysisSampleRate: Double = 16_000

    private func readFrames(url: URL) throws -> [Frame] {
        // Decode through `VADAudioLoader.monoSamples` (offline AVAudioEngine
        // render) instead of reading raw PCM buffers directly: both
        // `AVAudioFile.read(into:)` and `AVAudioConverter` fail on device for the
        // app's compressed AAC `.m4a` files (recordings and cleaned copy alike)
        // with a generic `erro 0`, which silently collapsed diarization to a
        // single speaker. See `VADAudioLoader.monoSamples`.
        let samples = try VADAudioLoader.monoSamples(url: url, sampleRate: analysisSampleRate)
        guard !samples.isEmpty else { return [] }

        let sampleRate = analysisSampleRate
        let samplesPerFrame = max(1, Int(sampleRate * frameDuration))
        var frames: [Frame] = []
        frames.reserveCapacity(samples.count / samplesPerFrame + 1)

        var index = 0
        while index + samplesPerFrame <= samples.count {
            let slice = Array(samples[index..<index + samplesPerFrame])
            let time = Double(index) / sampleRate
            frames.append(makeFrame(slice, time: time, sampleRate: sampleRate))
            index += samplesPerFrame
        }
        // Keep a trailing partial frame only if it carries enough samples to be
        // meaningful (matches the previous reader's >1/3-frame threshold).
        if samples.count - index > samplesPerFrame / 3 {
            let slice = Array(samples[index..<samples.count])
            let time = Double(index) / sampleRate
            frames.append(makeFrame(slice, time: time, sampleRate: sampleRate))
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
        // Reuse the shared VAD state machine for silence-gap segmentation, then
        // layer this engine's timbre features over each detected range.
        let ranges = EnergyVAD.speechFrameRanges(
            dbfs: frames.map { $0.dbfs },
            silenceFloor: silenceFloorDBFS,
            minSilenceFrames: minSilenceFrames,
            minRegionFrames: minRegionFrames
        )
        return ranges.map { featureRegion(from: frames, startFrame: $0.start, endFrame: $0.end) }
    }

    /// Build feature regions from speech intervals (seconds) produced by an
    /// external VAD, mapping each interval to the corresponding 100 ms frames.
    private func featureRegions(from frames: [Frame], speechRegions: [SpeechRegion]) -> [Region] {
        speechRegions.compactMap { region in
            let startFrame = max(0, Int(region.start / frameDuration))
            let endFrame = min(frames.count - 1, Int(region.end / frameDuration))
            guard endFrame >= startFrame else { return nil }
            return featureRegion(from: frames, startFrame: startFrame, endFrame: endFrame)
        }
    }

    /// Mean timbre feature vector over a `[startFrame, endFrame]` frame range.
    private func featureRegion(from frames: [Frame], startFrame: Int, endFrame: Int) -> Region {
        let slice = frames[startFrame...endFrame]
        let count = Float(slice.count)
        let meanZCR = slice.reduce(Float(0)) { $0 + $1.zcr } / count
        let meanHighBand = slice.reduce(Float(0)) { $0 + $1.highBand } / count

        let voicedPitches = slice.compactMap { $0.pitch > 0 ? $0.pitch : nil }
        let meanPitch = voicedPitches.isEmpty
            ? 0
            : voicedPitches.reduce(0, +) / Float(voicedPitches.count)
        let normalizedPitch = min(1.5, meanPitch / pitchNormalizer)

        return Region(
            start: frames[startFrame].time,
            end: frames[endFrame].time + frameDuration,
            feature: [normalizedPitch, meanZCR, meanHighBand]
        )
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
