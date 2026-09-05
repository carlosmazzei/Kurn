//
//  ModelDownloadControllerTests.swift
//  KurnTests
//
//  `ModelDownloadController` with its two seams injected: a scripted downloader
//  (no network, no FluidAudio/whisper.cpp/sherpa-onnx downloaders, no headroom
//  probe) and a scripted "is this whisper.cpp variant on disk" predicate.
//  Covers the consent gates for every engine picker, cancel/confirm of each
//  consent, the download lifecycle (progress, success applying the deferred
//  choice, failure leaving the feature off, cancellation staying silent, the
//  network policy handed to the downloader), and `deleteModel`'s feature
//  teardown per model group.
//
//  `AppSettings` is `UserDefaults.standard`-backed, so each test snapshots and
//  restores the keys it may touch, mirroring `AppSettingsTests`.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

// MARK: - Scripted downloader

private final class ScriptedDownloader: @unchecked Sendable {
    struct Call: Equatable {
        let set: ModelSet
        let policy: LargeTransferPolicy
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _failure: Error?
    private var _holds = false
    private var _progress: [ModelDownloadStatus] = []

    var calls: [Call] { lock.withLock { _calls } }

    func fail(with error: Error) { lock.withLock { _failure = error } }
    func holdUntilCancelled() { lock.withLock { _holds = true } }
    func report(_ statuses: [ModelDownloadStatus]) { lock.withLock { _progress = statuses } }

    var closure: ModelDownloadController.Downloader {
        { [self] set, policy, onProgress in
            let (failure, holds, progress) = lock.withLock {
                _calls.append(Call(set: set, policy: policy))
                return (_failure, _holds, _progress)
            }
            for status in progress { onProgress(status) }
            if holds {
                try await Task.sleep(for: .seconds(3_600))
            }
            if let failure { throw failure }
        }
    }
}

private struct ScriptedError: Error {}

// MARK: - Harness

@MainActor
private struct Harness {
    let downloader = ScriptedDownloader()
    let settings: AppSettings
    let controller: ModelDownloadController

    let defaults: UserDefaults
    let suiteName: String

    init(installedWhisperCpp: Set<WhisperCppModel> = []) throws {
        suiteName = "ModelDownloadControllerTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        settings = AppSettings(cloudStore: InMemoryCloudKeyValueStore(), defaults: defaults)
        controller = ModelDownloadController(
            downloader: downloader.closure,
            isWhisperCppInstalled: { installedWhisperCpp.contains($0) }
        )
    }

