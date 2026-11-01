import Foundation
import KurnCore
import Testing
@testable import Kurn

#if canImport(FluidAudio)
import AVFoundation
import FluidAudio

struct FluidAudioUnifiedStreamingManagerTests {
    @Test func unsupportedLanguageIsRejectedBeforeInstallationOrLoading() async {
        let manager = FluidAudioUnifiedStreamingManager(
            language: .japanese,
            isInstalled: { Issue.record("Installation must not be probed"); return true },
            load: { _ in
                Issue.record("The loader must not run")
                throw CancellationError()
            }
        )
        await #expect {
            try await manager.loadModels()
        } throws: { error in
            if case .transcriptionLanguageUnsupported = error as? AppError { return true }
            return false
        }
    }

    @Test func missingStreamingEncoderNeverInvokesTheLoader() async {
        let manager = FluidAudioUnifiedStreamingManager(language: .english, isInstalled: { false }, load: { _ in
            Issue.record("Loading a missing model could trigger a hidden download")
            throw CancellationError()
        })
        await #expect {
            try await manager.loadModels()
        } throws: { error in
            if case .modelDownloadRequired = error as? AppError { return true }
            return false
        }
    }

    @Test func loadIsIdempotentAndForwardsAutoWithoutInventingADetectedLanguage() async throws {
        let session = FluidAudioStreamingSession()
        let manager = FluidAudioUnifiedStreamingManager(language: .autoDetect, isInstalled: { true }, load: { language in
            await session.loaded(language)
            return session
        })
        #expect(await manager.displayName == FluidAudioASRModel.nemotronUnified.displayName)
        try await manager.loadModels()
        try await manager.loadModels()
        #expect(await session.languages == [.autoDetect])
        try await manager.processBufferedAudio()
        #expect(await session.processCalls == 0)
        await manager.cleanup()
        #expect(await session.cleanupCalls == 1)
    }

    @Test func finishCachesAndDeliversTheFinalTextAndResetKeepsTheSessionLoaded() async throws {
        let session = FluidAudioStreamingSession()
        let updates = Recorded<String>()
        let manager = FluidAudioUnifiedStreamingManager(language: .portuguese, isInstalled: { true }, load: { _ in session })
        await manager.setPartialTranscriptCallback { updates.append($0) }
        #expect(await manager.getPartialTranscript().isEmpty)
        try await manager.loadModels()
        #expect(try await manager.finish() == "final text")
        #expect(await manager.getPartialTranscript() == "final text")
        #expect(updates.values == ["final text"])
        try await manager.reset()
        #expect(await manager.getPartialTranscript().isEmpty)
        #expect(await session.resetCalls == 1)
        #expect(try await manager.finish() == "final text")
        await manager.cleanup()
        #expect(await manager.getPartialTranscript().isEmpty)
        #expect(await session.finishCalls == 2)
        #expect(await session.cleanupCalls == 1)
    }

    @Test func aFailedLoadCanBeRetriedAndCleanupAllowsReloading() async throws {
        let session = FluidAudioStreamingSession(failFirstLoad: true)
        let manager = FluidAudioUnifiedStreamingManager(language: .english, isInstalled: { true }, load: { language in
            try await session.load(language)
            return session
        })
        await #expect(throws: CancellationError.self) { try await manager.loadModels() }
        try await manager.loadModels()
        #expect(await session.languages == [.english, .english])
        await manager.cleanup()
        try await manager.loadModels()
        #expect(await session.languages == [.english, .english, .english])
        await manager.cleanup()
    }

    @Test func cleanupRemovesTheCallbackBeforeTheNextSession() async throws {
        let updates = Recorded<String>()
        let session = FluidAudioStreamingSession()
        let manager = FluidAudioUnifiedStreamingManager(language: .english, isInstalled: { true }, load: { _ in session })
        await manager.setPartialTranscriptCallback { updates.append($0) }
        try await manager.loadModels()
        await manager.cleanup()
        try await manager.loadModels()
        _ = try await manager.finish()
        #expect(updates.values.isEmpty)
        await manager.cleanup()
    }

    @Test func anUnloadedManagerCanResetAndCleanUpButCannotFinish() async throws {
        let manager = FluidAudioUnifiedStreamingManager(language: .english, isInstalled: { false })
        try await manager.processBufferedAudio()
        try await manager.reset()
        await manager.cleanup()
        await #expect(throws: ASRError.self) { _ = try await manager.finish() }
        #expect(await manager.getPartialTranscript().isEmpty)
    }

    @Test func everyProcessingCallDrainsTimingsWithoutChangingTranscriptState() async throws {
        let session = FluidAudioTimingSession()
        for _ in 0..<100 {
            try await FluidAudioUnifiedStreamingManager.processBufferedAudio(using: session)
            #expect(await session.pendingTimings == 0)
        }
        #expect(await session.discardCalls == 100)
        #expect(await session.getPartialTranscript() == "unchanged partial")
        let ordinary = FluidAudioStreamingSession()
        try await FluidAudioUnifiedStreamingManager.processBufferedAudio(using: ordinary)
        #expect(await ordinary.processCalls == 1)
    }

    @Test func failedProcessingStillDrainsTimingsAndPreservesTheError() async {
        let session = FluidAudioTimingSession(failProcessing: true)
        await #expect(throws: CancellationError.self) {
            try await FluidAudioUnifiedStreamingManager.processBufferedAudio(using: session)
        }
        #expect(await session.pendingTimings == 0)
        #expect(await session.discardCalls == 1)
    }

    @Test func finishingDrainsTimingsBeforeDeliveringTheSameFinalText() async throws {
        let session = FluidAudioTimingSession()
        let updates = Recorded<String>()
        let manager = FluidAudioUnifiedStreamingManager(language: .english, isInstalled: { true }, load: { _ in session })
        await manager.setPartialTranscriptCallback { updates.append($0) }
        try await manager.loadModels()
        #expect(try await manager.finish() == "final text")
        #expect(await session.pendingTimings == 0)
        #expect(await session.discardCalls == 1)
        #expect(updates.values == ["final text"])
        #expect(await manager.getPartialTranscript() == "final text")
        await manager.cleanup()
    }

    @Test func failedFinishingDrainsTimingsWithoutEmittingAPartial() async throws {
        let session = FluidAudioTimingSession(failFinishing: true)
        let updates = Recorded<String>()
        let manager = FluidAudioUnifiedStreamingManager(language: .english, isInstalled: { true }, load: { _ in session })
        await manager.setPartialTranscriptCallback { updates.append($0) }
        try await manager.loadModels()
        await #expect(throws: CancellationError.self) { _ = try await manager.finish() }
        #expect(await session.pendingTimings == 0)
        #expect(await session.discardCalls == 1)
        #expect(updates.values.isEmpty)
        #expect(await manager.getPartialTranscript().isEmpty)
        await manager.cleanup()
    }

    @Test func theNativeLocalLoaderRejectsUnsupportedLanguagesBeforeTouchingModels() async {
        await #expect {
            _ = try await FluidAudioUnifiedStreamingManager.loadLocal(language: .japanese)
        } throws: { error in
            if case .transcriptionLanguageUnsupported = error as? AppError { return true }
            return false
        }
    }
}

