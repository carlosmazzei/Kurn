import Foundation
import KurnCore
import Testing
@testable import Kurn

@MainActor
struct FluidAudioSettingsTests {
    private func withSettings(_ body: (AppSettings, UserDefaults) throws -> Void) throws {
        let name = "FluidAudioSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(AppSettings(cloudStore: InMemoryCloudKeyValueStore(), defaults: defaults), defaults)
    }

    @Test func freshInstallPreservesModelsAndDoesNotGrantNewConsent() throws {
        try withSettings { settings, _ in
            #expect(settings.fluidAudioASRModel == .parakeetV3)
            #expect(settings.fluidAudioLiveModel == .automatic)
            #expect(settings.fluidAudioDiarizationModel == .pyannote)
            #expect(settings.fluidAudioSegmentationBatchSize == .maximum)
            #expect(settings.transcriptionEngine == .appleSpeech)
            #expect(!settings.selectedFluidAudioASRModelsConsented)
            #expect(!settings.selectedFluidAudioLiveModelsConsented)
            #expect(!settings.selectedFluidDiarizationConsented)
            #expect(settings.fluidAudioASRModelConsents.isEmpty)
        }
    }

    @Test func modelChoicesAndConsentPersistIndependently() throws {
        try withSettings { settings, defaults in
            settings.fluidAudioASRModel = .nemotronUnified
            settings.fluidAudioLiveModel = .nemotronUnified
            settings.fluidAudioDiarizationModel = .nemotron3
            settings.fluidAudioSegmentationBatchSize = .balanced
            settings.fluidAudioASRModelConsents = [FluidAudioASRModel.nemotronUnified.rawValue]
            settings.fluidAudioUnifiedStreamingConsented = true
            settings.fluidAudioNemotronModelsConsented = true
            let restored = AppSettings(cloudStore: InMemoryCloudKeyValueStore(), defaults: defaults)
            #expect(restored.fluidAudioASRModel == .nemotronUnified)
            #expect(restored.fluidAudioLiveModel == .nemotronUnified)
            #expect(restored.fluidAudioDiarizationModel == .nemotron3)
            #expect(restored.fluidAudioSegmentationBatchSize == .balanced)
            #expect(restored.selectedFluidAudioASRModelsConsented)
            #expect(restored.selectedFluidAudioLiveModelsConsented)
            #expect(restored.selectedFluidDiarizationConsented)
            #expect(!restored.fluidAudioBatchASRModelsConsented)
            #expect(!restored.fluidAudioASRModelsConsented)
            #expect(!restored.fluidAudioDiarizationModelsConsented)
        }
    }

    @Test func legacyConsentDoesNotAuthorizeADifferentModel() throws {
        try withSettings { settings, _ in
            settings.fluidAudioBatchASRModelsConsented = true
            settings.fluidAudioASRModelsConsented = true
            settings.fluidAudioDiarizationModelsConsented = true
            #expect(settings.selectedFluidAudioASRModelsConsented)
            #expect(settings.selectedFluidAudioLiveModelsConsented)
            #expect(settings.selectedFluidDiarizationConsented)
            settings.fluidAudioASRModel = .bark3
            settings.fluidAudioLiveModel = .nemotronUnified
            settings.fluidAudioDiarizationModel = .nemotron3
            #expect(!settings.selectedFluidAudioASRModelsConsented)
            #expect(!settings.selectedFluidAudioLiveModelsConsented)
            #expect(!settings.selectedFluidDiarizationConsented)
        }
    }

    @Test func unknownStoredChoicesFallBackToLegacyDefaults() throws {
        try withSettings { _, defaults in
            for key in ["fluidAudioASRModel", "fluidAudioLiveModel", "fluidAudioDiarizationModel"] {
                defaults.set("future-model", forKey: "settings.\(key)")
            }
            defaults.set(999, forKey: "settings.fluidAudioSegmentationBatchSize")
            let restored = AppSettings(cloudStore: InMemoryCloudKeyValueStore(), defaults: defaults)
            #expect(restored.fluidAudioASRModel == .parakeetV3)
            #expect(restored.fluidAudioLiveModel == .automatic)
            #expect(restored.fluidAudioDiarizationModel == .pyannote)
            #expect(restored.fluidAudioSegmentationBatchSize == .maximum)
        }
    }

    @Test func pipelineUsesTheSelectedModelsAndTheirOwnConsent() throws {
        try withSettings { settings, _ in
            settings.transcriptionEngine = .fluidAudioParakeet
            settings.fluidAudioASRModel = .nemotronUnified
            settings.fluidAudioASRModelConsents.insert(FluidAudioASRModel.nemotronUnified.rawValue)
            settings.fluidAudioDiarizationModel = .nemotron3
            settings.fluidAudioNemotronModelsConsented = true
            settings.fluidAudioSegmentationBatchSize = .lowMemory
            let config = settings.pipelineConfiguration
            #expect(config.fluidAudioASRModel == .nemotronUnified)
            #expect(config.fluidAudioASRConsented)
            #expect(config.fluidAudioDiarizationModel == .nemotron3)
            #expect(config.fluidAudioSegmentationBatchSize == .lowMemory)
            #expect(config.effectiveDiarization == .fluidAudio)
        }
    }

    @Test func anotherASRModelDoesNotPrewarmParakeetUnlessLanguageDetectionNeedsIt() throws {
        try withSettings { settings, _ in
            settings.transcriptionEngine = .fluidAudioParakeet
            settings.fluidAudioBatchASRModelsConsented = true
            settings.fluidAudioASRModel = .nemotronUnified
            #expect(!settings.usesFluidAudioModel)
            settings.languageDetectionEngine = .fluidAudioLID
            #expect(settings.usesFluidAudioModel)
            settings.fluidAudioBatchASRModelsConsented = false
            #expect(!settings.usesFluidAudioModel)
        }
    }
}
