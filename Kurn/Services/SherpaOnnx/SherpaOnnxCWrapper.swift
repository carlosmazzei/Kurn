//
//  SherpaOnnxCWrapper.swift
//  Kurn
//
//  Thin Swift wrapper over sherpa-onnx's C speaker-diarization API, adapted
//  from the project's own official example
//  (`swift-api-examples/SherpaOnnx.swift` in k2-fsa/sherpa-onnx) rather than
//  written from scratch against the raw C API. Kept to exactly the
//  diarization surface this app uses — the upstream file also wraps ASR/TTS/
//  VAD, none of which belong here.
//
//  Guarded by `SHERPA_ONNX_ENABLED`, a compilation condition that is NOT yet
//  set anywhere in the Xcode project — see `SherpaOnnxDiarizer.swift` for
//  why, and what remains to turn this on. The `#else` branch keeps this file
//  a harmless no-op until then, and `KurnTests` (which never gets the
//  bridging header) always takes it.
//

import Foundation

#if SHERPA_ONNX_ENABLED

/// Swift-friendly mirror of `SherpaOnnxOfflineSpeakerDiarizationSegment`
/// (start/end in seconds, 0-indexed speaker id in first-appearance order).
struct SherpaOnnxDiarizationSegmentWrapper {
    var start: Float
    var end: Float
    var speaker: Int
}

/// Owns the lifetime of a `SherpaOnnxOfflineSpeakerDiarization` C handle.
/// `numSpeakers > 0` pins an exact count (re-clusters); `0` lets the
/// pipeline's own clustering decide.
///
/// `@unchecked Sendable`: the handle is an opaque C pointer with no Swift
/// concurrency annotations of its own. `SherpaOnnxDiarizer` only ever calls
/// into one instance from a single task at a time (built, used, and released
/// within one `diarize(url:)` call), so there is no real aliasing risk —
/// same reasoning `FluidAudioDiarizer` uses for its own non-`Sendable`
/// `OfflineDiarizerManager`.
final class SherpaOnnxOfflineSpeakerDiarizationWrapper: @unchecked Sendable {
    private let handle: OpaquePointer

    init?(segmentationModelPath: String, embeddingModelPath: String, numSpeakers: Int32, numThreads: Int32) {
        // The config struct only holds the C strings' addresses, not copies,
        // so every `const char *` it references must stay alive for the
        // duration of the `SherpaOnnxCreateOfflineSpeakerDiarization` call
        // itself — hence calling it from inside the innermost `withCString`,
        // not after the nesting closes.
        let created: OpaquePointer? = segmentationModelPath.withCString { segPtr in
            embeddingModelPath.withCString { embPtr in
                "cpu".withCString { providerPtr in
                    var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
                    config.segmentation.pyannote.model = segPtr
                    config.segmentation.pyannote.window_shift_ratio = 0.1
                    config.segmentation.num_threads = numThreads
                    config.segmentation.provider = providerPtr
                    config.embedding.model = embPtr
                    config.embedding.num_threads = numThreads
                    config.embedding.provider = providerPtr
                    config.clustering.num_clusters = numSpeakers
                    config.clustering.threshold = 0.5
                    config.min_duration_on = 0.3
                    config.min_duration_off = 0.5
                    return SherpaOnnxCreateOfflineSpeakerDiarization(&config)
                }
            }
        }
        guard let created else { return nil }
        handle = created
    }

    deinit {
        SherpaOnnxDestroyOfflineSpeakerDiarization(handle)
    }

    /// The sample rate this instance's models expect. Audio handed to
    /// `process(samples:)` must already be resampled to this rate.
    var sampleRate: Int {
        Int(SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(handle))
    }

    /// Runs the whole-clip pipeline synchronously: segmentation, embedding,
    /// clustering. No progress callback exists in the C API for this call —
    /// callers report progress coarsely around it, same as the heuristic
    /// engine does.
    func process(samples: [Float]) -> [SherpaOnnxDiarizationSegmentWrapper] {
        guard let result = samples.withUnsafeBufferPointer({ buffer in
            SherpaOnnxOfflineSpeakerDiarizationProcess(handle, buffer.baseAddress, Int32(buffer.count))
        }) else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }

        let numSegments = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
        guard let resultSegments = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(resultSegments) }

        var segments: [SherpaOnnxDiarizationSegmentWrapper] = []
        segments.reserveCapacity(numSegments)
        for index in 0..<numSegments {
            let raw = resultSegments[index]
            segments.append(SherpaOnnxDiarizationSegmentWrapper(
                start: raw.start,
                end: raw.end,
                speaker: Int(raw.speaker)
            ))
        }
        return segments
    }
}

#endif