private actor FluidAudioStreamingSession: StreamingAsrManager {
    let displayName = "Lifecycle session"
    private(set) var languages: [MeetingLanguage] = []
    private(set) var finishCalls = 0
    private(set) var resetCalls = 0
    private(set) var cleanupCalls = 0
    private(set) var processCalls = 0
    private let failFirstLoad: Bool

    init(failFirstLoad: Bool = false) {
        self.failFirstLoad = failFirstLoad
    }

    func loaded(_ language: MeetingLanguage) { languages.append(language) }

    func load(_ language: MeetingLanguage) throws {
        languages.append(language)
        if failFirstLoad && languages.count == 1 { throw CancellationError() }
    }

    func loadModels() {}
    func appendAudio(_ buffer: AVAudioPCMBuffer) {}
    func processBufferedAudio() { processCalls += 1 }
    func finish() -> String { finishCalls += 1; return "final text" }
    func reset() { resetCalls += 1 }
    func cleanup() { cleanupCalls += 1 }
    func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) {}
    func getPartialTranscript() -> String { "" }
}

private actor FluidAudioTimingSession: StreamingAsrManager, FluidAudioStreamingTimingDiscarding {
    let displayName = "Timing lifecycle session"
    private(set) var pendingTimings = 0
    private(set) var discardCalls = 0
    private let failProcessing: Bool
    private let failFinishing: Bool

    init(failProcessing: Bool = false, failFinishing: Bool = false) {
        self.failProcessing = failProcessing
        self.failFinishing = failFinishing
    }

    func loadModels() {}
    func appendAudio(_ buffer: AVAudioPCMBuffer) {}
    func processBufferedAudio() throws {
        pendingTimings += 1
        if failProcessing { throw CancellationError() }
    }
    func finish() throws -> String {
        pendingTimings += 1
        if failFinishing { throw CancellationError() }
        return "final text"
    }
    func discardTokenTimings() { pendingTimings = 0; discardCalls += 1 }
    func reset() {}
    func cleanup() {}
    func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) {}
    func getPartialTranscript() -> String { "unchanged partial" }
}
#endif
