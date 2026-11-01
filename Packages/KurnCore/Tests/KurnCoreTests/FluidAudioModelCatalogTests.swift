import Foundation
import Testing
import KurnCore

struct FluidAudioModelCatalogTests {
    private let europeanCodes: Set<String> = [
        "en", "es", "fr", "de", "it", "pt", "nl", "pl", "cs", "sk", "hu", "ro",
        "bg", "hr", "sl", "da", "sv", "fi", "et", "lv", "lt", "el", "mt", "ru", "uk"
    ]

    @Test func persistedASRValuesAndLegacyDefaultRemainStable() throws {
        let rawValues = ["parakeetV3", "nemotronUnified", "bark3", "bark3Clean", "phonon2", "nemotronTranscribeLite"]
        #expect(FluidAudioASRModel.allCases.map(\.rawValue) == rawValues)
        #expect(FluidAudioASRModel.default == .parakeetV3)
        for model in FluidAudioASRModel.allCases {
            #expect(model.id == model.rawValue)
            #expect(try JSONDecoder().decode(FluidAudioASRModel.self, from: JSONEncoder().encode(model)) == model)
            #expect(try JSONEncoder().encode(model) == Data("\"\(model.rawValue)\"".utf8))
        }
        #expect(FluidAudioASRModel(rawValue: "unknown") == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FluidAudioASRModel.self, from: Data("\"unknown\"".utf8))
        }
    }

    @Test(arguments: [FluidAudioASRModel.parakeetV3, .nemotronUnified])
    func multilingualModelsCoverTheExistingTwentyFiveCodes(model: FluidAudioASRModel) {
        #expect(model.supportedLanguageCodes == europeanCodes)
        #expect(model.supportedLanguageCodes.count == 25)
        #expect(model.supportsAutoDetect)
        #expect(model.supports(.autoDetect))
        #expect(model.supports(.portuguese))
        #expect(model.supports(.maltese))
        #expect(model.supports(.english))
        #expect(!model.supports(.japanese))
        #expect(!model.supports(.arabic))
        for language in MeetingLanguage.allCases {
            let expected = language.whisperCode.map(europeanCodes.contains) ?? true
            #expect(model.supports(language) == expected)
        }
    }

    @Test(arguments: [FluidAudioASRModel.bark3, .bark3Clean, .phonon2, .nemotronTranscribeLite])
    func englishOnlyModelsRequireExplicitEnglish(model: FluidAudioASRModel) {
        #expect(model.supportedLanguageCodes == ["en"])
        #expect(!model.supportsAutoDetect)
        for language in MeetingLanguage.allCases {
            #expect(model.supports(language) == (language == .english))
        }
    }

    private struct ASRMetadata {
        let name: String
        let bytes: Int64
        let folder: String
    }

    @Test func ASRMetadataAndCacheIdentitiesMatchTheRuntimeCatalog() {
        let expected: [FluidAudioASRModel: ASRMetadata] = [
            .parakeetV3: ASRMetadata(name: "Parakeet TDT v3", bytes: 480_000_000, folder: "parakeet-tdt-0.6b-v3"),
            .nemotronUnified: ASRMetadata(name: "Nemotron Unified 0.6B", bytes: 1_200_000_000, folder: "nemotron-labs-unified-asr"),
            .bark3: ASRMetadata(name: "Bark 3.0", bytes: 435_000_000, folder: "bark-3.0"),
            .bark3Clean: ASRMetadata(name: "Bark 3.0 Clean", bytes: 445_000_000, folder: "bark-3.0-clean"),
            .phonon2: ASRMetadata(name: "Phonon-2", bytes: 360_000_000, folder: "phonon-2"),
            .nemotronTranscribeLite: ASRMetadata(name: "Nemotron 3.5 Transcribe Lite", bytes: 1_400_000_000, folder: "nemotron-3.5-transcribe-lite")
        ]
        for (model, metadata) in expected {
            #expect(model.displayName == metadata.name)
            #expect(model.approximateBytes == metadata.bytes)
            #expect(model.folderName == metadata.folder)
            #expect(!model.folderName.contains("/"))
            let checkpointID = model == .parakeetV3 ? nil : "fluidaudio:\(model.rawValue)"
            #expect(model.checkpointProviderID == checkpointID)
        }
        #expect(Set(FluidAudioASRModel.allCases.map(\.folderName)).count == expected.count)
        #expect(Set(FluidAudioASRModel.allCases.compactMap(\.checkpointProviderID)).count == expected.count - 1)
    }

    @Test func livePersistedValuesAndLegacySelectionRemainStable() throws {
        #expect(FluidAudioLiveModel.allCases.map(\.rawValue) == ["automatic", "nemotronUnified"])
        #expect(FluidAudioLiveModel.default == .automatic)
        for model in FluidAudioLiveModel.allCases {
            #expect(model.id == model.rawValue)
            #expect(!model.displayName.isEmpty)
            #expect(model.supportsAutoDetect)
            #expect(model.supports(.autoDetect))
            #expect(model.supports(.portuguese))
            #expect(model.supports(.english))
            #expect(try JSONDecoder().decode(FluidAudioLiveModel.self, from: JSONEncoder().encode(model)) == model)
            #expect(try JSONEncoder().encode(model) == Data("\"\(model.rawValue)\"".utf8))
        }
        #expect(FluidAudioLiveModel(rawValue: "unknown") == nil)
    }

    @Test func liveCatalogDistinguishesAutomaticStreamingFromUnifiedLanguages() {
        let automaticCodes: Set<String> = ["en", "es", "fr", "it", "pt", "de", "zh", "ja"]
        #expect(FluidAudioLiveModel.automatic.supportedLanguageCodes == automaticCodes)
        #expect(FluidAudioLiveModel.nemotronUnified.supportedLanguageCodes == europeanCodes)
        for model in FluidAudioLiveModel.allCases {
            for language in MeetingLanguage.allCases {
                let expected = language.whisperCode.map(model.supportedLanguageCodes.contains) ?? true
                #expect(model.supports(language) == expected)
            }
        }
        #expect(FluidAudioLiveModel.automatic.supports(.japanese))
        #expect(!FluidAudioLiveModel.nemotronUnified.supports(.japanese))
        #expect(!FluidAudioLiveModel.automatic.supports(.maltese))
        #expect(FluidAudioLiveModel.nemotronUnified.supports(.maltese))
    }

    @Test func diarizationMetadataAndPersistedValuesRemainStable() throws {
        #expect(FluidAudioDiarizationModel.allCases.map(\.rawValue) == ["pyannote", "nemotron3"])
        #expect(FluidAudioDiarizationModel.default == .pyannote)
        #expect(FluidAudioDiarizationModel.pyannote.displayName == "Pyannote")
        #expect(FluidAudioDiarizationModel.nemotron3.displayName == "Nemotron 3")
        #expect(FluidAudioDiarizationModel.pyannote.supportsPinnedSpeakerCount)
        #expect(!FluidAudioDiarizationModel.nemotron3.supportsPinnedSpeakerCount)
        #expect(FluidAudioDiarizationModel.pyannote.maximumSpeakers == nil)
        #expect(FluidAudioDiarizationModel.nemotron3.maximumSpeakers == 8)
        #expect(FluidAudioDiarizationModel.pyannote.approximateBytes == 100_000_000)
        #expect(FluidAudioDiarizationModel.nemotron3.approximateBytes == 190_000_000)
        #expect(FluidAudioDiarizationModel.pyannote.folderName == "speaker-diarization")
        #expect(FluidAudioDiarizationModel.nemotron3.folderName == "nemotron-3-diarization")
        for model in FluidAudioDiarizationModel.allCases {
            #expect(model.id == model.rawValue)
            #expect(!model.folderName.contains("/"))
            #expect(try JSONDecoder().decode(FluidAudioDiarizationModel.self, from: JSONEncoder().encode(model)) == model)
            #expect(try JSONEncoder().encode(model) == Data("\"\(model.rawValue)\"".utf8))
        }
        #expect(FluidAudioDiarizationModel(rawValue: "unknown") == nil)
    }

    @Test func segmentationBatchChoicesPreserveThirtyTwoAndRecommendEight() throws {
        #expect(FluidAudioSegmentationBatchSize.allCases == [.lowMemory, .balanced, .throughput, .maximum])
        #expect(FluidAudioSegmentationBatchSize.allCases.map(\.rawValue) == [4, 8, 16, 32])
        #expect(FluidAudioSegmentationBatchSize.default == .maximum)
        #expect(FluidAudioSegmentationBatchSize.recommended == .balanced)
        for choice in FluidAudioSegmentationBatchSize.allCases {
            #expect(choice.id == choice.rawValue)
            #expect(try JSONDecoder().decode(FluidAudioSegmentationBatchSize.self, from: JSONEncoder().encode(choice)) == choice)
            #expect(try JSONEncoder().encode(choice) == Data("\(choice.rawValue)".utf8))
        }
        for invalid in [0, 1, 3, 5, 33, 64] {
            #expect(FluidAudioSegmentationBatchSize(rawValue: invalid) == nil)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FluidAudioSegmentationBatchSize.self, from: Data("7".utf8))
        }
    }
}
