//
//  AppSettingsTests.swift
//  KurnTests
//
//  Covers the derived/computed surfaces of AppSettings: the per-stage pipeline
//  assembly, provider selection fallback, and summary-model fallback, plus the
//  legacy→engine migration. AppSettings reads/writes `UserDefaults.standard`, so
//  each test runs inside a scope that clears the relevant keys and restores the
//  user's real values afterward (no pollution of the app's defaults).
//

import Foundation
import Testing
@testable import Kurn

@MainActor
struct AppSettingsTests {

    private static let keys = [
        "settings.aiProvider", "settings.aiProviders", "settings.defaultTranscriptionMode",
        "settings.defaultLanguage", "settings.micPickup", "settings.audioQuality",
        "settings.summaryModels", "settings.summaryTemplates", "settings.lastSummaryTemplate",
        "settings.liveTranscriptionEnabled", "settings.diarizationEngine", "settings.transcriptionEngine",
        "settings.diarizationPreprocessingEnabled", "settings.preprocessingEngine",
        "settings.vadEngine", "settings.languageDetectionEngine",
        "settings.fluidAudioASRModelsConsented", "settings.fluidAudioBatchASRModelsConsented",
        "settings.fluidAudioDiarizationModelsConsented", "settings.fluidAudioVADModelsConsented",
        "settings.logLevel", "settings.meetingsSortOrder"
    ]

    /// Run `body` against a freshly-defaulted AppSettings, restoring the user's
    /// real UserDefaults (and `AppLog.minimumLevel`) afterward.
    private func withScopedDefaults(_ body: (AppSettings) -> Void) {
        let defaults = UserDefaults.standard
        let snapshot = Self.keys.reduce(into: [String: Any]()) { acc, key in
            if let value = defaults.object(forKey: key) { acc[key] = value }
        }
        let originalLogLevel = AppLog.minimumLevel
        defer {
            for key in Self.keys {
                if let value = snapshot[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            AppLog.minimumLevel = originalLogLevel
        }
        for key in Self.keys { defaults.removeObject(forKey: key) }
        body(AppSettings())
    }

    @Test func pipelineConfigurationReflectsIndividualEngineChoices() {
        withScopedDefaults { settings in
            settings.preprocessingEngine = .none
            settings.vadEngine = .fluidAudio
            settings.languageDetectionEngine = .fluidAudioLID
            settings.diarizationEngine = .fluidAudio
            settings.transcriptionEngine = .whisperAPI
            settings.diarizationPreprocessingEnabled = false

            let config = settings.pipelineConfiguration
            #expect(config.preprocessing == .none)
            #expect(config.vad == .fluidAudio)
            #expect(config.languageDetection == .fluidAudioLID)
            #expect(config.diarization == .fluidAudio)
            #expect(config.transcription == .whisperAPI)
            #expect(config.diarizationPreprocessingEnabled == false)
        }
    }

    @Test func freshSettingsUseAlwaysAvailablePipeline() {
        withScopedDefaults { settings in
            #expect(settings.pipelineConfiguration == PipelineConfiguration())
        }
    }

    @Test func aiProviderFallsBackToFirstWhenSelectedIDMissing() {
        withScopedDefaults { settings in
            settings.aiProviderID = "no-such-provider"
            #expect(settings.aiProvider.id == settings.providers.first?.id)
        }
    }

    @Test func aiProviderResolvesSelectedID() {
        withScopedDefaults { settings in
            settings.aiProviderID = AIProvider.anthropic.id
            #expect(settings.aiProvider.id == "anthropic")
        }
    }

    @Test func summaryModelFallsBackToProviderDefaultThenStored() {
        withScopedDefaults { settings in
            #expect(settings.summaryModel(for: .openAI) == AIProvider.openAI.defaultModel)
            settings.setSummaryModel("custom-model", for: .openAI)
            #expect(settings.summaryModel(for: .openAI) == "custom-model")
        }
    }

    @Test func whisperModeMigratesToWhisperRegardlessOfLanguage() {
        #expect(
            AppSettings.migratedTranscriptionEngine(
                mode: .whisperAPI, language: .portuguese, multilingualConsented: false
            ) == .whisperAPI
        )
    }
}
