import Foundation
import KurnCore
import Testing
@testable import Kurn

struct FluidAudioModelTranscriberTests {
    private let url = URL(fileURLWithPath: "/never-opened.m4a")

    @Test(arguments: FluidAudioASRModel.allCases)
    func installedModelsForwardTheExactRequestAndProgress(model: FluidAudioASRModel) async throws {
        let calls = Recorded<String>()
        let progress = Recorded<Double>()
        let expectedURL = url
        let transcriber = FluidAudioModelTranscriber(operations: .init(
            isInstalled: { selected in
                calls.append("installed:\(selected.rawValue)")
                return true
            },
            requireHeadroom: { calls.append("headroom") },
            transcribe: { url, language, selected, onProgress in
                #expect(url == expectedURL)
                #expect(language == .english)
                #expect(selected == model)
                calls.append("transcribe")
                onProgress(0.4)
                return RawTranscript(spans: [TranscribedSpan(text: "word", start: 0.2, end: 1)], language: "")
            }
        ))
        let result = try await transcriber.transcribe(url: url, language: .english, model: model) { progress.append($0) }
        #expect(calls.values == ["installed:\(model.rawValue)", "headroom", "transcribe", "headroom"])
        #expect(progress.values == [0.4])
        #expect(result.spans.map(\.text) == ["word"])
        #expect(result.language.isEmpty)
        #expect(result.speakerTurns == nil)
    }

    @Test func theProductionAdapterRejectsUnsupportedLanguageBeforeAnyModelWork() async {
        let transcriber = FluidAudioModelTranscriber()
        await #expect {
            _ = try await transcriber.transcribe(url: url, language: .portuguese, model: .bark3)
        } throws: { error in
            if case .transcriptionLanguageUnsupported = error as? AppError { return true }
            return false
        }
    }

    @Test func unsupportedLanguageDoesNotProbeOrLoadAModel() async {
        let transcriber = FluidAudioModelTranscriber(operations: forbiddenOperations)
        await #expect {
            _ = try await transcriber.transcribe(url: url, language: .portuguese, model: .nemotronTranscribeLite)
        } throws: { error in
            if case .transcriptionLanguageUnsupported(.portuguese, .fluidAudioParakeet) = error as? AppError { return true }
            return false
        }
    }

    @Test(arguments: FluidAudioASRModel.allCases)
    func missingModelsIncludingTheDefaultNeverLoad(model: FluidAudioASRModel) async {
        var operations = forbiddenOperations
        operations.isInstalled = { _ in false }
        let transcriber = FluidAudioModelTranscriber(operations: operations)
        await #expect {
            _ = try await transcriber.transcribe(url: url, language: .english, model: model)
        } throws: { error in
            if case .modelDownloadRequired = error as? AppError { return true }
            return false
        }
    }

    @Test func preflightHeadroomFailurePreventsLoading() async {
        var operations = forbiddenOperations
        operations.isInstalled = { _ in true }
        operations.requireHeadroom = { throw AppError.resourceUnavailable("capacity") }
        let transcriber = FluidAudioModelTranscriber(operations: operations)
        await #expect {
            _ = try await transcriber.transcribe(url: url, language: .english, model: .bark3)
        } throws: { error in
            if case .resourceUnavailable("capacity") = error as? AppError { return true }
            return false
        }
    }

    @Test func postflightHeadroomFailureIsPreserved() async {
        let checks = FluidAudioHeadroomChecks()
        let transcriber = FluidAudioModelTranscriber(operations: .init(
            isInstalled: { _ in true },
            requireHeadroom: { try await checks.requireHeadroom() },
            transcribe: { _, _, _, _ in RawTranscript(spans: [], language: "") }
        ))
        await #expect {
            _ = try await transcriber.transcribe(url: url, language: .english, model: .phonon2)
        } throws: { error in
            if case .resourceUnavailable("after transcription") = error as? AppError { return true }
            return false
        }
    }

    @Test func typedFailuresAreNotReplacedWithGenericErrors() async {
        let transcriber = failingTranscriber { throw AppError.modelDownloadRequired("selected") }
        await #expect {
            _ = try await transcriber.transcribe(url: url, language: .english, model: .bark3Clean)
        } throws: { error in
            if case .modelDownloadRequired("selected") = error as? AppError { return true }
            return false
        }
    }

    @Test func frameworkFailuresBecomeLocalizedTranscriptionFailures() async {
        let transcriber = failingTranscriber { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed"]) }
        await #expect {
            _ = try await transcriber.transcribe(url: url, language: .english, model: .bark3)
        } throws: { error in
            if case .transcriptionFailed("failed") = error as? AppError { return true }
            return false
        }
    }

    @Test func diskPressureFromTheFrameworkKeepsItsRecoverableError() async {
        let transcriber = failingTranscriber { throw CocoaError(.fileWriteOutOfSpace) }
        await #expect {
            _ = try await transcriber.transcribe(url: url, language: .english, model: .bark3)
        } throws: { error in
            if case .resourceUnavailable = error as? AppError { return true }
            return false
        }
    }

    @Test func cancellationFromTheRuntimeIsPreserved() async {
        let transcriber = failingTranscriber { throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            _ = try await transcriber.transcribe(url: url, language: .english, model: .nemotronUnified)
        }
    }

    @Test func cancelledCallsNeverLoadModels() async {
        var operations = forbiddenOperations
        operations.isInstalled = { _ in true }
        let transcriber = FluidAudioModelTranscriber(operations: operations)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transcriber.transcribe(url: url, language: .english, model: .bark3)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func cancellationAfterTheRuntimeReturnsStillCancelsTheCall() async {
        let transcriber = failingTranscriber {
            withUnsafeCurrentTask { $0?.cancel() }
            return RawTranscript(spans: [], language: "")
        }
        let task = Task { try await transcriber.transcribe(url: url, language: .english, model: .bark3) }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    private var forbiddenOperations: FluidAudioRuntimePolicy.Operations {
        .init(
            isInstalled: { _ in Issue.record("Installation must not be checked"); return false },
            requireHeadroom: { Issue.record("Headroom must not be checked") },
            transcribe: { _, _, _, _ in
                Issue.record("No transcription or model loading is allowed")
                return RawTranscript(spans: [], language: "")
            }
        )
    }

    private func failingTranscriber(
        _ run: @escaping @Sendable () async throws -> RawTranscript
    ) -> FluidAudioModelTranscriber {
        FluidAudioModelTranscriber(operations: .init(
            isInstalled: { _ in true }, requireHeadroom: {}, transcribe: { _, _, _, _ in try await run() }
        ))
    }
}

private actor FluidAudioHeadroomChecks {
    private var count = 0

    func requireHeadroom() throws {
        count += 1
        if count == 2 { throw AppError.resourceUnavailable("after transcription") }
    }
}
