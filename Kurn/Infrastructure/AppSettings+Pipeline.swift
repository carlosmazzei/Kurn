//
//  AppSettings+Pipeline.swift
//  Kurn
//

import KurnCore

extension AppSettings {
    /// The full per-stage pipeline configuration assembled from the individual
    /// engine preferences, passed to `TranscriptionService`.
    var pipelineConfiguration: PipelineConfiguration {
        PipelineConfiguration(
            preprocessing: preprocessingEngine,
            vad: vadEngine,
            languageDetection: languageDetectionEngine,
            diarization: diarizationEngine,
            diarizationConsented: selectedFluidDiarizationConsented,
            sherpaOnnxConsented: sherpaOnnxModelsConsented,
            transcription: transcriptionEngine,
            transcriptionProvider: transcriptionProvider,
            transcriptionModel: transcriptionModel(for: transcriptionProvider),
            cloudTranscriptionConsented: hasCloudTranscriptionConsent(for: transcriptionProvider),
            largeTransferPolicy: largeTransferPolicy,
            fluidAudioSpeakerCount: fluidAudioSpeakerCount,
            diarizationPreprocessingEnabled: diarizationPreprocessingEnabled,
            whisperCppModel: whisperCppModel,
            fluidAudioASRModel: fluidAudioASRModel,
            fluidAudioASRConsented: selectedFluidAudioASRModelsConsented,
            fluidAudioDiarizationModel: fluidAudioDiarizationModel,
            fluidAudioSegmentationBatchSize: fluidAudioSegmentationBatchSize,
            correction: correctionEnabled ? .llm : .none,
            correctionProvider: aiProvider,
            correctionModel: correctionEnabled ? summaryModel(for: aiProvider) : "",
            correctionConsented: correctionEnabled && aiProvider.isUsable
        )
    }

    /// Whether the selected pipeline relies on the FluidAudio on-device ASR model
    /// (as the Parakeet transcriber or the auto-language detector) *and* the user
    /// has consented to downloading it. Gates foreground pre-warming so the model
    /// is only loaded for users who will actually use it, and never downloaded
    /// without consent. See `FluidAudioModelStore.prewarm()`.
    var usesFluidAudioModel: Bool {
        let needsOnDeviceASR = (transcriptionEngine == .fluidAudioParakeet && fluidAudioASRModel == .parakeetV3)
            || languageDetectionEngine.requiredModelSet == .onDeviceASR
        return needsOnDeviceASR && fluidAudioBatchASRModelsConsented
    }

    var largeTransferPolicy: LargeTransferPolicy {
        LargeTransferPolicy(
            allowsExpensiveAccess: allowsExpensiveNetworkTransfers,
            allowsConstrainedAccess: allowsConstrainedNetworkTransfers
        )
    }
}
