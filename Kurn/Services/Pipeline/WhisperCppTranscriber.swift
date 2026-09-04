//
//  WhisperCppTranscriber.swift
//  Kurn
//
//  Whisper running fully on device through whisper.cpp. Structurally this is the
//  local twin of `WhisperTranscriber`: the same `AudioChunker` +
//  `ChunkedTranscriptionRunner` loop, with the network upload replaced by a
//  `whisper_full` call over 16 kHz mono samples.
//
//  Chunking is not just inherited for symmetry — it is what keeps this usable on
//  a phone. `whisper_full` takes the whole clip as one `[Float]` array, so a two
//  hour meeting would mean ~460 MB of samples resident at once; five-minute
//  chunks cap that at ~19 MB, and bring resumable checkpoints and per-chunk
//  cancellation along for free.
//

import AVFoundation
import Foundation
import KurnCore

#if canImport(whisper)
import whisper

actor WhisperCppTranscriber: Transcribing {

    /// Sample rate whisper.cpp's mel front-end requires. Not configurable.
    private static let sampleRate: Double = 16_000

    /// Shorter than the cloud engine's 10-minute chunks: local inference has no
    /// per-request overhead to amortize, and smaller chunks bound peak memory
    /// and tighten cancellation/checkpoint granularity.
    private static let chunkDuration: TimeInterval = 300

    private let chunker = AudioChunker(chunkDuration: WhisperCppTranscriber.chunkDuration)

    /// The loaded model, kept between recordings — loading costs seconds and a
    /// full re-read of the weight file. Rebuilt when the user picks a different
    /// variant in Settings.
    private var context: WhisperContext?
    private var loadedModel: WhisperCppModel?

    func transcribe(
        url: URL,
        language: MeetingLanguage,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> RawTranscript {
        try await transcribeResumable(
            url: url,
            language: language,
            model: .default,
            onProgress: { progress, _, _ in onProgress(progress) }
        )
    }

    /// Chunked transcription that can resume from a persisted checkpoint, in the
    /// same shape as `WhisperTranscriber.transcribeResumable`.
    func transcribeResumable(
        url: URL,
        language: MeetingLanguage,
        model: WhisperCppModel,
        cutPoints: [TimeInterval] = [],
        resume: ChunkedTranscriptionRunner.Progress? = nil,
        onChunkCompleted: (@Sendable (ChunkedTranscriptionRunner.Progress) async throws -> Void)? = nil,
        onProgress: @escaping @Sendable (Double, Int, Int) -> Void = { _, _, _ in }
    ) async throws -> RawTranscript {
        let context = try loadedContext(for: model)

        let chunks = try await chunker.chunkByDuration(url: url, cutPoints: cutPoints)
        let total = chunks.count
        let planDigest = PipelineDigest.sha256Hex(of: chunks.map(\.offset))
        AppLog.transcription.atInfo.info(
            "whisperCpp: \(total, privacy: .public) chunk(s) with \(model.fileName, privacy: .public)"
        )
        defer { Task { await chunker.cleanup(chunks) } }

        return try await ChunkedTranscriptionRunner.run(
            chunks: chunks,
            planDigest: planDigest,
            resume: resume,
            transcribeChunk: { chunk, index in
                try await self.transcribeChunk(
                    chunk,
                    index: index,
                    of: total,
                    context: context,
                    language: language,
                    onProgress: onProgress
                )
            },
            onChunkCompleted: onChunkCompleted,
            onProgress: onProgress
        )
    }

    private func transcribeChunk(
        _ chunk: AudioChunker.Chunk,
        index: Int,
        of total: Int,
        context: WhisperContext,
        language: MeetingLanguage,
        onProgress: @escaping @Sendable (Double, Int, Int) -> Void
    ) async throws -> RawTranscript {
        try await ResourceGuard.requireTranscriptionHeadroom()
        let samples = try VADAudioLoader.monoSamples(url: chunk.url, sampleRate: Self.sampleRate)
        guard !samples.isEmpty else {
            AppLog.transcription.atInfo.info(
                "whisperCpp: chunk \(index + 1, privacy: .public)/\(total, privacy: .public) decoded to no samples"
            )
            return RawTranscript(spans: [], language: "")
        }

        let started = Date()
        // Map whisper's within-chunk progress into this chunk's slice of the
        // overall bar, so a single long chunk still advances visibly.
        let chunkProgress: @Sendable (Double) -> Void = { fraction in
            let overall = (Double(index) + min(1, max(0, fraction))) / Double(max(1, total))
            onProgress(overall, min(total, index + 1), total)
        }

        let result = try await context.transcribe(
            samples: samples,
            language: language.whisperCode,
            onProgress: chunkProgress
        )
        AppLog.transcription.atNotice.notice(
            "whisperCpp: chunk \(index + 1, privacy: .public)/\(total, privacy: .public) done in \(Int(Date().timeIntervalSince(started)), privacy: .public)s, spans=\(result.spans.count, privacy: .public) lang=\(result.language, privacy: .public)"
        )
        try await ResourceGuard.requireTranscriptionHeadroom()
        return result
    }

    /// Proves a downloaded weight file actually loads, without keeping the
    /// context around — used by `WhisperCppModelDownloader` right after
    /// install (H7 PR 16) so a corrupt/truncated file is caught immediately
    /// instead of waiting for the first real transcription to fail.
    /// `WhisperContext.init` is a blocking C call, so this runs detached
    /// rather than on whatever actor happened to call it.
    static func verifyModelLoads(at path: URL) async throws {
        // H8 PR 17: same global weight budget as a real transcription's
        // load, so a health probe racing an in-flight transcription can't
        // stack memory with it either.
        try await withResourceReservation(.modelLoading) {
            try await Task.detached(priority: .utility) {
                _ = try WhisperContext(modelPath: path.path)
            }.value
        }
    }

    private func loadedContext(for model: WhisperCppModel) throws -> WhisperContext {
        if let context, loadedModel == model { return context }
        // Dropping the old context frees its weights before the new ones are
        // read, so switching variants never holds two models in memory.
        self.context = nil
        loadedModel = nil

        let path = WhisperCppModelDownloader.fileURL(for: model)
        guard ModelSet.whisperCppASR(model).isInstalled else {
            AppLog.transcription.atError.error(
                "whisperCpp: model \(model.fileName, privacy: .public) is not installed"
            )
            throw AppError.modelDownloadRequired(model.displayName)
        }
        let created = try WhisperContext(modelPath: path.path)
        context = created
        loadedModel = model
        AppLog.transcription.atNotice.notice(
            "whisperCpp: loaded \(model.fileName, privacy: .public)"
        )
        return created
    }
}

/// Owns one `whisper_context`. The pointer and every C call live on a private
/// serial queue: `whisper_full` blocks for as long as inference takes, which
/// must not happen on a Swift concurrency cooperative thread.
private final class WhisperContext: @unchecked Sendable {

    private let context: OpaquePointer
    private let queue = DispatchQueue(label: "ai.kurn.whispercpp", qos: .userInitiated)

    init(modelPath: String) throws {
        var params = whisper_context_default_params()
        // Metal on a device is the difference between real-time-ish and unusably
        // slow. In the iOS Simulator ggml can still init a Metal backend, but
        // the emulated GPU lacks the features whisper.cpp actually needs and the
        // context crashes mid-inference; force CPU there so CI and local
        // simulator runs can exercise the transcription path.
        #if targetEnvironment(simulator)
        params.use_gpu = false
        params.flash_attn = false
        #else
        params.use_gpu = true
        params.flash_attn = true
        #endif
        guard let context = whisper_init_from_file_with_params(modelPath, params) else {
            throw AppError.transcriptionFailed(
                NSLocalizedString("error.whisper_cpp_load_failed", comment: "whisper.cpp model failed to load")
            )
        }
        self.context = context
    }

    deinit {
        whisper_free(context)
    }

    /// Run the model over `samples` (16 kHz mono float). `language` is a
    /// two-letter Whisper code, or `nil` to let the model detect it.
    func transcribe(
        samples: [Float],
        language: String?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> RawTranscript {
        let callbacks = CallbackBox(onProgress: onProgress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        let transcript = try run(samples: samples, language: language, callbacks: callbacks)
                        continuation.resume(returning: transcript)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            // Read by `abort_callback` on ggml's compute threads, which unwinds
            // `whisper_full` at the next graph boundary instead of waiting out
            // the rest of the chunk.
            callbacks.cancel()
        }
    }

    private func run(samples: [Float], language: String?, callbacks: CallbackBox) throws -> RawTranscript {
        dispatchPrecondition(condition: .onQueue(queue))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        // Leave one core for the rest of the app; whisper saturates whatever it
        // is given and the UI still has to render a progress bar.
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        params.translate = false
        params.no_timestamps = false
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        // The chunk loop already feeds windows in order but each chunk is an
        // independent clip, so previous-chunk text must not condition it.
        params.no_context = true
        params.single_segment = false
        params.suppress_blank = true
        // Per-token bounds, which `words(inSegment:)` aggregates into words. The
        // segment bounds alone put a whole sentence on one speaker, so a handover
        // mid-sentence could only ever be estimated.
        params.token_timestamps = true
        // whisper.cpp runs its own temperature fallback against these, retrying a
        // window that decoded badly before giving up on it. They already default
        // to these values; setting them from the filter's constants keeps the
        // retry and the post-filter judging a segment by the same numbers.
        params.logprob_thold = Float(TranscriptQualityFilter.minimumAverageLogProb)
        params.no_speech_thold = Float(TranscriptQualityFilter.maximumNoSpeechProb)
        params.entropy_thold = Float(TranscriptQualityFilter.maximumCompressionRatio)

        let user = Unmanaged.passUnretained(callbacks).toOpaque()
        params.progress_callback_user_data = user
        params.progress_callback = { _, _, progress, userData in
            guard let userData else { return }
            Unmanaged<CallbackBox>.fromOpaque(userData)
                .takeUnretainedValue()
                .report(Double(progress) / 100.0)
        }
        params.abort_callback_user_data = user
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<CallbackBox>.fromOpaque(userData)
                .takeUnretainedValue()
                .isCancelled
        }

        // `language` must outlive `whisper_full`, so keep the C string alive for
        // the whole call rather than letting a temporary bridge dangle.
        let status = withLanguage(language, params: params) { params in
            samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            }
        }

        if callbacks.isCancelled { throw CancellationError() }
        guard status == 0 else {
            throw AppError.transcriptionFailed(
                NSLocalizedString("error.whisper_cpp_failed", comment: "whisper.cpp inference failed")
            )
        }
        return RawTranscript(spans: spans(), language: detectedLanguage())
    }

    /// Invoke `body` with `params.language` pointing at a C string that stays
    /// valid for the whole call. A bridged Swift `String` would otherwise be
    /// freed before `whisper_full` reads it.
    private func withLanguage(
        _ language: String?,
        params: whisper_full_params,
        body: (whisper_full_params) -> Int32
    ) -> Int32 {
        guard let language else {
            // A null language means auto-detect. whisper.cpp already
            // auto-detects language as part of the normal transcription pass
            // when `language` is nil — `detect_language` is a detect-only
            // switch that makes `whisper_full` return before transcribing.
            var scoped = params
            scoped.language = nil
            scoped.detect_language = false
            return body(scoped)
        }
        return language.withCString { pointer in
            var scoped = params
            scoped.language = pointer
            scoped.detect_language = false
            return body(scoped)
        }
    }

    private func spans() -> [TranscribedSpan] {
        var scored: [TranscriptQualityFilter.ScoredSpan] = []
        for index in 0..<whisper_full_n_segments(context) {
            guard let raw = whisper_full_get_segment_text(context, index) else { continue }
            let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // whisper reports segment bounds in centiseconds.
            let start = Double(whisper_full_get_segment_t0(context, index)) / 100
            let end = Double(whisper_full_get_segment_t1(context, index)) / 100
            scored.append(
                TranscriptQualityFilter.ScoredSpan(
                    span: TranscribedSpan(
                        text: text,
                        start: start,
                        end: max(start, end),
                        confidence: nil
                    ),
                    quality: quality(ofSegment: index),
                    words: words(inSegment: index)
                )
            )
        }
        return TranscriptQualityFilter.keeping(scored, engine: "whisperCpp")
    }

    /// The decoder's confidence in one segment.
    ///
    /// There is no local equivalent of the cloud's `compression_ratio`, so that
    /// field stays `nil` and the filter's own repetition test is what catches a
    /// loop here.
    private func quality(ofSegment index: Int32) -> SpanQuality {
        let noSpeech = Double(whisper_full_get_segment_no_speech_prob(context, index))

        // Whisper's `avg_logprob` is the mean over *text* tokens. Everything from
        // `whisper_token_eot` upwards is a control or timestamp token — near
        // certain by construction, and counting them would flatter the average
        // towards zero on every segment equally.
        var total = 0.0
        var count = 0
        forEachTextToken(inSegment: index) { token, _ in
            let probability = Double(whisper_full_get_token_p(context, index, token))
            guard probability.isFinite else { return }
            total += log(max(probability, 1e-10))
            count += 1
        }

        return SpanQuality(
            averageLogProb: count > 0 ? total / Double(count) : nil,
            noSpeechProb: noSpeech.isFinite ? noSpeech : nil,
            compressionRatio: nil
        )
    }

    /// Word timings for one segment, aggregated from the model's sub-word tokens.
    ///
    /// Whisper emits SentencePiece pieces, not words: "orçamento" can arrive as
    /// "or", "ça", "mento". A piece that begins with a space opens a new word and
    /// every piece after it extends that word, which is the same rule the
    /// tokenizer used to produce them. Sub-word timings are what
    /// `TranscriptFusion` needs to place a speaker handover *inside* a sentence
    /// rather than estimating where it fell.
    private func words(inSegment index: Int32) -> [TimedWord] {
        var words: [TimedWord] = []
        forEachTextToken(inSegment: index) { token, _ in
            guard let raw = whisper_full_get_token_text(context, index, token) else { return }
            let piece = String(cString: raw)
            let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            // Token bounds are centiseconds from the start of this chunk, the
            // same origin the segment bounds use, so the chunk runner's offset
            // correction applies to both without further work.
            let data = whisper_full_get_token_data(context, index, token)
            let start = Double(data.t0) / 100
            let end = Double(data.t1) / 100
            guard start.isFinite, end.isFinite else { return }

            if piece.first?.isWhitespace == true || words.isEmpty {
                words.append(TimedWord(text: text, start: start, end: max(start, end)))
            } else {
                words[words.count - 1].text += text
                words[words.count - 1].end = max(words[words.count - 1].end, end)
            }
        }
        return words
    }

    /// Visit the tokens of a segment that carry text, skipping control and
    /// timestamp tokens.
    private func forEachTextToken(inSegment index: Int32, _ body: (Int32, whisper_token) -> Void) {
        let firstSpecialToken = whisper_token_eot(context)
        for token in 0..<whisper_full_n_tokens(context, index) {
            let id = whisper_full_get_token_id(context, index, token)
            guard id < firstSpecialToken else { continue }
            body(token, id)
        }
    }

    private func detectedLanguage() -> String {
        let id = whisper_full_lang_id(context)
        guard id >= 0, let raw = whisper_lang_str(id) else { return "" }
        return String(cString: raw)
    }
}

