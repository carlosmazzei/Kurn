import Foundation
import KurnCore
import Testing
@testable import Kurn

struct FluidAudioChunkedPipelineTests {
    private func request(url: URL, model: FluidAudioASRModel) -> EngineTranscriptionRequest {
        EngineTranscriptionRequest(
            url: url, language: .english, provider: .groq, model: "", transferPolicy: .wifiOnly,
            whisperCppModel: .default, cutPoints: [], resume: nil, onChunkCompleted: nil,
            onProgress: { _, _ in }, fluidAudioASRModel: model
        )
    }

    @Test(arguments: FluidAudioASRModel.allCases.filter { $0 != .parakeetV3 })
    func optionalModelsUseDurableChunkProgressWithoutOwningTheSource(model: FluidAudioASRModel) async throws {
        let url = try AudioFixtures.wav(segments: [(220, 3)])
        defer { try? FileManager.default.removeItem(at: url) }
        let checkpoints = Recorded<ChunkedTranscriptionRunner.Progress>()
        let fractions = Recorded<Double>()
        let calls = Recorded<FluidAudioASRModel>()
        let transcriber = FluidAudioModelTranscriber(operations: .init(
            isInstalled: { _ in true }, requireHeadroom: {},
            transcribe: { incomingURL, language, selected, onProgress in
                #expect(incomingURL == url)
                #expect(language == .english)
                calls.append(selected)
                onProgress(0.5)
                return RawTranscript(spans: [TranscribedSpan(text: "complete", start: 0.2, end: 1)], language: "en")
            }
        ))
        var input = request(url: url, model: model)
        input.onChunkCompleted = { checkpoints.append($0) }
        input.onProgress = { fraction, _ in fractions.append(fraction) }
        let result = try await transcriber.transcribe(input)
        #expect(calls.values == [model])
        #expect(result.spans.map(\.text) == ["complete"])
        #expect(checkpoints.values.map(\.completedChunks) == [1])
        #expect(checkpoints.values.first?.planDigest == PipelineDigest.sha256Hex(of: [Double(0)]))
        #expect(fractions.values.first == 0)
        #expect(fractions.values.last == 1)
        await Task.yield()
        #expect(FileManager.default.fileExists(atPath: url.path))
        var resumed = input
        resumed.resume = checkpoints.values.first
        resumed.onChunkCompleted = { _ in Issue.record("Completed progress must not be written as new work") }
        let retry = try await transcriber.transcribe(resumed)
        #expect(retry.spans == result.spans)
        #expect(calls.values == [model])
    }

    @Test func invalidLanguageFailsBeforeReadingAChunkOrStartingAModel() async {
        let transcriber = FluidAudioModelTranscriber(operations: .init(
            isInstalled: { _ in Issue.record("Unsupported language must not probe models"); return false },
            requireHeadroom: { Issue.record("Unsupported language must not prepare models") },
            transcribe: { _, _, _, _ in Issue.record("Must not transcribe"); return RawTranscript(spans: [], language: "") }
        ))
        var input = request(url: URL(fileURLWithPath: "/not-opened.wav"), model: .bark3)
        input.language = .portuguese
        await #expect(throws: AppError.self) { try await transcriber.transcribe(input) }
    }

    @Test func defaultModelKeepsItsExistingSinglePassContract() async throws {
        let checkpoints = Recorded<Int>()
        let transcriber = FluidAudioModelTranscriber(operations: .init(
            isInstalled: { _ in true }, requireHeadroom: {},
            transcribe: { _, _, selected, onProgress in
                #expect(selected == .parakeetV3)
                onProgress(1)
                return RawTranscript(spans: [TranscribedSpan(text: "legacy", start: 0, end: 1)], language: "en")
            }
        ))
        var input = request(url: URL(fileURLWithPath: "/not-opened.wav"), model: .parakeetV3)
        input.onChunkCompleted = { checkpoints.append($0.completedChunks) }
        let result = try await transcriber.transcribe(input)
        #expect(result.spans.first?.text == "legacy")
        #expect(checkpoints.values.isEmpty)
    }
}
