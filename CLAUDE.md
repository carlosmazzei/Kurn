# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Kurn is a local-first iOS + watchOS app (Swift 6, SwiftUI, SwiftData) for recording
meetings, transcribing audio, diarizing speakers, and generating structured AI
summaries. Everything is stored on device; network calls happen only when the user
opts into cloud (Whisper-compatible) transcription or a cloud summary provider.

There is no Swift Package or `Package.swift` — the project is an Xcode project
(`Kurn.xcodeproj`) with three targets: `Kurn` (app), `KurnWatch` (watchOS companion),
and `KurnLiveActivityExtension` (widget/Live Activity). Tests live in `KurnTests`
(Swift Testing, not XCTest).

## Commands

Builds/tests require macOS with Xcode 16+. CI uses `iPhone 17` as the simulator
destination (see `.github/workflows/swift.yml`); substitute an installed simulator
name locally if needed.

```bash
# Build
xcodebuild -project Kurn.xcodeproj -scheme Kurn \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# Run all tests
xcodebuild -project Kurn.xcodeproj -scheme Kurn \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

# Run a single test (Swift Testing uses -only-testing:Target/Suite/test)
xcodebuild -project Kurn.xcodeproj -scheme Kurn \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:KurnTests/SummaryJSONParsingTests

# Lint (must pass before build in CI)
swiftlint lint --config .swiftlint.yml
```

If `xcodebuild`/SwiftLint can't find SourceKit, point the toolchain at Xcode:
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

### Releasing

`fastlane/Fastfile` has two lanes: `bump_version type:{patch,minor,major}` bumps
`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` across all targets via direct text
substitution on `project.pbxproj` (not `increment_version_number`/`xcodeproj`,
which reorder unrelated parts of this file because it uses Xcode 16
file-system-synchronized groups), then commits, tags `vX.Y.Z`, and pushes —
run locally by a maintainer. Pushing that tag triggers the `release` job in
`.github/workflows/swift.yml` (gated with `if: startsWith(github.ref,
'refs/tags/v')`, `needs: build-and-test` so it only runs after the same
lint/build/test job that gates every push/PR), which runs the CI-only
`github_release` lane to publish a GitHub Release. No signing/archiving/
TestFlight upload is wired up yet.

SwiftLint limits worth knowing before adding code: file length warns at 600 lines,
function body at 120, cyclomatic complexity at 15, type body at 400.

### Verifying without a local macOS/Xcode toolchain

Builds and tests require macOS + Xcode, so they can't run in Linux/CI agents or
any environment without the Apple toolchain. When you cannot build or test
locally, **do not claim a change compiles or passes — verify it through the
GitHub Actions `iOS CI` workflow** (`.github/workflows/swift.yml`), which builds,
lints, and runs the full test suite on a macOS runner:

- Push the change to its branch and open (or update) a PR targeting `main` — the
  `pull_request` trigger runs the workflow. Pushing to a feature branch alone
  does **not** trigger CI; only `push` to `main` and PRs to `main` do.
- Read the run's outcome with the GitHub Actions tooling/API: fetch the
  `build-and-test` job logs and grep for `error:` (compile failures),
  `recorded an issue` / `** TEST FAILED **` (test failures), and the final
  result line. Treat a green run as the source of truth that it compiles and
  passes.
- Iterate against CI: each fix can surface the next latent error (the Swift
  build stops at the first error), so expect several rounds. State plainly that
  results are pending/observed from CI rather than asserting local success.

## Architecture

MVVM with `@Observable` `@MainActor` view models, value-type async services, and a
single app-wide SwiftData `ModelContainer`. The layers (under `Kurn/`):

