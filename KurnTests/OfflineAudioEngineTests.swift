import AVFoundation
import Foundation
import KurnCore
import Testing
@testable import Kurn

struct OfflineAudioEngineTests {
    @Test(arguments: [16_000.0, 24_000.0, 48_000.0], [AVAudioFrameCount(1024), 4096])
    func factoryEnablesManualModeBeforeClientNodesAreAttached(sampleRate: Double, maxFrames: AVAudioFrameCount) throws {
        let format = try #require(OfflineAudioRenderer.monoFormat(sampleRate: sampleRate))
        let engine = try OfflineAudioEngine.make(outputFormat: format, maxFrames: maxFrames)
        defer { engine.stop() }

        #expect(engine.isInManualRenderingMode)
        #expect(engine.manualRenderingMode == .offline)
        #expect(!engine.isRunning)
        #expect(engine.manualRenderingFormat == format)
        #expect(engine.manualRenderingMaximumFrameCount == maxFrames)
        #expect(!engine.attachedNodes.contains { $0 is AVAudioPlayerNode })

        let player = AVAudioPlayerNode()
        engine.attach(player)
        #expect(engine.outputConnectionPoints(for: player, outputBus: 0).isEmpty)
        #expect(engine.isInManualRenderingMode)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        #expect(engine.isInManualRenderingMode)
    }

    @Test func rendererBuildsItsChainInManualModeAndMatchesTheSynchronousLoader() async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: [(440, 0.125)])
            defer { try? FileManager.default.removeItem(at: url) }
            let expected = try VADAudioLoader.monoSamples(url: url, sampleRate: 16_000)
            let format = try #require(OfflineAudioRenderer.monoFormat(sampleRate: 16_000))
            var builtChain = false
            let renderer = OfflineAudioRenderer(
                outputFormat: format,
                maxFrames: 1024,
                buildChain: { engine, player, inputFormat in
                    #expect(engine.isInManualRenderingMode)
                    #expect(!engine.isRunning)
                    #expect(engine.outputConnectionPoints(for: player, outputBus: 0).isEmpty)
                    #expect(engine.manualRenderingFormat == format)
                    #expect(engine.manualRenderingMaximumFrameCount == 1024)
                    builtChain = true
                    engine.connect(player, to: engine.mainMixerNode, format: inputFormat)
                },
                failure: .audioError("fixture"),
                logLabel: "offline-test"
            )
            var actual: [Float] = []
            let frames = try await renderer.render(url: url) { buffer in
                let channels = try #require(buffer.floatChannelData)
                actual.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
            }

            #expect(builtChain)
            #expect(frames == 2000)
            #expect(actual == expected)
        }
    }
}