    /// Waits for the in-flight download task to finish its main-actor
    /// epilogue (`downloadingModel` is cleared last but one, before the
    /// installed-models refresh is scheduled).
    func awaitDownloadSettled() async {
        for _ in 0..<2_000 where controller.isDownloading {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Each harness gets its own `UserDefaults` suite, so these async tests never
/// race other suites that snapshot/restore `UserDefaults.standard`.
@MainActor
private func withScopedDefaults(
    installedWhisperCpp: Set<WhisperCppModel> = [],
    _ body: (Harness) async throws -> Void
) async throws {
    let harness = try Harness(installedWhisperCpp: installedWhisperCpp)
    defer {
        harness.defaults.removePersistentDomain(forName: harness.suiteName)
    }
    try await body(harness)
}

@MainActor
@Suite("ModelDownloadController consent gates and downloads")
struct ModelDownloadControllerTests {

    // MARK: - Transcription engine gate

    @Test func appleSpeechAppliesImmediately() async throws {
        try await withScopedDefaults { h in
            h.controller.selectTranscriptionEngine(.appleSpeech, settings: h.settings, transcriptionProviders: [])
            #expect(h.settings.transcriptionEngine == .appleSpeech)
            #expect(!h.controller.showingBatchASRConsent)
            #expect(h.controller.pendingTranscriptionEngine == nil)
        }
    }

    @Test func parakeetWithoutConsentDefersBehindTheBatchASRDialog() async throws {
        try await withScopedDefaults { h in
            let before = h.settings.transcriptionEngine
            h.controller.selectTranscriptionEngine(.fluidAudioParakeet, settings: h.settings, transcriptionProviders: [])
            #expect(h.controller.showingBatchASRConsent)
            #expect(h.controller.pendingTranscriptionEngine == .fluidAudioParakeet)
            #expect(h.settings.transcriptionEngine == before)
            #expect(h.downloader.calls.isEmpty)
        }
    }

    @Test func parakeetWithConsentAppliesWithoutADialog() async throws {
        try await withScopedDefaults { h in
            h.settings.fluidAudioBatchASRModelsConsented = true
            h.controller.selectTranscriptionEngine(.fluidAudioParakeet, settings: h.settings, transcriptionProviders: [])
            #expect(h.settings.transcriptionEngine == .fluidAudioParakeet)
            #expect(!h.controller.showingBatchASRConsent)
        }
    }

    @Test func whisperAPIWithoutAProviderIsIgnored() async throws {
        try await withScopedDefaults { h in
            let before = h.settings.transcriptionEngine
            h.controller.selectTranscriptionEngine(.whisperAPI, settings: h.settings, transcriptionProviders: [])
            #expect(h.settings.transcriptionEngine == before)
        }
    }

    @Test func whisperAPIRepointsAStaleProviderToTheFirstCapableOne() async throws {
        try await withScopedDefaults { h in
            let providers = AIProvider.defaultProviders.filter { $0.id != h.settings.transcriptionProviderID }
            let first = try #require(providers.first)
            h.controller.selectTranscriptionEngine(.whisperAPI, settings: h.settings, transcriptionProviders: providers)
            #expect(h.settings.transcriptionEngine == .whisperAPI)
            #expect(h.settings.transcriptionProviderID == first.id)
        }
    }

    @Test func whisperCppWithoutWeightsOpensTheVariantChooser() async throws {
        try await withScopedDefaults { h in
            h.controller.selectTranscriptionEngine(.whisperCpp, settings: h.settings, transcriptionProviders: [])
            #expect(h.controller.showingWhisperCppModelChoice)
            #expect(h.controller.pendingTranscriptionEngine == .whisperCpp)
            #expect(h.settings.transcriptionEngine != .whisperCpp)
        }
    }

    @Test func whisperCppWithInstalledWeightsAppliesImmediately() async throws {
        try await withScopedDefaults(installedWhisperCpp: [.small]) { h in
            h.settings.whisperCppModel = .small
            h.controller.selectTranscriptionEngine(.whisperCpp, settings: h.settings, transcriptionProviders: [])
            #expect(h.settings.transcriptionEngine == .whisperCpp)
            #expect(!h.controller.showingWhisperCppModelChoice)
        }
    }

    // MARK: - whisper.cpp variants

    @Test func selectingAnInstalledVariantAppliesAndAMissingOneAsksForConsent() async throws {
        try await withScopedDefaults(installedWhisperCpp: [.base]) { h in
            h.controller.selectWhisperCppModel(.base, settings: h.settings)
            #expect(h.settings.whisperCppModel == .base)
            #expect(!h.controller.showingWhisperCppConsent)

            h.controller.selectWhisperCppModel(.largeTurbo, settings: h.settings)
            #expect(h.controller.showingWhisperCppConsent)
            #expect(h.controller.pendingWhisperCppModel == .largeTurbo)
            #expect(h.settings.whisperCppModel == .base)

            h.controller.cancelWhisperCpp()
            #expect(h.controller.pendingWhisperCppModel == nil)
            #expect(h.controller.pendingTranscriptionEngine == nil)
        }
    }

    @Test func choosingAnInstalledVariantFromTheChooserAppliesTheEngineToo() async throws {
        try await withScopedDefaults(installedWhisperCpp: [.small]) { h in
            h.controller.selectTranscriptionEngine(.whisperCpp, settings: h.settings, transcriptionProviders: [])
            h.settings.whisperCppModel = .base

            h.controller.chooseWhisperCppModel(.small, settings: h.settings)

            #expect(h.settings.whisperCppModel == .small)
            #expect(h.settings.transcriptionEngine == .whisperCpp)
            #expect(h.controller.pendingTranscriptionEngine == nil)
            #expect(h.downloader.calls.isEmpty)
        }
    }

    @Test func choosingAMissingVariantDownloadsItAndThenAppliesEngineAndVariant() async throws {
        try await withScopedDefaults { h in
            h.controller.selectTranscriptionEngine(.whisperCpp, settings: h.settings, transcriptionProviders: [])

            h.controller.chooseWhisperCppModel(.largeTurbo, settings: h.settings)
            #expect(h.controller.downloadingModel == .whisperCppASR(.largeTurbo))
            await h.awaitDownloadSettled()

            #expect(h.downloader.calls == [.init(set: .whisperCppASR(.largeTurbo), policy: .wifiOnly)])
            #expect(h.settings.whisperCppModelsConsented)
            #expect(h.settings.whisperCppModel == .largeTurbo)
            #expect(h.settings.transcriptionEngine == .whisperCpp)
            #expect(h.controller.pendingTranscriptionEngine == nil)
            #expect(h.controller.pendingWhisperCppModel == nil)
            #expect(h.controller.error == nil)
        }
    }

    @Test func confirmWhisperCppWithoutAPendingModelDoesNothing() async throws {
        try await withScopedDefaults { h in
            h.controller.confirmWhisperCpp(settings: h.settings)
            #expect(!h.controller.isDownloading)
            #expect(h.downloader.calls.isEmpty)
        }
    }

    // MARK: - Batch ASR

    @Test func batchASRConsentAppliesBothPendingPickersOnSuccess() async throws {
        try await withScopedDefaults { h in
            h.controller.selectTranscriptionEngine(.fluidAudioParakeet, settings: h.settings, transcriptionProviders: [])
            h.controller.selectLanguageDetectionEngine(.fluidAudioLID, settings: h.settings)
            #expect(h.controller.pendingLanguageDetectionEngine == .fluidAudioLID)

            h.controller.confirmBatchASR(settings: h.settings)
            #expect(h.controller.downloadingModel == .onDeviceASR)
            #expect(h.controller.downloadProgress == ModelDownloadStatus(fractionCompleted: 0, phase: .preparing))
            await h.awaitDownloadSettled()

            #expect(h.settings.fluidAudioBatchASRModelsConsented)
            #expect(h.settings.transcriptionEngine == .fluidAudioParakeet)
            #expect(h.settings.languageDetectionEngine == .fluidAudioLID)
            #expect(h.controller.pendingTranscriptionEngine == nil)
            #expect(h.controller.pendingLanguageDetectionEngine == nil)
            #expect(h.controller.downloadProgress == nil)
        }
    }

    @Test func batchASRFailureLeavesConsentOffAndSurfacesTheError() async throws {
        try await withScopedDefaults { h in
            h.downloader.fail(with: AppError.networkPolicyRestricted)
            h.controller.selectTranscriptionEngine(.fluidAudioParakeet, settings: h.settings, transcriptionProviders: [])
            let before = h.settings.transcriptionEngine

            h.controller.confirmBatchASR(settings: h.settings)
            await h.awaitDownloadSettled()

            guard case .networkPolicyRestricted = h.controller.error else {
                Issue.record("expected networkPolicyRestricted, got \(String(describing: h.controller.error))")
                return
            }
            #expect(!h.settings.fluidAudioBatchASRModelsConsented)
            #expect(h.settings.transcriptionEngine == before)
            #expect(h.controller.pendingTranscriptionEngine == nil)
            #expect(!h.controller.isDownloading)
        }
    }

    @Test func nonAppErrorsAreWrappedAsModelDownloadFailed() async throws {
        try await withScopedDefaults { h in
            h.downloader.fail(with: ScriptedError())
            h.controller.selectVADEngine(.fluidAudio, settings: h.settings)

            h.controller.confirmVAD(settings: h.settings)
            await h.awaitDownloadSettled()

            guard case .modelDownloadFailed = h.controller.error else {
                Issue.record("expected modelDownloadFailed, got \(String(describing: h.controller.error))")
                return
            }
            #expect(!h.settings.fluidAudioVADModelsConsented)
            #expect(h.settings.vadEngine == .energyThreshold)
        }
    }

    @Test func cancelBatchASRDropsBothPendingPickersWithoutDownloading() async throws {
        try await withScopedDefaults { h in
            h.controller.selectTranscriptionEngine(.fluidAudioParakeet, settings: h.settings, transcriptionProviders: [])
            h.controller.selectLanguageDetectionEngine(.fluidAudioLID, settings: h.settings)

            h.controller.cancelBatchASR()

            #expect(h.controller.pendingTranscriptionEngine == nil)
            #expect(h.controller.pendingLanguageDetectionEngine == nil)
            #expect(h.downloader.calls.isEmpty)
        }
    }

    @Test func languageDetectionByTranscriberNeedsNoConsent() async throws {
        try await withScopedDefaults { h in
            h.controller.selectLanguageDetectionEngine(.byTranscriber, settings: h.settings)
            #expect(h.settings.languageDetectionEngine == .byTranscriber)
            #expect(!h.controller.showingBatchASRConsent)
        }
    }

    // MARK: - Cancellation and policy

    @Test func cancelDownloadIsSilentAndLeavesTheFeatureOff() async throws {
        try await withScopedDefaults { h in
            h.downloader.holdUntilCancelled()
            h.controller.setLiveTranscriptionEnabled(true, settings: h.settings)
            #expect(h.controller.showingASRConsent)
            #expect(!h.settings.liveTranscriptionEnabled)

            h.controller.confirmLiveTranscriptionASR(settings: h.settings)
            #expect(h.controller.downloadingModel == .liveTranscriptionASR)
            for _ in 0..<2_000 where h.downloader.calls.isEmpty {
                try await Task.sleep(for: .milliseconds(5))
            }
            h.controller.cancelDownload()
            await h.awaitDownloadSettled()

            #expect(h.controller.error == nil)
            #expect(!h.settings.fluidAudioASRModelsConsented)
            #expect(!h.settings.liveTranscriptionEnabled)
            #expect(h.controller.downloadProgress == nil)
        }
    }

    @Test func cancelDownloadWithNothingInFlightIsANoOp() async throws {
        try await withScopedDefaults { h in
            h.controller.cancelDownload()
            #expect(!h.controller.isDownloading)
        }
    }

    @Test func liveTranscriptionWithConsentTogglesDirectly() async throws {
        try await withScopedDefaults { h in
            h.settings.fluidAudioASRModelsConsented = true
            h.controller.setLiveTranscriptionEnabled(true, settings: h.settings)
            #expect(h.settings.liveTranscriptionEnabled)
            #expect(!h.controller.showingASRConsent)
            h.controller.setLiveTranscriptionEnabled(false, settings: h.settings)
            #expect(!h.settings.liveTranscriptionEnabled)
        }
    }

    @Test func expensiveNetworkPolicyIsForwardedToTheDownloader() async throws {
        try await withScopedDefaults { h in
            h.settings.allowsExpensiveNetworkTransfers = true
            h.settings.allowsConstrainedNetworkTransfers = false
            h.controller.selectVADEngine(.fluidAudio, settings: h.settings)

            h.controller.confirmVAD(settings: h.settings)
            await h.awaitDownloadSettled()

            let call = try #require(h.downloader.calls.first)
            #expect(call.set == .vad)
            #expect(call.policy == LargeTransferPolicy(allowsExpensiveAccess: true, allowsConstrainedAccess: false))
            #expect(h.settings.fluidAudioVADModelsConsented)
            #expect(h.settings.vadEngine == .fluidAudio)
        }
    }

    @Test func progressReportedByTheDownloaderIsForwardedWhileInFlight() async throws {
        try await withScopedDefaults { h in
            h.downloader.holdUntilCancelled()
            h.downloader.report([ModelDownloadStatus(fractionCompleted: 0.5, phase: .downloading)])
            h.settings.diarizationEngine = .heuristic
            h.controller.selectDiarizationEngine(.fluidAudio, settings: h.settings)
            #expect(h.controller.showingDiarizationConsent)

            h.controller.confirmDiarization(settings: h.settings)
            for _ in 0..<2_000 where h.controller.downloadProgress?.phase != .downloading {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(h.controller.downloadProgress == ModelDownloadStatus(fractionCompleted: 0.5, phase: .downloading))

            h.controller.cancelDownload()
            await h.awaitDownloadSettled()
            #expect(h.settings.diarizationEngine == .heuristic)
        }
    }

    // MARK: - Diarization / sherpa-onnx / VAD gates

    @Test func diarizationGatesPerEngineAndCancelClearsThePendingChoice() async throws {
        try await withScopedDefaults { h in
            h.controller.selectDiarizationEngine(.heuristic, settings: h.settings)
            #expect(h.settings.diarizationEngine == .heuristic)

            h.controller.selectDiarizationEngine(.fluidAudio, settings: h.settings)
            #expect(h.controller.showingDiarizationConsent)
            #expect(h.controller.pendingDiarizationEngine == .fluidAudio)
            h.controller.cancelDiarization()
            #expect(h.controller.pendingDiarizationEngine == nil)

            h.controller.selectDiarizationEngine(.sherpaOnnx, settings: h.settings)
            #expect(h.controller.showingSherpaOnnxConsent)
            #expect(h.controller.pendingDiarizationEngine == .sherpaOnnx)
            h.controller.cancelSherpaOnnx()
            #expect(h.controller.pendingDiarizationEngine == nil)
            #expect(h.settings.diarizationEngine == .heuristic)

            h.controller.confirmDiarization(settings: h.settings)
            h.controller.confirmSherpaOnnx(settings: h.settings)
            #expect(!h.controller.isDownloading)
        }
    }

    @Test func consentedDiarizationEnginesApplyDirectly() async throws {
        try await withScopedDefaults { h in
            h.settings.fluidAudioDiarizationModelsConsented = true
            h.controller.selectDiarizationEngine(.fluidAudio, settings: h.settings)
            #expect(h.settings.diarizationEngine == .fluidAudio)

            h.settings.sherpaOnnxModelsConsented = true
            h.controller.selectDiarizationEngine(.sherpaOnnx, settings: h.settings)
            #expect(h.settings.diarizationEngine == .sherpaOnnx)
            #expect(!h.controller.showingSherpaOnnxConsent)
        }
    }

    @Test func sherpaOnnxDownloadAppliesTheEngineOnSuccess() async throws {
        try await withScopedDefaults { h in
            h.controller.selectDiarizationEngine(.sherpaOnnx, settings: h.settings)
            h.controller.confirmSherpaOnnx(settings: h.settings)
            #expect(h.controller.downloadingModel == .sherpaOnnxDiarization)
            await h.awaitDownloadSettled()

            #expect(h.settings.sherpaOnnxModelsConsented)
            #expect(h.settings.diarizationEngine == .sherpaOnnx)
            #expect(h.controller.pendingDiarizationEngine == nil)
        }
    }

    @Test func vadGateAndCancel() async throws {
        try await withScopedDefaults { h in
            h.controller.selectVADEngine(.energyThreshold, settings: h.settings)
            #expect(h.settings.vadEngine == .energyThreshold)

            h.controller.selectVADEngine(.fluidAudio, settings: h.settings)
            #expect(h.controller.showingVADConsent)
            #expect(h.controller.pendingVADEngine == .fluidAudio)
            h.controller.cancelVAD()
            #expect(h.controller.pendingVADEngine == nil)

            h.controller.confirmVAD(settings: h.settings)
            #expect(!h.controller.isDownloading)
        }
    }
}

@MainActor
@Suite("ModelDownloadController.deleteModel")
struct ModelDownloadControllerDeleteModelTests {

    // MARK: - deleteModel

    private func installed(_ group: ModelStore.ModelGroup?) -> ModelStore.InstalledModel {
        ModelStore.InstalledModel(
            id: group?.rawValue ?? "other",
            group: group,
            displayName: "test",
            folderNames: ["kurn-tests-nonexistent-\(UUID().uuidString)"],
            size: 0
        )
    }

    @Test func deletingLiveTranscriptionModelsTurnsTheFeatureOff() async throws {
        try await withScopedDefaults { h in
            h.settings.fluidAudioASRModelsConsented = true
            h.settings.liveTranscriptionEnabled = true
            h.controller.pendingModelDeletion = installed(.liveTranscription)

            h.controller.deleteModel(installed(.liveTranscription), settings: h.settings)

            #expect(!h.settings.liveTranscriptionEnabled)
            #expect(!h.settings.fluidAudioASRModelsConsented)
            #expect(h.controller.pendingModelDeletion == nil)
        }
    }

    @Test func deletingOnDeviceLanguageModelsFallsBackOnlyTheDependentEngines() async throws {
        try await withScopedDefaults { h in
            h.settings.fluidAudioBatchASRModelsConsented = true
            h.settings.transcriptionEngine = .fluidAudioParakeet
            h.settings.languageDetectionEngine = .fluidAudioLID

            h.controller.deleteModel(installed(.onDeviceLanguage), settings: h.settings)

            #expect(!h.settings.fluidAudioBatchASRModelsConsented)
            #expect(h.settings.transcriptionEngine == .appleSpeech)
            #expect(h.settings.languageDetectionEngine == .byTranscriber)

            h.settings.transcriptionEngine = .appleSpeech
            h.controller.deleteModel(installed(.onDeviceLanguage), settings: h.settings)
            #expect(h.settings.transcriptionEngine == .appleSpeech)
        }
    }

    @Test func deletingDiarizationAndSherpaModelsResetTheEngine() async throws {
        try await withScopedDefaults { h in
            h.settings.fluidAudioDiarizationModelsConsented = true
            h.settings.diarizationEngine = .fluidAudio
            h.controller.deleteModel(installed(.diarization), settings: h.settings)
            #expect(!h.settings.fluidAudioDiarizationModelsConsented)
            #expect(h.settings.diarizationEngine == .heuristic)

            h.settings.sherpaOnnxModelsConsented = true
            h.settings.diarizationEngine = .sherpaOnnx
            h.controller.deleteModel(installed(.sherpaOnnxDiarization), settings: h.settings)
            #expect(!h.settings.sherpaOnnxModelsConsented)
            #expect(h.settings.diarizationEngine == .heuristic)

            h.settings.sherpaOnnxModelsConsented = true
            h.settings.diarizationEngine = .heuristic
            h.controller.deleteModel(installed(.sherpaOnnxDiarization), settings: h.settings)
            #expect(h.settings.diarizationEngine == .heuristic)
        }
    }

    @Test func deletingVADModelsResetsToEnergyThreshold() async throws {
        try await withScopedDefaults { h in
            h.settings.fluidAudioVADModelsConsented = true
            h.settings.vadEngine = .fluidAudio
            h.controller.deleteModel(installed(.vad), settings: h.settings)
            #expect(!h.settings.fluidAudioVADModelsConsented)
            #expect(h.settings.vadEngine == .energyThreshold)
        }
    }

    @Test func deletingTheLastWhisperCppVariantTearsTheEngineDown() async throws {
        try await withScopedDefaults { h in
            h.settings.whisperCppModelsConsented = true
            h.settings.transcriptionEngine = .whisperCpp
            h.controller.deleteModel(installed(.whisperCpp), settings: h.settings)
            #expect(!h.settings.whisperCppModelsConsented)
            #expect(h.settings.transcriptionEngine == .appleSpeech)
        }
    }

    @Test func deletingTheActiveWhisperCppVariantRepointsToARemainingOne() async throws {
        try await withScopedDefaults(installedWhisperCpp: [.base]) { h in
            h.settings.whisperCppModelsConsented = true
            h.settings.whisperCppModel = .largeTurbo
            h.settings.transcriptionEngine = .whisperCpp

            h.controller.deleteModel(installed(.whisperCpp), settings: h.settings)

            #expect(h.settings.whisperCppModelsConsented)
            #expect(h.settings.transcriptionEngine == .whisperCpp)
            #expect(h.settings.whisperCppModel == .base)
        }
    }

    @Test func deletingAnUnclaimedFolderOnlyClearsThePendingDeletion() async throws {
        try await withScopedDefaults { h in
            let snapshot = (h.settings.transcriptionEngine, h.settings.diarizationEngine, h.settings.vadEngine)
            h.controller.pendingModelDeletion = installed(nil)

            h.controller.deleteModel(installed(nil), settings: h.settings)

            #expect(h.controller.pendingModelDeletion == nil)
            #expect(h.settings.transcriptionEngine == snapshot.0)
            #expect(h.settings.diarizationEngine == snapshot.1)
            #expect(h.settings.vadEngine == snapshot.2)
        }
    }
}