- **Models/** — SwiftData `@Model` classes (`Meeting`, `Recording`, `Transcript`,
  `Speaker`, `Summary`, `Tag`, `Folder`, `SmartFolder`) plus shared value types
  (`Enums.swift`, `MeetingFilter`, `TranscriptionCheckpoint`, `FolderCatalog`,
  `SummarySection`, `SummaryTemplate`).
- **Services/** — audio capture, transcription pipeline (`Services/Pipeline/`),
  on-device FluidAudio engines, diarization, live transcription preview,
  summaries, folder analytics, auto-tagging. These are mostly `struct`/`actor`
  types operating on plain values so they stay decoupled from SwiftData and
  safe off the main actor.
- **Providers/** — cloud LLM clients behind the `LLMProvider` protocol.
- **ViewModels/** — `@MainActor @Observable` coordinators owning services and
  persisting results.
- **Views/** — SwiftUI screens.
- **Infrastructure/** — settings, errors, logging, keychain, export, extensions.

### Data model

`Meeting` is the aggregate root. It cascades deletes to its `recordings`,
`speakers`, and `summary`. Key persistence convention: **SwiftData can't store
arbitrary `Codable` arrays**, so `Transcript.segments` (`[TranscriptSegment]`) and
similar collections are encoded to/from JSON `Data` via computed properties
(`Transcript.segmentsData`). Relationships are set by assigning the parent (e.g.
`Recording(meeting:)`) — SwiftData maintains the inverse, so never append to the
parent collection manually. `Recording.transcriptionCheckpointData` uses the same
JSON-`Data` pattern to persist a `TranscriptionCheckpoint` (see "Resumable
transcription" below).

Organization is layered on top of `Meeting` rather than replacing the aggregate
root:

- `isFavorite: Bool` and `archivedAt: Date?` (`isArchived`) are plain fields on
  `Meeting`; `MeetingsLibraryBucket`/`LibrarySelection` (`Models/Enums.swift`)
  bucket meetings into All/Inbox/Favorites/Archive.
- `Folder` (`Models/Folder.swift`) — one folder per meeting (`Meeting.folder`,
  `.nullify`, so deleting a folder detaches rather than deletes its meetings).
  Self-referential `parent`/`children` support subfolders, with breadcrumb
  drill-down navigation (`Views/FolderSidebarView.swift`, driven by a
  `NavigationStack(path:)` of drilled-into folders). Icon/color are picked from
  the curated lists in `FolderCatalog.swift` (`FolderIconCatalog`,
  `FolderColorPalette`) via `Views/FolderFormView.swift`, so free-form
  icon/hex entry can't produce an invalid symbol or color. `FolderPickerView`
  mirrors the same drill-down to move a meeting into a folder.
- `Tag` (`Models/Tag.swift`) — many-to-many via `Meeting.tags` (`.nullify`).
  `AutoTaggingService` (`Services/AutoTaggingService.swift`) can suggest
  existing/new tags from a transcript excerpt through the configured summary
  LLM provider; it's off by default and gated in Settings. Suggestions are
  reviewed in `AutoTagConfirmView` before `MeetingDetailAutoTagging` (a
  `MeetingDetailView` extension) applies them — attaching existing tags by id
  and creating new `Tag` rows for suggested names.
- `MeetingFilter` (`Models/MeetingFilter.swift`) — a `Codable` value type (not a
  `@Model`) ANDing date range, tags, status, summary presence, and duration.
  Used as live UI filter state and as a `SmartFolder`'s persisted predicate.
- `SmartFolder` (`Models/SmartFolder.swift`) — stores a JSON-encoded
  `MeetingFilter` and does not own meetings; `meetings(matching:)` filters an
  in-memory list dynamically, like a saved search rather than a folder.
- `FolderAnalytics` (`Services/FolderAnalytics.swift`) — pure value type
  computing counts/durations/status/tag/speaker breakdowns for a folder or any
  `[Meeting]`, rendered by `Views/FolderAnalyticsView.swift`.

### Secure local storage for recordings

Audio files live in `Documents/Recordings/` (not `Documents/` itself) with
`FileProtectionType.completeUnlessOpen` set on the directory so new `.m4a`
files inherit it. iOS wraps each file's AES key with a key derived from the
device passcode, so the bytes are unrecoverable from a backup or extraction
without the passcode. `.completeUnlessOpen` (rather than `.complete`) is
chosen so an in-progress recording survives the screen locking mid-meeting.

`RecordingProtection` (`Infrastructure/RecordingProtection.swift`) owns the
directory setup, the per-file attribute application, and the one-shot
migration of any legacy `.m4a` left in `Documents/` from older versions —
called from `RecordingRecovery.recoverOrphans` at launch. Every read path
resolves files through `AudioFileStore.resolveURL(fileName:)`, which prefers
the protected directory and falls back to `Documents/` for any
not-yet-migrated leftovers.

A separate access layer, `RecordingAccessGate`
(`Services/RecordingAccessGate.swift`), guards the recordings UI behind
`LAContext.evaluatePolicy(.deviceOwnerAuthentication, ...)` (Face ID /
Touch ID / passcode) once per foreground session. The gate is injected via
the environment from `KurnApp` and re-locked on every
`scenePhase == .background` transition. `MeetingsListView` swaps in a
`LockedRecordingsView` overlay until the user authenticates. Disabling
`AppSettings.requireAuthForRecordings` (Settings → Recording) turns off the
prompt while leaving the on-disk encryption in place.

The recorder sheet is presented outside the access gate's locked/unlocked
branch, so backgrounding mid-recording (which re-locks the gate) can't tear
down the live `RecorderViewModel` and orphan its audio file;
`RecordingRecovery` also no longer deletes unreadable orphans ≥1 MB outright.
`AudioRecorderService` separately recovers from
`AVAudioEngineConfigurationChange` (e.g. the engine bouncing when the device
locks) by restarting in place, or pausing with a banner if the audio format
changed.

`ModelStoreProtection` (`Infrastructure/ModelStoreProtection.swift`) applies
the same `.completeUnlessOpen` file protection to the SwiftData store itself
(`default.store` plus its `-shm`/`-wal` sidecars in Application Support),
since transcripts and summaries live there as JSON `Data`. It must run before
the `ModelContainer` is created and is a no-op on a fresh install with no
store file yet. Despite the similar name, it is unrelated to `ModelStore`
(below), which manages downloaded FluidAudio model files, not app data.

**All meeting-derived persisted data is encrypted at rest by this same
mechanism.** The semantic-search index (`SemanticChunk` — passage text plus its
embedding `vectorData`) and any future chat-history model are `@Model`s in the
one app store, so they inherit `.completeUnlessOpen` automatically. The rule
this imposes: never write vectors, transcript-derived text, or chat content to a
loose file, a cache directory, or `UserDefaults` — keep it in the SwiftData
store. Embedding vectors are stored in-store as raw `Float32` `Data`
(`Infrastructure/Extensions/VectorData.swift`), deliberately not in a separate
on-disk vector file, precisely so no unprotected sidecar is introduced.

### Transcription pipeline (`Services/TranscriptionService.swift`)

Each stage is a protocol seam (`Services/Pipeline/PipelineStages.swift`:
`AudioPreprocessing`, `VoiceActivityDetecting`, `LanguageDetecting`,
`Transcribing`, plus `Diarizing` in `TranscriptionTypes.swift`) so the engine per
stage is swappable without touching the orchestrator. `PipelineConfiguration`
(built from `AppSettings`) picks one engine per stage; defaults are the
always-available, no-download engines so a fresh install works offline.
`TranscriptionService` holds one instance of every engine and maps the chosen
enum to it — engines are never spun up per call. The concrete choices per
stage (enums in `Models/Enums.swift`) are:

| Stage | `AppSettings` property | Default (no download) | Alternative (FluidAudio, model download) |
| --- | --- | --- | --- |
| Preprocessing | `preprocessingEngine` | `.standardDSP` (`AudioPreprocessor`) | `.none` (passthrough — not FluidAudio, just skips cleanup) |
| VAD | `vadEngine` | `.energyThreshold` (`Pipeline/EnergyVAD.swift`) | `.fluidAudio` (`Pipeline/FluidAudioVAD.swift`, Silero VAD) |
| Language detection | `languageDetectionEngine` | `.byTranscriber` (no-op, defers to the transcriber) | `.fluidAudioLID` (`Pipeline/LanguageDetectors.swift`'s `FluidAudioLanguageDetector`, transcribes a 60s prefix with FluidAudio Parakeet and classifies it with `NLLanguageRecognizer`) |
| Diarization | `diarizationEngine` | `.heuristic` (`SpeakerDiarizer`, pitch/timbre clustering) | `.fluidAudio` (`FluidAudioDiarizer`, neural embeddings via `OfflineDiarizerManager`) |
| Transcription | `transcriptionEngine` | `.appleSpeech` (`OnDeviceTranscriber`, fixed device locale) | `.fluidAudioParakeet` (`FluidAudioTranscriber`, multilingual, auto-detects language) or `.whisperAPI` (cloud) |

`TranscriptionService.transcribe` drives the stages in order:

1. **Preprocess** audio with the selected engine (`AudioPreprocessor` or a
   passthrough); on any failure it falls back to the original file so
   transcription never breaks.
2. **Detect language** (only surfaced as a phase when a real detector runs; the
   default no-op detector defers to the transcription engine).
3. **Detect speech** (VAD) — drives both silence-gating of the transcription
   input and the heuristic diarizer's segmentation.
4. **Transcribe + diarize** — concurrent (`async let`) for Whisper, since cloud
   transcription keeps almost nothing on-device; sequential for on-device
   engines, because running a large ASR model alongside the diarizer over a
   long recording can push peak memory past the jetsam limit. Diarization reads
   its own cleaned copy (`DiarizationPreprocessor`, minimal DSP preserving
   natural timbre) rather than the ASR-tuned one, unless
   `diarizationPreprocessingEnabled` is off. `fluidAudioMinSpeakers` forces the
   `.fluidAudio` diarizer to re-cluster with KMeans to at least that many
   speakers, working around its VBx step collapsing far-field/single-mic audio
   into one cluster; the heuristic engine ignores it.
5. **Fuse** transcript spans with speaker turns into `[TranscriptSegment]`
   via the pure, unit-tested `Pipeline/TranscriptFusion.swift` (merges
   consecutive same-speaker spans, capped at 30s).

Every stage call is preceded by `ResourceGuard.requireTranscriptionHeadroom()`
(`Infrastructure/ResourceGuard.swift`, 750MB disk floor), which throws
`AppError.resourceUnavailable` rather than let the pipeline run out of disk
mid-transcription; `TempFileCleaner.cleanupOrphanedTempFiles()` runs at the
start of every `transcribe` call to sweep temp files (`kurn_clean_`,
`kurn_vad_`, `kurn_diar_`, `kurn_chunk_` prefixes, plus stale Whisper upload
spool files) older than an hour that earlier interrupted runs left behind; the
same cleaner backs the manual "Free up space" action in Settings.

Progress is reported via a `@Sendable` `PhaseHandler` (`TranscriptionPhase`); the
receiver must hop to the main actor itself.

#### FluidAudio on-device models and download consent

The FluidAudio-backed engines above (and the live transcription preview below)
download CoreML models on first use rather than bundling them, so enabling one
never fetches models for a feature the user hasn't opted into:

- `Infrastructure/ModelDownloadConsent.swift` is the single place that
  triggers a download, one `ModelSet` case (`.liveTranscriptionASR`,
  `.onDeviceASR`, `.diarization`, `.vad`) at a time, gated behind a matching
  `AppSettings.fluidAudio*Consented` flag the user sets in Settings. Each
  engine's `requiredModelSet` (on the `TranscriptionEngine`/`VADEngine`/
  `DiarizationEngine`/`LanguageDetectionEngine` enums) says which set it needs.
- `Services/FluidAudioModelStore.swift` (`actor`, `.shared`) caches the loaded
  multilingual Parakeet batch ASR model so `FluidAudioTranscriber` and
  `FluidAudioLanguageDetector` share one loaded copy instead of each compiling
  their own CoreML/ANE artifacts; `prewarm()` is called from the foreground
  (from `AppSettings.usesFluidAudioModel`) since ANE compilation can fail if
  attempted from the background.
- `Services/ModelStore.swift` (distinct from the above) is a pure-Foundation
  on-disk manager for the downloaded model folders under
  `Application Support/FluidAudio/Models`, grouped by `ModelGroup`. It backs
  the Settings screen that lists installed models with disk usage and lets the
  user delete a group to reclaim space.
- `ResourceGuard.requireModelDownloadHeadroom()` (2.5GB disk floor) gates every
  download attempt in addition to the 750MB transcription floor above.

#### Resumable transcription

Long transcriptions survive backgrounding, app termination, and cancellation
instead of restarting from scratch:

- `Models/TranscriptionCheckpoint.swift` persists JSON (via
  `Recording.transcriptionCheckpointData`) after every completed chunk: engine,
  language, whether the VAD-compacted input was used, total/completed chunk
  counts, and spans transcribed so far. `Pipeline/ChunkedTranscriptionRunner.swift`
  is the shared chunk loop for both Whisper and chunked Apple Speech; a resume
  is only honored if the re-derived chunk plan matches exactly (same engine,
  language, compaction, chunk count), otherwise it starts over.
- `Services/WhisperBackgroundUploader.swift` uploads Whisper chunks over a
  background `URLSession` (file-based request bodies) so an in-flight upload
  survives the app suspending or the device locking.
- `Infrastructure/TranscriptionScheduler.swift` registers the
  `ai.kurn.transcription.processing` `BGProcessingTask` and submits a request
  on backgrounding whenever pending/in-progress work remains (skipped for
  FluidAudio engines, which can't compile CoreML models in the background).
  The task resumes pending recordings and checkpoints cooperatively before its
  time window expires.
- `Infrastructure/TranscriptionRecovery.swift` sweeps recordings stuck at
  `.inProgress` on launch and every foreground activation: recordings with a
  checkpoint reset to `.pending` (resumable), others to `.failed`.
- `Infrastructure/BackgroundActivity.swift` wraps
  `UIApplication.beginBackgroundTask`/`endBackgroundTask`, requesting a finite
  execution window so a long transcription isn't suspended the instant the app
  backgrounds; its `onExpiration` callback lets the checkpoint machinery pause
  cleanly instead of being frozen mid-chunk when the system reclaims the
  window.

### Live transcription preview (`Services/LiveTranscriptionService.swift`)

An opt-in (`AppSettings.liveTranscriptionEnabled`, off by default),
preview-only transcript shown while recording — nothing it produces is
persisted; the authoritative transcript still comes from `TranscriptionService`
after the recording stops. `RecorderViewModel` feeds it live audio buffers
through a `nonisolated append(_:)` entry point wired to
`AudioRecorderService.onAudioBuffer`. It picks a streaming engine by the
meeting's language: English uses the lightweight
`StreamingModelVariant.parakeetEou160ms` manager; every other language
(including auto-detect) uses `Services/FluidAudioMultilingualStreamingManager.swift`,
which adapts FluidAudio's `StreamingNemotronMultilingualAsrManager` to the
app's `StreamingAsrManager` protocol. An in-flight gate drops buffers instead
of queuing them when a previous chunk is still processing, so the preview
never falls behind the microphone.

### Providers (`Providers/`)

`LLMProvider` (`Sendable`) abstracts the cloud vendors. `ProviderFactory` is the
single place that resolves a provider from `AppSettings` + Keychain and throws
`AppError.noAPIKey` when a key is missing. Vendor API shapes are modeled by
`AIProviderKind` (`openAICompatible`, `anthropic`, `googleGemini`); Groq reuses the
OpenAI-compatible client. **Cloud (`.whisperAPI`) transcription is not pinned to
OpenAI** — `AIProvider.supportsTranscription` is true for any `openAICompatible`
provider (OpenAI, Groq, or a custom OpenAI-compatible endpoint the user adds),
since they're the only ones exposing a Whisper-shaped `/audio/transcriptions`
route; Anthropic/Gemini are excluded. `AppSettings.transcriptionProviderID`
picks which one to use, independently of the summary provider, surfaced as a
"Transcription provider" picker in Settings shown only when the Whisper engine
is selected. `ProviderFactory.whisperProvider(for:model:)` resolves the chosen
provider + model (Groq defaults to `whisper-large-v3`; everything else to
`whisper-1`).
`Providers/ProviderModelsService.swift` separately lists a provider's available
summary models by querying its own `/models` endpoint (auth style branches on
`AIProviderKind`), falling back to `AIProvider.fallbackModels` on a 403 or an
empty response (some vendors, e.g. Groq, reject otherwise-valid keys) — this
backs the model picker in Settings and is distinct from the
completion-calling `LLMProvider` clients above.

Summaries are template-driven: `SummaryPrompt.system(for:)` builds the system prompt
from the chosen `SummaryTemplate` (`Models/SummaryTemplate.swift` — persona/
instructions plus suggested sections; built-ins are `.general`, `.standup`, and
`.interview`, collected in `defaultTemplates`), and the model returns a flexible
`{ "sections": [...] }` shape decoded into `[SummarySection]`
(`Models/SummarySection.swift` — title, Markdown body, bullet items) rather than
a fixed set of fields. `SummaryJSON.parse` tolerantly strips
markdown fences and extracts the outermost `{...}` since models add prose. Templates
(built-in presets + user-defined, created/edited via `Views/TemplateEditorView.swift`
— built-ins can't be renamed or deleted) live in `AppSettings.summaryTemplates`; the user
picks one per summarization via `SummaryTemplatePicker`. `Summary.sections` holds the
template-driven body that the views and export render. `SummaryView` renders inline
Markdown in titles, body text, and item text, with lightweight block handling for
headings and lists.

Every provider HTTP call funnels through `LLMHTTP.sendValidated`, which retries
transient transport errors and `429/500/502/503/504` with exponential
backoff + jitter (honoring `Retry-After`), instead of failing outright on a
momentary blip. `SummaryService` splits transcripts beyond ~80k chars into a
map-reduce pass (condense each block, then summarize the combined notes) and
raises the output budget/timeout (8192 tokens, 300s) so long transcripts don't
truncate mid-JSON or time out; a truncated response surfaces as
`AppError.summaryTruncated` instead of a confusing decode error. Summary generation is
owned by `TranscriptionViewModel.startSummary`, which keeps the Summary tab in a
non-reentrant progress state and supports cooperative cancellation.

### Cross-device control (Watch + Live Activity)

`RecordingCommandRouter` (main-actor singleton) is the single dispatcher: the live
`RecorderViewModel` registers `onPause/onResume/onStop/onTogglePause` closures while
recording. Both the Lock Screen Live Activity (via `kurn://recording/...` deep links)
and the Apple Watch (via `PhoneSessionController` over WatchConnectivity) route
through it. The recorder pushes state to the Watch with `updateApplicationContext`
(survives disconnects) and throttles audio-level pushes (`sendMessage` off the main
thread, 0.2s spacing). `Services/LockScreenRecordingController.swift` owns the
ActivityKit (`Activity<RecordingActivityAttributes>`) lifecycle — `start`/
`update`/`end` mirror `AudioRecorderService.State` into the activity's
`ContentState`; the actual Live Activity UI is rendered separately by the
`KurnLiveActivityExtension` widget target.

The watchOS target does **not** share source files with the app — types like
`WatchCommand` and the wire-contract constants in `WatchSessionProtocol.swift`
(the `WCSession` application-context/message dictionary keys and state
strings) are intentionally duplicated byte-for-byte in `KurnWatch/`. Keep both
copies in sync.

`RecordingActivityAttributes` (`Infrastructure/RecordingActivityAttributes.swift`)
is, by contrast, a single file compiled into both the `Kurn` and
`KurnLiveActivityExtension` targets — unlike `WatchCommand`, there was no reason
for it to drift, so it's shared rather than duplicated.

### Semantic search & chat (`Services/Embedding/`, `Services/SemanticSearchService.swift`, `Services/MeetingChatService.swift`)

On-device semantic search over transcripts plus a retrieval-augmented "chat with
your meetings", built with **no new external dependency**: embeddings come from
Apple's `NaturalLanguage` framework (`NLContextualEmbedding`, multilingual,
loaded once via the `EmbeddingModelStore` actor — same coalesced-load pattern as
`FluidAudioModelStore`), and chat reuses the existing cloud `LLMProvider` stack.

- **Indexing.** After a transcript is persisted, `TranscriptChunker` splits it
  into short passages (absolute meeting timestamps + dominant speaker),
  `SemanticIndexService` embeds them off-main, and `SemanticIndexCoordinator`
  (`@MainActor`, app-wide, created in `KurnApp`) persists them as `SemanticChunk`
  rows. Indexing is automatic on transcription completion and a low-priority
  launch/foreground **backfill** re-indexes meetings transcribed before the
  feature existed (or by an older embedder, tracked via `modelIdentifier`). Gated
  by `AppSettings.semanticSearchEnabled` (on by default).
- **Search.** `SemanticSearchService` embeds the query once and ranks stored
  chunk vectors by cosine similarity (`vDSP` dot product on unit-normalized
  vectors). `MeetingsListView` runs a debounced hybrid pass: instant substring
  matching plus semantically-relevant meetings the substring pass missed.
- **Chat.** `LLMProvider` gained a plain-text `chat(systemPrompt:messages:)`
  (implemented for OpenAI/Anthropic/Google; no JSON-mode forcing) alongside
  `summarize`. `MeetingChatService` has two grounding strategies: **per-meeting**
  (`answerAboutMeeting`) sends the **whole transcript** as context — a single
  meeting almost always fits the single-pass budget (`SummaryService.maxSinglePassChars`),
  which is far more accurate than retrieving a few passages; only over-budget
  meetings fall back to retrieval. **Library-wide** (`answerAcrossLibrary`) and
  the long-meeting fallback use a retrieval pipeline: LLM query rewrite → hybrid
  dense (`NLContextualEmbedding` cosine) + lexical (BM25) retrieval fused with
  Reciprocal Rank Fusion (`SemanticSearchService.hybridSearch`) → LLM rerank →
  grounded answer. All prompts cite `[mm:ss]` and reply in the transcript
  language. `MeetingChatViewModel` + `MeetingChatView` drive an in-memory
  conversation, surfaced as a per-meeting Chat tab (`MeetingDetailView`) and a
  library-wide "Ask" sheet (`MeetingsListView`); cited `[mm:ss]` timestamps are
  tappable and seek the transcript. History is in-memory only — nothing
  chat-related is persisted, so there is nothing extra to encrypt.

### Settings & secrets

`AppSettings` (`@MainActor @Observable`) holds non-secret preferences in
`UserDefaults`, persisting on `didSet`. **API keys never go here** — they live in the
Keychain via `KeychainManager`, keyed by `AIProvider.keychainAccount`. Built-in
providers keep a `legacyKeychainAccount` for backward compatibility; custom providers
use `provider_<id>_api_key`. A few preferences also mirror to non-persistent global
state in their `didSet` — e.g. `logLevel` pushes to `AppLog.minimumLevel` so the
logging gate reflects the user's choice immediately (also synced once on init).

## Conventions

- **Errors:** surface recoverable failures as `AppError` (`Infrastructure/AppError.swift`),
  a `LocalizedError` whose messages come from `NSLocalizedString`. New error cases
  must add a matching localization key.
- **Localization:** user-facing strings use `NSLocalizedString`; the app ships
  **seven languages** — English, Brazilian Portuguese, Spanish, French, Italian,
  German, and Simplified Chinese (`Kurn/Resources/{en,pt-BR,es,fr,it,de,zh-Hans}.lproj/`).
  Every new user-facing string must be added as a key to **all seven**
  `Localizable.strings` files in the same change — none skipped. `displayName` on
  enums is the localization seam.
- **Logging:** use `AppLog.<category>` (subsystem `ai.kurn.app`), which wraps
  `os.Logger` in a `CategoryLogger` that gates every message by `AppLog.minimumLevel`.
  Pick the severity per call site — `.debug` for high-frequency/per-iteration traces,
  `.info` for details (counts, formats, timings), `.notice` for lifecycle milestones,
  `.error`/`.fault` for failures. The user controls the threshold in Settings
  (persisted via `AppSettings.logLevel`); `.off` silences everything. The launch
  default is `.notice`, overridable with `KURN_LOG_LEVEL=debug|info|notice|error|off`
  or `KURN_LOG=0`. Mark interpolated values `privacy:` explicitly.
- **Concurrency:** services are `Sendable` value types callable off the main actor;
  view models and anything touching SwiftData/UI are `@MainActor`. Preserve these
  boundaries when adding code.
- **Tests:** Swift Testing (`@Test`, `#expect`). Use
  `TestModelContainer.make()` for an in-memory `ModelContainer` when exercising real
  SwiftData relationship behavior.
- **Git & PRs:** write all commit messages and pull request titles/descriptions in
  English, regardless of the language used in chat. (User-facing app strings are
  still localized per the localization convention above — this rule is only about
  repository metadata.)
- **Do not commit directly to `main`:** create a feature branch for every change,
  push it, and open a pull request. Only merge through the GitHub PR workflow so
  CI runs before the change lands on `main`. The only exceptions are fastlane
  version/tag bumps run explicitly by a maintainer.
