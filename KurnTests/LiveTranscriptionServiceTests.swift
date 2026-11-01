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

#if canImport(FluidAudio)
import FluidAudio
#endif

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
        #expect(service.queuedAudioDuration == 0)
        #expect(service.droppedAudioBufferCount == 0)
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
        #expect(service.queuedAudioDuration == 0)
        #expect(service.droppedAudioBufferCount == 0)
    }

    #if canImport(FluidAudio)
    @Test func idleConsentRejectionNeverInvokesTheLocalFactory() async {
        let service = LiveTranscriptionService(engineFactory: { _, _ in
            Issue.record("Consent rejection must not load a model")
            throw CancellationError()
        })
        await service.start(language: .english, modelsConsented: false)
        await service.stop()
        #expect(!service.isActive)
        #expect(!service.isLoading)
        #expect(service.queuedAudioDuration == 0)
        #expect(service.droppedAudioBufferCount == 0)
    }

    @Test func anAlreadyLoadedFactoryResultIsNeverReloadedAndRepeatedStartsAreIgnored() async {
        let session = LivePreviewSession()
        let calls = Recorded<MeetingLanguage>()
        let service = LiveTranscriptionService(engineFactory: { language, _ in
            calls.append(language)
            return session
        })
        await service.start(language: .english, modelsConsented: true)
        await service.start(language: .portuguese, modelsConsented: true)
        #expect(calls.values == [.english])
        #expect(service.isActive)
        #expect(!service.isLoading)
        #expect(service.queuedAudioDuration == 0)
        #expect(service.droppedAudioBufferCount == 0)
        await service.stop()
        #expect(await session.cleanupCalls == 1)
    }

    @Test func loadFailureLeavesAnEmptyIdleQueueAndCanBeRetried() async {
        let calls = Recorded<Int>()
        let session = LivePreviewSession()
        let service = LiveTranscriptionService(engineFactory: { _, _ in
            calls.append(1)
            if calls.values.count == 1 { throw CancellationError() }
            return session
        })
        await service.start(language: .english, modelsConsented: true)
        #expect(service.isUnavailable)
        #expect(!service.isActive)
        #expect(!service.isLoading)
        #expect(service.queuedAudioDuration == 0)
        await service.start(language: .english, modelsConsented: true)
        #expect(service.isActive)
        #expect(!service.isUnavailable)
        await service.stop()
    }

    @Test func aStoppedLoadsLateFailureCannotPoisonTheNewSession() async {
        let gate = LivePreviewBarrier()
        let currentGate = LivePreviewBarrier()
        let calls = Recorded<Int>()
        let current = LivePreviewSession()
        let service = LiveTranscriptionService(engineFactory: { _, _ in
            calls.append(1)
            if calls.values.count == 1 {
                try await gate.wait()
            } else {
                try await currentGate.wait()
            }
            return current
        })
        let oldStart = Task { await service.start(language: .english, modelsConsented: true) }
        await gate.waitUntilEntered()
        #expect(service.isLoading)
        await service.stop()
        let currentStart = Task { await service.start(language: .english, modelsConsented: true) }
        await currentGate.waitUntilEntered()
        await gate.release(failing: true)
        await oldStart.value
        #expect(service.isLoading)
        #expect(!service.isUnavailable)
        #expect(!service.isActive)
        await currentGate.release()
        await currentStart.value
        #expect(service.isActive)
        #expect(!service.isUnavailable)
        #expect(!service.isLoading)
        #expect(await current.cleanupCalls == 0)
        await service.stop()
    }

    @Test func aStoppedLoadsLateSuccessIsCleanedWithoutReplacingTheNewEngine() async {
        let gate = LivePreviewBarrier()
        let calls = Recorded<Int>()
        let old = LivePreviewSession()
        let current = LivePreviewSession()
        let service = LiveTranscriptionService(engineFactory: { _, _ in
            calls.append(1)
            if calls.values.count == 1 {
                try await gate.wait()
                return old
            }
            return current
        })
        let oldStart = Task { await service.start(language: .english, modelsConsented: true) }
        await gate.waitUntilEntered()
        await service.stop()
        await service.start(language: .english, modelsConsented: true)
        await gate.release()
        await oldStart.value
        #expect(await old.cleanupCalls == 1)
        #expect(await current.cleanupCalls == 0)
        #expect(service.isActive)
        #expect(!service.isLoading)
        await service.stop()
        #expect(await current.cleanupCalls == 1)
    }

    @Test func oldStopFailureAndCallbacksCannotClearTheRestartedSession() async {
        let gate = LivePreviewBarrier()
        let old = LivePreviewSession(finishGate: gate)
        let current = LivePreviewSession()
        let calls = Recorded<Int>()
        let service = LiveTranscriptionService(engineFactory: { _, _ in
            calls.append(1)
            return calls.values.count == 1 ? old : current
        })
        await service.start(language: .english, modelsConsented: true)
        let stopping = Task { await service.stop() }
        await gate.waitUntilEntered()
        #expect(!service.isActive)
        #expect(!service.isLoading)
        #expect(service.queuedAudioDuration == 0)
        await service.start(language: .english, modelsConsented: true)
        await current.emit("new partial")
        for _ in 0..<100 {
            if service.partialText == "new partial" { break }
            await Task.yield()
        }
        #expect(service.partialText == "new partial")
        await old.emit("old partial")
        for _ in 0..<20 { await Task.yield() }
        #expect(service.partialText == "new partial")
        await gate.release(failing: true)
        await stopping.value
        #expect(service.isActive)
        #expect(!service.isUnavailable)
        #expect(!service.isLoading)
        #expect(service.partialText == "new partial")
        #expect(await old.cleanupCalls == 1)
        #expect(await current.cleanupCalls == 0)
        await service.stop()
    }
    #endif
}

#if canImport(FluidAudio)
private actor LivePreviewBarrier {
    private var continuation: CheckedContinuation<Void, Error>?
    private var entered: [CheckedContinuation<Void, Never>] = []

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let observers = entered
            entered.removeAll()
            observers.forEach { $0.resume() }
        }
    }

    func waitUntilEntered() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { entered.append($0) }
    }

    func release(failing: Bool = false) {
        let continuation = self.continuation
        self.continuation = nil
        if failing {
            continuation?.resume(throwing: CancellationError())
        } else {
            continuation?.resume()
        }
    }
}

private actor LivePreviewSession: StreamingAsrManager {
    let displayName = "Idle lifecycle session"
    private let finishGate: LivePreviewBarrier?
    private var callback: (@Sendable (String) -> Void)?
    private(set) var cleanupCalls = 0

    init(finishGate: LivePreviewBarrier? = nil) { self.finishGate = finishGate }
    func loadModels() { Issue.record("A local factory result must not be loaded again") }
    func appendAudio(_ buffer: AVAudioPCMBuffer) { Issue.record("Idle lifecycle tests must not process audio") }
    func processBufferedAudio() { Issue.record("Idle lifecycle tests must not process audio") }
    func finish() async throws -> String { try await finishGate?.wait(); return "" }
    func reset() {}
    func cleanup() { cleanupCalls += 1 }
    func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) { self.callback = callback }
    func getPartialTranscript() -> String { "" }
    func emit(_ text: String) { callback?(text) }
}
#endif