/// Reference box handed to whisper.cpp's C callbacks as `user_data`. The
/// callbacks fire on ggml's own compute threads, so both fields are guarded.
private final class CallbackBox: @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var cancelled = false

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func report(_ fraction: Double) {
        onProgress(min(1, max(0, fraction)))
    }
}

#else

/// Built without the whisper.cpp package linked (as in the test target): the
/// on-device Whisper engine is unavailable and says so rather than failing
/// somewhere deeper in the pipeline.
actor WhisperCppTranscriber: Transcribing {
    /// Nothing to verify without the package linked (as in `KurnTests`) — a
    /// no-op rather than a throw, since `WhisperCppModelDownloader.download`
    /// must still succeed in this configuration (it only fetches bytes, and
    /// never links `whisper` itself).
    static func verifyModelLoads(at path: URL) async throws {}

    func transcribe(
        url: URL,
        language: MeetingLanguage,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> RawTranscript {
        throw AppError.transcriptionFailed(
            NSLocalizedString("settings.whisper_cpp.package_missing", comment: "whisper.cpp package missing")
        )
    }

    func transcribeResumable(
        url: URL,
        language: MeetingLanguage,
        model: WhisperCppModel,
        cutPoints: [TimeInterval] = [],
        resume: ChunkedTranscriptionRunner.Progress? = nil,
        onChunkCompleted: (@Sendable (ChunkedTranscriptionRunner.Progress) async throws -> Void)? = nil,
        onProgress: @escaping @Sendable (Double, Int, Int) -> Void = { _, _, _ in }
    ) async throws -> RawTranscript {
        throw AppError.transcriptionFailed(
            NSLocalizedString("settings.whisper_cpp.package_missing", comment: "whisper.cpp package missing")
        )
    }
}

#endif
