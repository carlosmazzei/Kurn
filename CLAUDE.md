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
  `Speaker`, `Summary`) plus shared value types in `Enums.swift`.
- **Services/** — audio capture, transcription pipeline, diarization, summaries.
  These are mostly `struct`/value types operating on plain values so they stay
  decoupled from SwiftData and safe off the main actor.
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
parent collection manually.

### Transcription pipeline (`Services/TranscriptionService.swift`)

The orchestration that requires reading several files together:

1. **Preprocess** audio (`AudioPreprocessor`); on any failure it falls back to the
   original file so transcription never breaks.
2. **Transcribe + diarize concurrently** (`async let`) over the same cleaned file —
   engine is on-device (`OnDeviceTranscriber`, Apple Speech) or Whisper
   (`AudioChunker` splits long audio, uploads chunks, offsets timestamps back to
   absolute meeting time).
3. **Fuse** transcript spans with heuristic speaker turns into
   `[TranscriptSegment]`, merging consecutive same-speaker spans (capped at 30s).

Progress is reported via a `@Sendable` `PhaseHandler` (`TranscriptionPhase`); the
receiver must hop to the main actor itself.

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
