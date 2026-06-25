//
//  EnergyVAD.swift
//  Kurn
//
//  Energy-threshold voice-activity detection: split a clip into speech regions
//  separated by silence gaps, using per-100ms-frame dBFS. This is the single
//  source of truth for the gap-detection state machine — `SpeakerDiarizer`
//  reuses `speechFrameRanges(...)` over its own (richer) frames so the app has
//  exactly one VAD algorithm.
//

import AVFoundation
import Foundation

actor EnergyVAD: VoiceActivityDetecting {

    /// Tunables shared with the heuristic diarizer's segmentation.
    static let frameDuration: TimeInterval = 0.1   // 100 ms frames
    static let silenceFloorDBFS: Float = -40       // below this is "silence"
    static let minSilenceFrames = 5                // 0.5 s gap splits regions
    static let minRegionFrames = 2                 // ignore < 200 ms blips

    /// Locate speech regions in `url`. On any read failure returns a single
    /// region covering the whole clip so callers always get usable output.
    func detectSpeech(url: URL) async -> [SpeechRegion] {
        guard let dbfs = try? Self.frameDBFS(url: url), !dbfs.isEmpty else {
            let duration = (try? AVURLAsset(url: url).load(.duration)).map(CMTimeGetSeconds) ?? 0
            return [SpeechRegion(start: 0, end: max(0, duration))]
        }
        let ranges = Self.speechFrameRanges(dbfs: dbfs)
        guard !ranges.isEmpty else {
            return [SpeechRegion(start: 0, end: Double(dbfs.count) * Self.frameDuration)]
        }
        return ranges.map { range in
            SpeechRegion(
                start: Double(range.start) * Self.frameDuration,
                end: Double(range.end + 1) * Self.frameDuration
            )
        }
    }

    /// The gap-detection state machine: turn a per-frame dBFS series into speech
    /// frame-index ranges `[start, end]` (inclusive), dropping sub-`minRegionFrames`
    /// blips. Pure and `static` so both this VAD and `SpeakerDiarizer` share it.
    static func speechFrameRanges(
        dbfs: [Float],
        silenceFloor: Float = EnergyVAD.silenceFloorDBFS,
        minSilenceFrames: Int = EnergyVAD.minSilenceFrames,
        minRegionFrames: Int = EnergyVAD.minRegionFrames
    ) -> [(start: Int, end: Int)] {
        var ranges: [(start: Int, end: Int)] = []
        var inSpeech = false
        var regionStart = 0
        var silentRun = 0

        for (i, value) in dbfs.enumerated() {
            let isSpeech = value > silenceFloor
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
            ranges.append((regionStart, dbfs.count - 1))
        }
        return ranges.filter { $0.end - $0.start + 1 >= minRegionFrames }
    }

    /// Read `url` and compute per-frame dBFS over 100 ms mono frames.
    private static func frameDBFS(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return [] }

        let channelCount = Int(format.channelCount)
        let samplesPerFrame = max(1, Int(sampleRate * frameDuration))
        let chunkCapacity = AVAudioFrameCount(samplesPerFrame * 50) // ~5 s per read

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else {
            return []
        }

        var result: [Float] = []
        var carry: [Float] = []

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

            var consumed = 0
            while carry.count - consumed >= samplesPerFrame {
                let slice = carry[consumed..<consumed + samplesPerFrame]
                consumed += samplesPerFrame
                result.append(Self.dbfs(of: slice))
            }
            if consumed > 0 { carry.removeFirst(consumed) }
        }
        if carry.count > samplesPerFrame / 3 {
            result.append(Self.dbfs(of: carry[...]))
        }
        return result
    }

    private static func dbfs(of samples: ArraySlice<Float>) -> Float {
        var sumSquares: Float = 0
        for s in samples { sumSquares += s * s }
        let rms = sqrt(sumSquares / Float(max(1, samples.count)))
        return rms > 0 ? 20 * log10(rms) : -160
    }
}
