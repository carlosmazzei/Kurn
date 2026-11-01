import KurnCore

extension FluidAudioModelTranscriber: PipelineTranscribing {
    func transcribe(_ request: EngineTranscriptionRequest) async throws -> RawTranscript {
        guard request.fluidAudioASRModel.supports(request.language) else {
            throw AppError.transcriptionLanguageUnsupported(request.language, .fluidAudioParakeet)
        }
        guard request.fluidAudioASRModel != .parakeetV3 else {
            return try await transcribe(
                url: request.url,
                language: request.language,
                model: request.fluidAudioASRModel,
                onProgress: { request.onProgress($0, nil) }
            )
        }
        try Task.checkCancellation()
        let chunker = AudioChunker(chunkDuration: 300)
        let chunks = try await chunker.chunkByDuration(url: request.url, cutPoints: request.cutPoints)
        defer { Task { await chunker.cleanup(chunks.filter { $0.url != request.url }) } }
        return try await ChunkedTranscriptionRunner.run(
            chunks: chunks,
            planDigest: PipelineDigest.sha256Hex(of: chunks.map(\.offset)),
            resume: request.resume,
            transcribeChunk: { chunk, index in
                try await self.transcribe(
                    url: chunk.url,
                    language: request.language,
                    model: request.fluidAudioASRModel,
                    onProgress: { fraction in
                        let overall = ChunkedProgress.overall(chunkIndex: index, fraction: fraction, total: chunks.count)
                        request.onProgress(overall.fraction, ChunkProgress(completed: index + 1, total: chunks.count))
                    }
                )
            },
            onChunkCompleted: request.onChunkCompleted,
            onProgress: { fraction, current, total in
                request.onProgress(fraction, ChunkProgress(completed: current, total: total))
            }
        )
    }
}

struct FluidAudioDiarizationRouter: PipelineDiarizing {
    var pyannote: @Sendable (PipelineDiarizationRequest) async -> DiarizationOutcome
    var nemotron: @Sendable (PipelineDiarizationRequest) async -> DiarizationOutcome

    func diarize(_ request: PipelineDiarizationRequest) async -> DiarizationOutcome {
        switch request.fluidAudioDiarizationModel {
        case .pyannote: await pyannote(request)
        case .nemotron3: await nemotron(request)
        }
    }
}
