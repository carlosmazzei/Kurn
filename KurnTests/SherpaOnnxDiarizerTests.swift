//
//  SherpaOnnxDiarizerTests.swift
//  KurnTests
//
//  `SherpaOnnxDiarizer`'s real, ONNX-backed implementation is guarded by
//  `SHERPA_ONNX_ENABLED`, which nothing in the Xcode project sets yet (see
//  the file's own header comment) — so in every CI configuration today this
//  exercises the `#else` stub, exactly like `KurnTests` never linking
//  FluidAudio or whisper.cpp would exercise theirs. What that stub has to
//  guarantee is the same contract every `Diarizing` conformer promises: never
//  throw, never return nothing, fall back to a single whole-clip turn.
//

import Foundation
import Testing
@testable import Kurn

struct SherpaOnnxDiarizerTests {

    @Test func unreadableFileFallsBackToSingleSpeaker() async {
        let url = URL(fileURLWithPath: "/does/not/exist/\(UUID().uuidString).wav")
        let turns = await SherpaOnnxDiarizer().diarize(url: url)
        #expect(turns.count == 1)
        #expect(turns.first?.speakerLabel == "Speaker 1")
    }

    @Test func fallbackTurnCoversTheWholeClip() async throws {
        let url = try AudioFixtures.wav(segments: [(0, 2.0)])
        defer { try? FileManager.default.removeItem(at: url) }

        let turns = await SherpaOnnxDiarizer().diarize(url: url)
        #expect(turns.count == 1)
        #expect(turns.first?.start == 0)
        #expect(turns.first?.end ?? 0 > 0)
    }

    // MARK: - processTimeout

    /// Deliberately more generous than `FluidAudioDiarizer`'s budget: that one
    /// assumes ANE acceleration, which this CPU-only ONNX Runtime engine has
    /// no equivalent guarantee for.
    @Test func processTimeoutHasAFloorAndACeiling() {
        #expect(SherpaOnnxDiarizer.processTimeout(forAudioDuration: 0) == 300)
        #expect(SherpaOnnxDiarizer.processTimeout(forAudioDuration: 10_000) == 3600)
    }

    @Test func processTimeoutScalesWithDuration() {
        let timeout = SherpaOnnxDiarizer.processTimeout(forAudioDuration: 600)
        #expect(timeout == 900) // 600 * 1.5, within the floor/ceiling
    }
}
