//
//  LiveTranscriptionServiceTests.swift
//  KurnTests
//
//  The consent gate and the idle-state behaviour of the live preview. Nothing
//  here loads a streaming model — the tests stop at the point where a download
//  would start, which is exactly the boundary the recorder UI depends on.
//

import AVFoundation
import Foundation
import KurnCore
import Testing
@testable import Kurn

@MainActor
struct LiveTranscriptionServiceTests {

    private func makeBuffer(frames: AVAudioFrameCount = 1_600) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        return buffer
    }

    @Test func startWithoutModelConsentIsUnavailableAndNeverActive() async {
        let service = LiveTranscriptionService()

        await service.start(language: .english, modelsConsented: false)

        #expect(service.isUnavailable)
        #expect(!service.isActive)
        #expect(!service.isLoading)
        #expect(service.partialText.isEmpty)
    }

    @Test(arguments: [MeetingLanguage.english, .portuguese, .autoDetect])
    func consentGateDoesNotDependOnLanguage(language: MeetingLanguage) async {
        let service = LiveTranscriptionService()
        await service.start(
            language: language,
            modelsConsented: false,
            policy: LargeTransferPolicy(allowsExpensiveAccess: true, allowsConstrainedAccess: true)
        )
        #expect(service.isUnavailable)
        #expect(!service.isActive)
    }

    @Test func appendBeforeStartIsDroppedWithoutSideEffects() async throws {
        let service = LiveTranscriptionService()
        let buffer = try makeBuffer()

        service.append(buffer)
        service.append(buffer)
        await Task.yield()

        #expect(!service.isActive)
        #expect(service.partialText.isEmpty)
    }

    @Test func stopWithoutEngineResetsToIdle() async {
        let service = LiveTranscriptionService()
        await service.start(language: .english, modelsConsented: false)
        #expect(service.isUnavailable)

        await service.stop()

        #expect(!service.isActive)
        #expect(!service.isLoading)
        #expect(service.partialText.isEmpty)
    }

    @Test func stopIsIdempotent() async {
        let service = LiveTranscriptionService()
        await service.stop()
        await service.stop()
        #expect(!service.isActive)
    }
}
