//
//  OfflineAudioRendererTests.swift
//  KurnTests
//
//  Offline renders must never involve the audio server. The preprocessors,
//  the enhancement renderer and the compactors all render in parallel under
//  Swift Testing, and an engine that creates a device `AURemoteIO` unit per
//  render aborted the whole test host with "AURemoteIO: RPC timeout.
//  Apparently deadlocked" once enough of them overlapped. The render paths
//  themselves are covered by the preprocessor, enhancement and compactor
//  suites.
//

import AVFoundation
import KurnCore
import Testing
@testable import Kurn

struct OfflineAudioRendererTests {

    /// Many renders at once, as the suites produce on a busy runner. Each one
    /// must complete with the whole clip rendered.
    @Test func manyParallelRendersAllComplete() async throws {
        let url = try AudioFixtures.wav(segments: [(440, 1.0)])
        defer { try? FileManager.default.removeItem(at: url) }
        let renders = 32

        let frames = try await withThrowingTaskGroup(of: AVAudioFramePosition.self) { group in
            for _ in 0..<renders {
                group.addTask {
                    guard let format = OfflineAudioRenderer.monoFormat(sampleRate: 16_000) else {
                        throw AppError.audioError("no mono format")
                    }
                    let renderer = OfflineAudioRenderer(
                        outputFormat: format,
                        failure: .audioError("offline render failed"),
                        logLabel: "test.parallel"
                    )
                    return try await renderer.render(url: url) { _ in }
                }
            }
            return try await group.reduce(into: [AVAudioFramePosition]()) { $0.append($1) }
        }

        let everyRenderCoversTheClip = frames.allSatisfy { $0 >= 15_000 }
        #expect(frames.count == renders)
        #expect(everyRenderCoversTheClip, "every render covers the 1 s clip: \(frames)")
    }
}
