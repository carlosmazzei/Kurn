import Foundation
import KurnCore

#if canImport(FluidAudio)
import FluidAudio
#endif

actor FluidAudioModelTranscriber {
    private let operations: FluidAudioRuntimePolicy.Operations

    init(operations: FluidAudioRuntimePolicy.Operations = .live) {
        self.operations = operations
    }

    func transcribe(
        url: URL,
        language: MeetingLanguage,
        model: FluidAudioASRModel,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> RawTranscript {
        try await FluidAudioRuntimePolicy.transcribe(
            url: url, language: language, model: model, operations: operations, onProgress: onProgress
        )
    }

    #if canImport(FluidAudio)
    static func transcribeUnified(url: URL, language: MeetingLanguage) async throws -> RawTranscript {
        guard let unifiedLanguage = FluidAudioASRModelRuntime.unifiedLanguage(for: language) else {
            throw AppError.transcriptionLanguageUnsupported(language, .fluidAudioParakeet)
        }
        return try await transcribeUnified(url: url, unifiedLanguage: unifiedLanguage)
    }

    static func transcript(from words: [FluidAudioStartTimedWord], duration: TimeInterval) throws -> RawTranscript {
        RawTranscript(spans: try FluidAudioWordTiming.spans(from: words, duration: duration), language: "")
    }

    static func transcript(from result: ASRResult) -> RawTranscript {
        let words = result.tokenTimings.map(buildWordTimings(from:)) ?? []
        return BatchTranscriptAssembly.transcript(
            text: result.text,
            words: words.map { TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime) },
            duration: result.duration
        )
    }
    #endif
}

extension FluidAudioRuntimePolicy.Operations {
    static var live: Self {
        let defaultTranscriber = FluidAudioTranscriber()
        return Self(
            isInstalled: { model in
                #if canImport(FluidAudio)
                return FluidAudioASRModelRuntime.isInstalled(model)
                #else
                return false
                #endif
            },
            requireHeadroom: { try await ResourceGuard.requireTranscriptionHeadroom() },
            transcribe: { url, language, model, onProgress in
                switch FluidAudioRuntimePolicy.backend(for: model) {
                case .parakeetV3:
                    return try await defaultTranscriber.transcribe(url: url, language: language, onProgress: onProgress)
                #if canImport(FluidAudio)
                case .tdt:
                    guard let version = FluidAudioASRModelRuntime.asrVersion(for: model) else {
                        throw AppError.transcriptionLanguageUnsupported(language, .fluidAudioParakeet)
                    }
                    return try await FluidAudioModelTranscriber.transcribeTDT(url: url, version: version, onProgress: onProgress)
                case .unified:
                    return try await FluidAudioModelTranscriber.transcribeUnified(url: url, language: language)
                case .transcribeLite:
                    return try await FluidAudioModelTranscriber.transcribeLite(url: url)
                #else
                case .tdt, .unified, .transcribeLite:
                    throw AppError.modelDownloadRequired(model.displayName)
                #endif
                }
            }
        )
    }
}
