# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Kurn is a local-first iOS + watchOS app (Swift 6, SwiftUI, SwiftData) for recording
meetings, transcribing audio, diarizing speakers, and generating structured AI
summaries. Everything is stored on device; network calls happen only when the user
opts into OpenAI Whisper transcription or a cloud summary provider.

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
run locally by a maintainer. Pushing that tag triggers
`.github/workflows/release.yml`, which reruns `build-and-test.yml` against the
tagged commit and then runs the CI-only `github_release` lane to publish a
GitHub Release. No signing/archiving/TestFlight upload is wired up yet.

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
  (`Enums.swift`, `MeetingFilter`, `TranscriptionCheckpoint`).
- **Services/** — audio capture, transcription pipeline (`Services/Pipeline/`),
  diarization, summaries, folder analytics, auto-tagging. These are mostly
  `struct`/value types operating on plain values so they stay decoupled from
  SwiftData and safe off the main actor.
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
  Self-referential `parent`/`children` exist for future subfolders; the sidebar
  only shows root folders today. Icon/color come from `FolderCatalog.swift`.
- `Tag` (`Models/Tag.swift`) — many-to-many via `Meeting.tags` (`.nullify`).
  `AutoTaggingService` (`Services/AutoTaggingService.swift`) can suggest
  existing/new tags from a transcript excerpt through the configured summary
  LLM provider; it's off by default and gated in Settings.
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

### Transcription pipeline (`Services/TranscriptionService.swift`)

Each stage is a protocol seam (`Services/Pipeline/PipelineStages.swift`:
`AudioPreprocessing`, `VoiceActivityDetecting`, `LanguageDetecting`,
`Transcribing`, plus `Diarizing` in `TranscriptionTypes.swift`) so the engine per
stage is swappable without touching the orchestrator. `PipelineConfiguration`
(built from `AppSettings`) picks one engine per stage; defaults are the
always-available, no-download engines so a fresh install works offline.

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
   `diarizationPreprocessingEnabled` is off.
5. **Fuse** transcript spans with speaker turns into `[TranscriptSegment]`
   via the pure, unit-tested `Pipeline/TranscriptFusion.swift` (merges
   consecutive same-speaker spans, capped at 30s).

Progress is reported via a `@Sendable` `PhaseHandler` (`TranscriptionPhase`); the
receiver must hop to the main actor itself.

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

### Providers (`Providers/`)

`LLMProvider` (`Sendable`) abstracts the cloud vendors. `ProviderFactory` is the
single place that resolves a provider from `AppSettings` + Keychain and throws
`AppError.noAPIKey` when a key is missing. Vendor API shapes are modeled by
`AIProviderKind` (`openAICompatible`, `anthropic`, `googleGemini`); Groq reuses the
OpenAI-compatible client. **Cloud transcription always uses OpenAI Whisper**
(`ProviderFactory.whisperProvider()`) regardless of the chosen summary provider.
Summaries are template-driven: `SummaryPrompt.system(for:)` builds the system prompt
from the chosen `SummaryTemplate` (persona/focus + suggested sections), and the model
returns a flexible `{ "sections": [...] }` shape. `SummaryJSON.parse` tolerantly strips
markdown fences and extracts the outermost `{...}` since models add prose. Templates
(built-in presets + user-defined) live in `AppSettings.summaryTemplates`; the user
picks one per summarization via `SummaryTemplatePicker`. `Summary.sections` holds the
template-driven body that the views and export render.

Every provider HTTP call funnels through `LLMHTTP.sendValidated`, which retries
transient transport errors and `429/500/502/503/504` with exponential
backoff + jitter (honoring `Retry-After`), instead of failing outright on a
momentary blip. `SummaryService` splits transcripts beyond ~80k chars into a
map-reduce pass (condense each block, then summarize the combined notes) and
raises the output budget/timeout (8192 tokens, 300s) so long transcripts don't
truncate mid-JSON or time out; a truncated response surfaces as
`AppError.summaryTruncated` instead of a confusing decode error.

### Cross-device control (Watch + Live Activity)

`RecordingCommandRouter` (main-actor singleton) is the single dispatcher: the live
`RecorderViewModel` registers `onPause/onResume/onStop/onTogglePause` closures while
recording. Both the Lock Screen Live Activity (via `kurn://recording/...` deep links)
and the Apple Watch (via `PhoneSessionController` over WatchConnectivity) route
through it. The recorder pushes state to the Watch with `updateApplicationContext`
(survives disconnects) and throttles audio-level pushes (`sendMessage` off the main
thread, 0.2s spacing).

The watchOS target does **not** share source files with the app — types like
`WatchCommand` are intentionally duplicated in `KurnWatch/`. Keep both copies in sync.

`RecordingActivityAttributes` (`Infrastructure/RecordingActivityAttributes.swift`)
is, by contrast, a single file compiled into both the `Kurn` and
`KurnLiveActivityExtension` targets — unlike `WatchCommand`, there was no reason
for it to drift, so it's shared rather than duplicated.

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
  English and Brazilian Portuguese (`Kurn/Resources/`). `displayName` on enums is the
  localization seam.
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
