import Foundation
import KurnCore

#if canImport(FluidAudio)
import CoreML
import FluidAudio

enum FluidAudioASRModelRuntime {
    static let unifiedPrecision: UnifiedEncoderPrecision = .fp16
    static let transcribeLiteComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    static var unifiedDirectory: URL { MLModelConfigurationUtils.defaultModelsDirectory(for: .nemotronUnified) }
    static var transcribeLiteDirectory: URL {
        MLModelConfigurationUtils.defaultModelsDirectory(for: .nemotron35TranscribeLite)
    }

    static func asrVersion(for model: FluidAudioASRModel) -> AsrModelVersion? {
        switch model {
        case .parakeetV3: return .v3
        case .bark3: return .bark3
        case .bark3Clean: return .bark3Clean
        case .phonon2: return .phonon2
        case .nemotronUnified, .nemotronTranscribeLite: return nil
        }
    }

    static func unifiedLanguage(for language: MeetingLanguage) -> NemotronUnifiedLanguage? {
        NemotronUnifiedLanguage(rawValue: FluidAudioRuntimePolicy.unifiedLanguageCode(for: language))
    }

    static func unifiedConfig(_ language: NemotronUnifiedLanguage) -> UnifiedConfig {
        UnifiedConfig(family: .nemotronMultilingual(language))
    }

    static var unifiedSharedFiles: [String] {
        let family = unifiedConfig(.auto).family
        return [family.decoderFile, family.jointDecisionFile, family.vocab, family.metadata]
    }

    static var unifiedBatchFiles: [String] {
        unifiedSharedFiles + [unifiedConfig(.auto).family.offlineEncoderFile(precision: unifiedPrecision)]
    }

    static var unifiedStreamingFiles: [String] {
        let config = unifiedConfig(.auto)
        return unifiedSharedFiles + [config.family.streamingEncoderFile(
            precision: unifiedPrecision, contextSuffix: config.contextSuffix
        )]
    }

    static func installation(for model: FluidAudioASRModel) -> (directory: URL, files: [String]) {
        let tdtFiles = ModelNames.ASR.requiredModelsV3().union([ModelNames.ASR.vocabularyFile]).sorted()
        switch model {
        case .parakeetV3: return (AsrModels.defaultCacheDirectory(for: .v3), tdtFiles)
        case .bark3: return (AsrModels.defaultCacheDirectory(for: .bark3), tdtFiles)
        case .bark3Clean: return (AsrModels.defaultCacheDirectory(for: .bark3Clean), tdtFiles)
        case .phonon2: return (AsrModels.defaultCacheDirectory(for: .phonon2), tdtFiles)
        case .nemotronUnified:
            return (unifiedDirectory, unifiedBatchFiles)
        case .nemotronTranscribeLite:
            return (transcribeLiteDirectory, ModelNames.NemotronTranscribeLite.requiredModels.sorted())
        }
    }

    static func isInstalled(_ model: FluidAudioASRModel) -> Bool {
        isInstalled(model, fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    static func isInstalled(
        _ model: FluidAudioASRModel,
        enumerate: (String) -> [String]? = FluidAudioRuntimePolicy.modelContents,
        fileExists: (String) -> Bool
    ) -> Bool {
        let installation = installation(for: model)
        return FluidAudioRuntimePolicy.missingFiles(
            installation.files, in: installation.directory, enumerate: enumerate, fileExists: fileExists
        ).isEmpty
    }

    static var isUnifiedStreamingInstalled: Bool { unifiedStreamingIsInstalled() }

    static func unifiedStreamingIsInstalled(
        enumerate: (String) -> [String]? = FluidAudioRuntimePolicy.modelContents,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        FluidAudioRuntimePolicy.missingFiles(
            unifiedStreamingFiles, in: unifiedDirectory, enumerate: enumerate, fileExists: fileExists
        ).isEmpty
    }

    static func downloadStatus(for progress: DownloadProgress) -> ModelDownloadStatus {
        let phase: ModelDownloadPhase
        switch progress.phase {
        case .listing: phase = .preparing
        case .downloading: phase = .downloading
        case .compiling: phase = .compiling
        }
        return .scaled(progress.fractionCompleted, from: 0, to: 1, phase: phase)
    }
}
#endif
