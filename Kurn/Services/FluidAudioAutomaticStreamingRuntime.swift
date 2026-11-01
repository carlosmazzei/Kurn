import Foundation
import KurnCore

#if canImport(FluidAudio)
import FluidAudio

enum FluidAudioAutomaticStreamingRuntime {
    enum Backend: Sendable, Equatable {
        case english
        case multilingual
    }

    typealias Factory = @Sendable (Backend) async throws -> any StreamingAsrManager

    static func backend(for language: MeetingLanguage) -> Backend {
        language.usesEnglishOnlyStreamingModel ? .english : .multilingual
    }

    static var englishDirectory: URL {
        MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetEou160)
            .deletingLastPathComponent().appendingPathComponent(Repo.parakeetEou160.folderName)
    }

    static var englishFiles: [String] { ModelNames.ParakeetEOU.requiredModels.sorted() }

    static func multilingualDirectory(chunkMs: Int = 2240) -> URL {
        MLModelConfigurationUtils.defaultModelsDirectory(for: .nemotronMultilingual)
            .appendingPathComponent(StreamingNemotronMultilingualAsrManager.languageDirectory(for: "auto"))
            .appendingPathComponent("\(chunkMs)ms")
    }

    static var multilingualBaseFiles: [String] {
        [ModelNames.NemotronMultilingualStreaming.encoderFile,
         ModelNames.NemotronMultilingualStreaming.metadata, ModelNames.NemotronMultilingualStreaming.tokenizer]
    }

    static var multilingualOptionalModels: [String] {
        [ModelNames.NemotronMultilingualStreaming.decoderFile, ModelNames.NemotronMultilingualStreaming.jointFile,
         "decoder_joint.mlmodelc", "decoder_joint_noencproj.mlmodelc", "decoder_joint_argmax.mlmodelc",
         "joint_noencproj_batched.mlmodelc"]
    }

    static func multilingualIsInstalled(
        chunkMs: Int = 2240,
        enumerate: (String) -> [String]? = FluidAudioRuntimePolicy.modelContents,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        let directory = multilingualDirectory(chunkMs: chunkMs)
        let present = multilingualOptionalModels.filter { fileExists(directory.appendingPathComponent($0).path) }
        guard FluidAudioRuntimePolicy.missingFiles(
            multilingualBaseFiles + present, in: directory, enumerate: enumerate, fileExists: fileExists
        ).isEmpty else { return false }
        let barePair = present.contains(ModelNames.NemotronMultilingualStreaming.decoderFile)
            && present.contains(ModelNames.NemotronMultilingualStreaming.jointFile)
        let fused = present.contains { $0.hasPrefix("decoder_joint") }
        return (barePair || fused) && (!present.contains("joint_noencproj_batched.mlmodelc") || barePair)
    }

    static var isInstalled: Bool { installed() }

    static func installed(
        enumerate: (String) -> [String]? = FluidAudioRuntimePolicy.modelContents,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        FluidAudioRuntimePolicy.missingFiles(
            englishFiles, in: englishDirectory, enumerate: enumerate, fileExists: fileExists
        ).isEmpty && multilingualIsInstalled(enumerate: enumerate, fileExists: fileExists)
    }

    static func load(language: MeetingLanguage) async throws -> any StreamingAsrManager {
        try await load(language: language, isInstalled: { isInstalled }, factory: loadLocal)
    }

    static func load(
        language: MeetingLanguage,
        isInstalled: @Sendable () -> Bool,
        factory: Factory
    ) async throws -> any StreamingAsrManager {
        guard FluidAudioLiveModel.automatic.supports(language) else {
            throw AppError.transcriptionLanguageUnsupported(language, .fluidAudioParakeet)
        }
        guard isInstalled() else {
            throw AppError.modelDownloadRequired(FluidAudioLiveModel.automatic.displayName)
        }
        return try await factory(backend(for: language))
    }
}
#endif
