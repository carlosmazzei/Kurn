import Foundation
import KurnCore

enum FluidAudioRuntimePolicy {
    enum Backend: Sendable {
        case parakeetV3
        case tdt
        case unified
        case transcribeLite
    }

    static func backend(for model: FluidAudioASRModel) -> Backend {
        switch model {
        case .parakeetV3: return .parakeetV3
        case .bark3, .bark3Clean, .phonon2: return .tdt
        case .nemotronUnified: return .unified
        case .nemotronTranscribeLite: return .transcribeLite
        }
    }

    typealias Transcription = @Sendable (
        URL, MeetingLanguage, FluidAudioASRModel, @escaping @Sendable (Double) -> Void
    ) async throws -> RawTranscript

    struct Operations: Sendable {
        var isInstalled: @Sendable (FluidAudioASRModel) -> Bool
        var requireHeadroom: @Sendable () async throws -> Void
        var transcribe: Transcription
    }

    static let compiledModelMarker = "coremldata.bin"

    static func unifiedLanguageCode(for language: MeetingLanguage) -> String {
        language.whisperCode ?? "auto"
    }

    static func modelContents(at path: String) -> [String]? {
        try? FileManager.default.subpathsOfDirectory(atPath: path)
    }

    static func missingFiles(
        _ required: some Sequence<String>,
        in directory: URL,
        enumerate: (String) -> [String]? = modelContents,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String] {
        required.filter { file in
            let url = directory.appendingPathComponent(file)
            guard file.hasSuffix(".mlmodelc") else { return !fileExists(url.path) }
            guard fileExists(url.appendingPathComponent(compiledModelMarker).path),
                  let contents = enumerate(url.path) else { return true }
            return contents.contains { $0.hasSuffix(".partial") }
        }.sorted()
    }

    static func validate(
        model: FluidAudioASRModel,
        language: MeetingLanguage,
        isInstalled: @autoclosure () -> Bool
    ) throws {
        guard model.supports(language) else {
            throw AppError.transcriptionLanguageUnsupported(language, .fluidAudioParakeet)
        }
        guard isInstalled() else {
            throw AppError.modelDownloadRequired(model.displayName)
        }
    }

    static func transcribe(
        url: URL,
        language: MeetingLanguage,
        model: FluidAudioASRModel,
        operations: Operations,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> RawTranscript {
        try validate(model: model, language: language, isInstalled: operations.isInstalled(model))
        try Task.checkCancellation()
        try await operations.requireHeadroom()
        do {
            let transcript = try await operations.transcribe(url, language, model, onProgress)
            try Task.checkCancellation()
            try await operations.requireHeadroom()
            return transcript
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let resourceError = ResourceGuard.appErrorIfResourceFailure(error) { throw resourceError }
            throw AppError.transcriptionFailed(error.localizedDescription)
        }
    }
}
