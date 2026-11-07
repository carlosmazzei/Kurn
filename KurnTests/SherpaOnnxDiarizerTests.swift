//
//  SherpaOnnxDiarizerTests.swift
//  KurnTests
//
//  The Kurn app target sets `SHERPA_ONNX_ENABLED` in Debug and Release.
//  Hosted KurnTests import that compiled implementation through
//  `@testable import Kurn`, so these tests exercise the real sherpa-onnx 2.x
//  path, not the `#else` stub. Without downloaded models, it takes the
//  documented single-speaker fallback: never throw, never return nothing,
//  and cover the whole clip with one turn.
//

import Foundation
import KurnCore
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
