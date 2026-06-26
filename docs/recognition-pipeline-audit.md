# Recognition Pipeline — Best-Practices Audit

_Scope: the audio recognition pipeline — capture, preprocessing, VAD, language
detection, transcription (Apple Speech / FluidAudio Parakeet / OpenAI Whisper),
diarization, and span→segment fusion._

## Verdict

The pipeline is well-architected and largely follows Swift 6 / iOS best
practices. The findings below separate what is already solid from the two gaps
addressed in this change, plus items intentionally deferred.

## What is already solid

- **Protocol seams per stage** (`Services/Pipeline/PipelineStages.swift`):
  `AudioPreprocessing`, `VoiceActivityDetecting`, `LanguageDetecting`,
  `Transcribing`, `Diarizing`. Engines are swappable without touching the
  orchestrator, and `PipelineConfiguration` selects them declaratively.
- **Concurrency discipline.** Services are `Sendable` value types or actors;
  non-`Sendable` audio resources (`AVAudioEngine`, `SFSpeechRecognitionTask`,
  `AVAssetExportSession`, FluidAudio managers) stay isolated inside actors.
  Continuation safety is handled with single-resume guards (`ResumeBox`,
  `ExportBox`). Progress/warning callbacks are passed as per-call arguments
  rather than stored on shared actor state, so concurrent transcriptions can't
  leak one call's handler into another.
- **Concurrent independent stages.** Transcription and diarization read the same
  file independently and run via `async let` (`TranscriptionService` step 4).
- **Graceful degradation everywhere.** Preprocessing failure → original audio;
  VAD failure → whole-clip region; language detection failure → unchanged hint;
  diarization failure → single "Speaker 1" turn; VAD compaction not worthwhile →
  original audio with identity timeline. Transcription "never breaks" on a
  non-core stage failure.
- **Timeout safety nets** on long on-device work (Apple Speech `max(60, dur*4)`,
  FluidAudio VAD/diarizer via `withThrowingTaskGroup` races).
- **Sensible audio handling.** `.playAndRecord`, interruption/route-change
  auto-pause, lock-guarded render-thread sink, mono-16 kHz normalization for the
  speech engines, VAD silence-gating to cut cost and hallucination, and chunked
  Whisper upload with timestamp offsetting back to absolute meeting time.

## Gaps fixed in this change

1. **No retry/backoff on transient network failures.** Every cloud call (Whisper
   transcription and all summary/model-list providers) funneled through
   `LLMHTTP.send`, a single attempt. A momentary connectivity blip or a transient
   `429/500/502/503/504` failed the whole operation with no recovery.
   - **Fix:** `LLMHTTP.sendValidated(_:session:)` now wraps send+validate with
     exponential backoff + jitter, retrying only transient transport
     (`URLError`) and server status codes, honoring `Retry-After`, capped at
     `maxAttempts`. The decision is a pure, unit-tested function
     (`LLMHTTP.retryableDelay(...)`). All providers were migrated to it.

2. **Untested orchestration core.** The span→speaker attribution and
   same-speaker merge/split logic — central to multi-speaker output — was
   `private` inside `TranscriptionService` with zero tests.
   - **Fix:** extracted to the pure `TranscriptFusion` value type
     (`Services/Pipeline/TranscriptFusion.swift`) and covered by
     `KurnTests/TranscriptFusionTests.swift`. No behavioral change.

## Deferred (intentionally not done)

- **Parallel Whisper chunk uploads.** Uploads are sequential. Parallelizing risks
  rate-limit pressure, higher peak memory, and ordering complexity for a marginal
  wall-clock gain on the multi-chunk (>20 MB / >10 min) path only. Revisit if
  long-recording latency becomes a real complaint.
- **Hand-built multipart body** in `OpenAIProvider`. It is correct today; a
  rewrite carries risk without functional benefit.
- **Single-chunk Whisper progress is indeterminate.** Progress only advances
  across multiple chunks; a single chunk stays at "in progress" until done. A
  time-based estimate could improve UX but is cosmetic.
- **Engine-level integration tests** (Apple Speech / FluidAudio / live streaming)
  require device models or real API keys and don't fit the in-memory unit-test
  setup; they remain a coverage gap to address with fixtures/mocks later.
