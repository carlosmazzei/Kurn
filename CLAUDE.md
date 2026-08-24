# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Kurn is a local-first iOS + watchOS app (Swift 6, SwiftUI, SwiftData) for recording
meetings, transcribing audio, diarizing speakers, and generating structured AI
summaries. Everything is stored on device; network calls happen only when the user
opts into cloud (Whisper-compatible) transcription or a cloud summary provider.

Beyond the summary, a transcript also feeds three further derived artifacts, each
opt-in and each described in its own section below: a per-meeting **wiki**
(`WikiArticle`), free-form **documents** synthesized across meetings
(`GeneratedDocument`), and an optional **LLM correction pass** over the fused
segments. All three are cloud-LLM-backed and therefore off by default — the rule
throughout is that a fresh install transcribes offline and asks before it ever
reaches the network.

The iOS app targets **iOS 26.0** and uses the system's Liquid Glass chrome
directly (see "Navigation chrome" below); the watchOS companion still targets
watchOS 10.0. There is no `#available` fallback for pre-26 iOS — the floor is the
deployment target.

The project is an Xcode project (`Kurn.xcodeproj`) with three targets: `Kurn`
(app), `KurnWatch` (watchOS companion), and `KurnLiveActivityExtension`
(widget/Live Activity). Tests live in `KurnTests` (Swift Testing, not XCTest).
There is no root `Package.swift`; the one package manifest in the repo is
`Packages/WhisperCpp/Package.swift`, a local package whose only target is a
`.binaryTarget` pointing at whisper.cpp's official prebuilt XCFramework release
asset (see "On-device Whisper (whisper.cpp)" below). The only remote package is
FluidAudio.

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

`fastlane/Fastfile` has eight public lanes.
`bump_version type:{patch,minor,major}` bumps
`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` across all targets via direct text
substitution on `project.pbxproj` (not `increment_version_number`/`xcodeproj`,
which reorder unrelated parts of this file because it uses Xcode 16
file-system-synchronized groups), then commits, tags `vX.Y.Z`, and pushes —
run locally by a maintainer. Pushing that tag starts the pipeline in
`.github/workflows/swift.yml` after `build-and-test`: `release` publishes the
GitHub Release; `beta` signs via readonly `fastlane match`, uploads to TestFlight,
and waits for Apple processing; and `store-assets` calls the reusable
`.github/workflows/screenshots.yml` to capture iPhone/iPad/Watch screenshots and
sync them with all localized metadata to the exact project `MARKETING_VERSION`.
This uses deliver's beta `sync_screenshots` path (enabled only inside the
`store_assets` lane), which removes remote extras before uploading missing
images; the legacy uploader retries before Apple exposes checksums and can create
duplicates.
`beta` and the assets upload each use the protected `release` GitHub Environment,
so every App Store Connect mutation waits for administrator approval. Once both
succeed, the dependent protected `submit` job runs `submit_review`; that lane
derives version/build from the tagged project, verifies the `vX.Y.Z` tag,
attaches the processed build, and submits it to App Review with
`automatic_release: false`. The standalone
`.github/workflows/app-store-submit.yml` remains a manual retry path.
`Tools/validate_store_metadata.py` checks locale/file completeness, text limits,
and URLs in the regular CI job. No Apple ID password or 2FA prompt is required;
App Store Connect calls use its API key, while signing credentials come from the
private `kurn-certificates` repository. `store_assets` also calls the private
`sync_accessibility_labels` lane to upsert draft Accessibility Nutrition Labels
from `fastlane/accessibility.json` for iPhone, iPad, and Apple Watch through
Apple's `accessibilityDeclarations` API; Fastlane 2.238.0 has no native model for
that endpoint, so `fastlane/accessibility_labels.rb` uses Spaceship's
authenticated request client directly. The public `accessibility_labels` lane
supports `dry_run:true` and `publish:true`; publishing is separate because Apple
rejects publication until the app has a live App Store version. The protected
manual `.github/workflows/accessibility-labels.yml` workflow exposes that
operation for a `v*` tag after the first public release.

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

### Measuring accuracy (WER / DER)

`KurnTests/Support/Evaluation/` implements the two standard metrics, so an
accuracy claim can be *measured* instead of inferred from the literature —
which is what every claim about this pipeline had been until it existed.

- `WordErrorRate` — Levenshtein over normalized tokens, reporting
  substitutions / insertions / deletions separately, because they mean different
  things here: dropped speech (VAD gating, a quality filter, a chunk boundary)
  is deletions, hallucination is insertions, mishearing is substitutions.
  Two-row DP carrying the counts forward — a full backtrace matrix for an
  hour-long meeting is ~320 MB.
- `TextNormalizer` — for comparison only, never applied to a stored or displayed
  transcript, which should keep its punctuation and case. Language-neutral
  (NFKC, case fold, punctuation strip); unsegmented scripts fall back to
  characters, which makes their rate a CER. Rates are comparable between runs on
  the same material, not against published figures.
- `DiarizationErrorRate` — NIST DER: missed + false alarm + confusion over
  reference speech, scored under the label mapping that maximises agreement
  (a diarizer's own labels are arbitrary) with a ±0.25 s collar around reference
  boundaries. Confusion is reported apart from missed time because this app's
  known failure — the clustering step collapsing to one speaker — is *all*
  confusion and *no* missed time.
- `RTTM` — reads and writes the annotation format the corpora and external
  scorers use.

The corpus cannot live in the repository: meeting recordings are the most
private thing the app touches. `EvaluationDataset` reads `KURN_EVAL_DATA`
instead, and `EvaluationHarnessTests` is skipped entirely when it is unset —
which is how CI runs, so **a green run proves the metrics are correct and says
nothing about accuracy on real speech**. With a directory set, it scores
`<name>.reference.txt`/`.hypothesis.txt` pairs, `.rttm` pairs, and — the one
that catches regressions, because it re-derives the result every run — the
heuristic diarizer run over `<name>.m4a` against `<name>.reference.rttm`.

`Tools/evaluation/` has the recipe for producing that material — getting the
`.m4a` off the device (the app does not declare `UIFileSharingEnabled`, so Files
and Finder cannot see recordings, and that should stay true), annotating turns in
Audacity, and `prepare.py` to convert the app's Markdown export and the label
track into the two file formats the harness reads.

Deliberately no pass/fail threshold: a budget invented here would have no
provenance, and the first failure would just raise it.

### Pipeline evaluation matrix on public datasets

The private-corpus harness above answers "is this accurate on *my* meetings",
but never runs unattended — there is no corpus for CI to score against. It also
scores one hypothesis at a time, so it cannot say whether audio cleanup or a
given diarizer actually helps versus just asserting it does.
`PublicDatasetEvaluationHarnessTests` (`KurnTests/`) is the other half: it runs
the app's real pipeline — `TranscriptionService`, not a stand-in — once per
configuration in `PipelineEvaluationMatrix` (preprocessing on/off x VAD x
diarization x transcription engine, 24 on-device combinations, plus optional
cloud Whisper/OpenAI/Groq entries when their API key secret is present) over
public benchmark audio in English and Portuguese, scoring WER/DER against each.
Public audio carries none of the private corpus's restrictions, so this suite
is meant to run in CI on demand
(`.github/workflows/pipeline-eval.yml`, `workflow_dispatch`) — the practice is
to dispatch it after any change to a pipeline stage (preprocessing, VAD,
diarization, an engine, `TranscriptFusion`, …) to see whether the change moved
WER/DER, not just whether it still compiles.

Skipped like the private harness — via `KURN_PUBLIC_EVAL_DATA`, read by
`PublicEvaluationDataset` — but the corpus itself is fetched on demand rather
than committed (still too large for git, just not private), from
`Tools/evaluation/public_datasets/` (`manifest.json` + `fetch_all.py`; see its
README for what each corpus needs, including the `HF_TOKEN`/`OPENAI_API_KEY`/
`GROQ_API_KEY` secrets some entries are gated behind). Output is `[pipeline-eval]`
lines: per-item WER/DER, then aggregate tables per (language, configuration) and
per (corpus, configuration) — the ones to compare between runs — plus an
optional CSV via `KURN_PUBLIC_EVAL_REPORT`. Same no-threshold philosophy as the
private harness.

**The corpus mix is weighted toward meeting audio on purpose.** Rates are
micro-averaged by reference length, so the corpus with the most speech decides
the language number: AMI (four people around a table, `ami_rttm`, the only
corpus scored on **both** WER and DER) is sized to dominate English, while
LibriSpeech is kept small as a regression canary rather than a description of
real use. AMI's lexical reference comes from AMI's own manual annotation zip —
`fetch_ami.py` reads only `words/*.words.xml`, where each `<w>` carries its own
`starttime`, so a time-ordered transcript needs no speaker mapping; it is
best-effort and degrades to DER-only rather than risk a silently wrong
reference. A second grain exists because a language total otherwise blends read
speech with meeting speech. `huggingface_diarization` is the generic fetcher for
the `diarizers-community` layout (`timestamps_start`/`timestamps_end`/`speakers`
→ RTTM), which makes a DER corpus a manifest entry rather than a new script.
Cost scales as audio-seconds × configurations — prefer per-corpus dispatches
over one sweep.

**The CSV is appended row by row as each cell is scored**, and the aggregate is
printed before the failure assertion rather than after it. Both exist because
the report used to be built in memory and written once, after the loop *and*
after `#require(failures.isEmpty)`, so a run that hit the 360-minute ceiling, got
cancelled, or tripped over one broken cell produced nothing at all. A truncated
report is now a usable result and a resume point: `resume: true` (workflow) /
`KURN_PUBLIC_EVAL_RESUME=1` keeps the rows already in the file and runs only the
missing cells. Opt-in, because a row records nothing about the code that
produced it — reusing one is sound only while the pipeline is unchanged, which
per-stage versions in the CSV would make checkable instead of promised.

Two axes are provably redundant and worth knowing before adding cells:
`TranscriptFusion` is word-preserving (`splitCoarseSpan` returns the original
span unless the partition consumes every word), so **the diarizer cannot change
WER** — confirmed by Parakeet scoring identically across all four VAD × diarizer
combinations. whisper.cpp does vary there, which cannot be the diarizer and is
therefore its own decode non-determinism: roughly a 2-point noise floor that any
WER comparison has to clear. DER is *not* symmetric, since it is scored on the
fused segments whose boundaries come from the ASR spans.

**Results are recorded in `docs/pipeline-evaluation.md`**, newest run first,
and summarized in the README's "Accuracy And Evaluation" section. That file
exists because neither place the workflow writes to survives: the job summary
belongs to a run page and the artifact is deleted after 90 days, so without it
a measurement cannot be compared against one taken two months earlier — which
is the only thing these numbers are good for. `Tools/evaluation/report_to_markdown.py`
renders `report.csv` into exactly the Markdown that file expects (re-deriving
the micro-average from the raw counts rather than scraping the already-rounded
aggregate lines, and splitting the configuration label into one column per
stage so the table survives the label format changing again), and the workflow
runs it so the job summary hands a maintainer something paste-ready. Recording
a run is deliberately a human step: a partial or noisy dispatch is not worth a
commit.

## Architecture

MVVM with `@Observable` `@MainActor` view models, value-type async services, and a
single app-wide SwiftData `ModelContainer`. The layers (under `Kurn/`):

- **Models/** — SwiftData `@Model` classes (`Meeting`, `Recording`, `Transcript`,
  `Speaker`, `Summary`, `Tag`, `Folder`, `SmartFolder`, `SemanticChunk`,
  `WikiArticle`, `GeneratedDocument`) plus shared value types (`Enums.swift`,
  `MeetingFilter`, `MeetingLanguage`, `TranscriptionCheckpoint`, `FolderCatalog`,
  `SummarySection`, `SummaryTemplate`, `UsageStats`, `DocumentSourceResolver`).
- **Services/** — audio capture, transcription pipeline (`Services/Pipeline/`),
  on-device FluidAudio engines, diarization, live transcription preview,
  summaries, wiki and document generation, folder analytics, auto-tagging. These
  are mostly `struct`/`actor` types operating on plain values so they stay
  decoupled from SwiftData and safe off the main actor.
- **Providers/** — cloud LLM clients behind the `LLMProvider` protocol.
- **ViewModels/** — `@MainActor @Observable` coordinators owning services and
  persisting results.
- **Views/** — SwiftUI screens.
- **Infrastructure/** — settings, errors, logging, keychain, export, extensions.

### Data model

`Meeting` is the aggregate root. It cascades deletes to its `recordings`,
`speakers`, `summaries`, `semanticChunks`, and `wikiArticle` — every
transcript-derived artifact dies with the meeting it came from, which is what
makes "delete the meeting" a complete erasure rather than a partial one.
`GeneratedDocument` is the deliberate exception: it snapshots its sources
instead of relating to them, so deleting a meeting cannot destroy a document
already generated from it.

The spoken language is `MeetingLanguage` (`Models/MeetingLanguage.swift`),
carrying both the BCP-47 locale for the on-device recognizer and the code
Whisper expects in its `language` hint, plus `.autoDetect`. It is table-driven
rather than switch-driven so SwiftLint's cyclomatic-complexity and
function-length limits stay unaffected as languages are added. Its rawValues are
persisted in `Meeting.languageRaw` — **never rename or remove an existing
case.**

Key persistence convention: **SwiftData can't store
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

### Audio storage format

Recordings are **always stored as mono AAC at
`AudioRecorderService.storageSampleRate` (24 kHz)**, never at the microphone's
native format. The recorder used to derive its encoder settings from
`inputNode.outputFormat`, which meant a 48 kHz file spending bits on a 24 kHz
band that nothing reads back: every machine consumer resamples to 16 kHz
(`AudioPreprocessor`, `DiarizationPreprocessor`, `VADAudioLoader`,
`SpeakerDiarizer`, `WhisperCppTranscriber`, and Apple Speech / FluidAudio
internally), and the only full-fidelity consumer is `AudioPlayerService`, for
which 24 kHz mono is transparent. Audio is never exported — `MeetingExport`
produces Markdown only.

Three things follow from the fixed format:

- **`RecordingSink`** (`Services/RecordingSink.swift`, split out of the recorder)
  owns an `AVAudioConverter` and resamples every tap buffer on its way to the
  file. `AVAudioFile.write(from:)` requires buffers in the file's
  `processingFormat`, so this is not optional — the sample-rate conversion needs
  `convert(to:error:withInputFrom:)`, not the frame-count-preserving overload.
  The converted buffer is also what `onAudioBuffer` hands the live-transcription
  preview.
- **`AudioQuality`** (`Models/Enums.swift`) is now bit rate only — 64/48/32 kbps,
  defaulting to `.standard` — because the sample rate is no longer a free
  variable. The pairing is what makes the low tier clean: 32 kbps over a 12 kHz
  band is fine, over 24 kHz it artefacts. `approximateBytesPerHour` backs the
  Settings row.
- **A mid-recording input format change no longer invalidates the file.**
  `recoverEngineIfNeeded` rebuilds the tap and the sink's converter for the new
  input and keeps writing to the same `.m4a`; pausing with the
  `recorder.engine_stalled` banner is now only the fallback when that fails.

`Recording.fileSize` caches each file's byte count (`0` = not measured yet, which
is also what lets the field be added without a SwiftData migration plan).
`RecordingRecovery` backfills it during the launch/foreground sweep it already
runs, and `Recording.effectiveBitRate` derives the stored rate from it.

`RecordingCompactor` (`Services/RecordingCompactor.swift`) re-encodes
already-transcribed recordings down to the current quality, for libraries
recorded before the fixed format. It is user-triggered from Settings → Storage
via `RecordingCompactionViewModel`, never automatic, and is the app's only
destructive operation that isn't an explicit delete — so: only
`transcriptionStatus == .done` recordings (anything else is still going to be
read by the pipeline, and a checkpointed resume would be corrupted), only files
more than `minimumExcessRatio` above the target, never upsampling, no DSP chain
(the diarizer reads this file and depends on natural timbre), and a re-encode to
`kurn_compact_*` in the temp directory that is verified (frames rendered, then
decodable and long enough) and `RecordingProtection`-stamped before
`replaceItemAt` swaps it in. Any failure leaves the original untouched.

`OfflineAudioRenderer` (`Services/Pipeline/OfflineAudioRenderer.swift`) is the
shared offline manual-rendering loop behind `AudioPreprocessor`,
`DiarizationPreprocessor` and the compactor. Reading the app's own AAC files
**must** go through an `AVAudioEngine` player-node render — `AVAudioFile.read`
and `AVAudioConverter` both fail on them with a generic "erro 0" on device.
`VADAudioLoader.monoSamples` keeps its own copy of the loop because it is
synchronous; keep the two in sync.

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
(`Services/RecordingAccessGate.swift`), guards the app behind
`LAContext.evaluatePolicy(.deviceOwnerAuthentication, ...)` (Face ID /
Touch ID / passcode) once per foreground session, re-locking on every
`scenePhase == .background` transition. Disabling
`AppSettings.requireAuthForRecordings` (Settings → Recording) turns off the
prompt while leaving the on-disk encryption in place.

**The lock is a window, not a view branch** — and that distinction is the
whole design. It used to be `if isLocked { LockedRecordingsView } else { … }`
inside `MeetingsListView` (and a second copy in `DocumentsListView`), which
conflated "what is visible" with "what exists in the hierarchy": every
`.sheet` attached to the unlocked branch was *destroyed* on lock. That made
protecting content and preserving the user's work mutually exclusive, one
sheet at a time — keeping the Settings sheet inside the branch discarded an
in-progress template edit and reopened at the Settings root, while moving it
out preserved the edit. Moving the *wrong* ones out (meeting detail, the Ask
chat, share) silently removed the only thing keeping a pushed transcript off
the screen of a borrowed unlocked device, since `MeetingDetailView` has no
gate of its own.

So the cover now lives above everything, in its own `UIWindow`:

- `SecurityCoverState` (`Infrastructure/SecurityCoverState.swift`) is the pure,
  unit-tested decision — `.hidden` / `.privacy` / `.locked` resolved from scene
  phase plus gate state. A non-active scene always wins, so even a locked app
  shows the neutral privacy cover mid-transition, which is what the
  app-switcher photographs. Only `.locked` takes key window status, because
  only it has controls and a keyboard to feed.
- `SecurityCoverWindow` (`Infrastructure/SecurityCoverWindow.swift`) owns the
  window at `UIWindow.Level.alert + 1` and the `securityCover(…)` modifier
  `KurnApp` attaches. It hides rather than tears down, and learns its
  `UIWindowScene` from a `didMoveToWindow` probe rather than guessing through
  `connectedScenes`.
- `SecurityCoverView` (`Views/SecurityCoverView.swift`) renders
  `PrivacyCoverView` or `LockedRecordingsView` and hosts the Settings escape
  hatch — required because a device with no passcode configured can never
  authenticate, and nothing below the cover window is reachable. It re-injects
  `AppSettings`, `ModelDownloadController` and the model container, since a
  separate window's hosting controller inherits no environment.

Two consequences worth keeping: sheet placement in `MeetingsListView` is no
longer a security decision (nothing is torn down, so presentations go wherever
reads best), and the cover closes a gap the old `PrivacyCoverView` `ZStack`
sibling never could — a presented sheet renders *above* the root view, so the
app-switcher snapshot used to capture the Ask chat's transcript excerpts.

`RecordingRecovery` also no longer deletes unreadable orphans ≥1 MB outright.
`AudioRecorderService` separately recovers from
`AVAudioEngineConfigurationChange` (e.g. the engine bouncing when the device
locks) by restarting in place, or pausing with a banner if the audio format
changed.

### Playback

`AudioPlayerService` (`@MainActor @Observable`, one per `MeetingDetailView`)
wraps a single `AVAudioPlayer`, and owns two things beyond it.

`Services/Playback/NowPlayingController.swift` publishes to
`MPNowPlayingInfoCenter` and accepts `MPRemoteCommandCenter` commands
(play/pause/toggle, ±15 s, scrub). This is not optional polish: the app declares
`UIBackgroundModes: audio`, so without it playback continues when the screen
locks with **no controls and no metadata** anywhere — Lock Screen, Control
Centre, Dynamic Island, AirPods stem, CarPlay, Watch. Two rules hold it
together: commands are registered on `load` and *removed* on `stop`, because the
command centre is process-wide and a torn-down player must not keep answering
it; and metadata is published only on state changes, never on the player's 0.1 s
tick, because Now Playing extrapolates position from the rate.
`NowPlayingController.info(...)` is split out as a pure builder so the metadata
contract is testable without a Lock Screen.

Audio-session events are handled the same way the recorder handles them — the
player had none of this, so an incoming call left `isPlaying` true over a
stopped player: interruption `.began` pauses and `.ended`+`.shouldResume`
resumes, `.oldDeviceUnavailable` pauses (unplugging headphones must not dump a
meeting into the speaker), the category mode is `.spokenAudio` rather than
`.default`, and `stop()` deactivates the session with
`.notifyOthersOnDeactivation` so whatever was playing before can resume.

### Enhanced playback copies

Playback can use a second, derived `.m4a` per recording — loudness-normalized,
equalized and gently compressed — rendered offline by
`Services/Enhancement/PlaybackEnhancementRenderer.swift` and generated **on
demand**, the first time the user turns enhancement on for that recording.
Doing it offline is what keeps `AudioPlayerService` on `AVAudioPlayer`: the
player only picks which URL to open, so there is no realtime graph and no
reimplemented seek.

Two passes, because loudness cannot be known in advance. The first measures
integrated loudness to ITU-R BS.1770-4 (`Services/Enhancement/LoudnessMeter.swift`)
**at 48 kHz** — the only rate the standard's coefficients are valid at, so the
measurement pass renders there rather than re-deriving them. The second applies
the resulting gain *at the input*, ahead of the EQ and compressor, which is what
makes the compressor's fixed threshold mean the same thing for every recording
in the library. Tuning lives in `Services/Playback/PlaybackTuning.swift` as a
pure value type so tests can assert it stays gentler than the ASR chain in
`AudioPreprocessor` — different job, different ears.

**Copies live in `Documents/Recordings/Enhanced/` under the same file name as
the original, never beside it with a suffix.** Every existing sweep over the
recordings directory is shallow, so a nested directory is invisible to all of
them by construction. A suffixed copy would be worse than deleted:
`RecordingRecovery` parses the meeting ID from the name prefix, so it would be
adopted as a second `Recording` and shown in the library as a duplicate. The
same choice means adding the directory to `AudioFileStore.delete(fileName:)`'s
search list makes every existing deletion path drop the copy with the original,
without any caller knowing the copy exists. `AudioFileStore.enhancedDirectoryPath`
only computes a URL; `ensureEnhancedDirectory()` is the creating variant and is
called only by the writer, because `delete` runs in a loop and creating plus
re-stamping a directory on every iteration is filesystem work for nothing.
The derived copies can also be reclaimed together from Settings → Storage;
the original recordings and their transcripts remain untouched.

`Recording.enhancedAudioVersion` (`0` = none) doubles as an existence and a
staleness check against `PlaybackEnhancementRenderer.currentVersion`; bump that
constant when the tuning changes and existing copies regenerate instead of being
served. `AudioPlayerService.load(fileName:enhanced:)` keeps `loadedFileName`
reporting the **logical** recording name — the whole UI keys row-to-player
identity off `player.loadedFileName == recording.fileName`, so the variant must
stay an internal detail of which URL to open.

The chain is preceded by a neural denoise pass
(`Services/Enhancement/PlaybackEnhancementNeuralPass.swift`) running streaming
GTCRN, converted from its official PyTorch checkpoint by `Tools/gtcrn/` (macOS +
`coremltools`) and driven frame by frame by `SpeechEnhancer` over the existing
`Pipeline/STFT.swift`. GTCRN is small enough to run over complete meetings, so
there is no duration cutoff.

**Running with no model installed stays a supported configuration**, not a
degraded one: `SpeechEnhancer` returns `nil`, `renderNeuralMix` returns `nil`,
and the DSP chain renders the source directly. Denoising is the smaller half of
making a far-table voice audible — it removes the noise *around* a quiet talker
without making the talker louder, which is the compressor's and the loudness
normalization's job.

The model is 16 kHz, so the pass is **decode → enhance → resample → mix**, file
backed at every step (Float32 `.caf` in the temp directory) so memory stays
bounded by one 4096-frame block rather than the whole meeting. Four things about
it are load bearing:

- **The dry/wet sum** (`PlaybackTuning.wetMix`, 0.85) is not a hedge against the
  model. It restores the 8–12 kHz band a 16 kHz model cannot represent, which is
  otherwise simply gone from the enhanced copy.
- **`latencyFrames` is the number a mistake in is audible.** GTCRN's online
  overlap-add retains its first hop and flushes its final hop, so its file output
  is already aligned and reports zero. `SpeechEnhancerTests` still substitutes
  an enhancer that inverts its input and cross-correlates the rendered result
  against the source, so an alignment regression fails end to end.
- **A short wet tail is tolerated, not fatal.** Three stages each round their
  frame count, so the wet stream can end a few frames before the dry. Those
  frames are left dry and logged; throwing would discard the entire neural pass
  and silently revert to DSP-only over a rounding difference.
- **`STFT` uses GTCRN's exact framing:** a 512-sample square-root Hann analysis
  and synthesis window with a 256-sample hop. The squared windows overlap-add to
  one; using the diarization path's analysis-only Hann would amplitude-modulate
  the enhanced stream.

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

| Stage | `AppSettings` property | Default (no download) | Alternative (model download) |
| --- | --- | --- | --- |
| Preprocessing | `preprocessingEngine` | `.standardDSP` (`AudioPreprocessor`) | `.none` (passthrough — not FluidAudio, just skips cleanup) |
| VAD | `vadEngine` | `.energyThreshold` (`Pipeline/EnergyVAD.swift`) | `.fluidAudio` (`Pipeline/FluidAudioVAD.swift`, Silero VAD) |
| Language detection | `languageDetectionEngine` | `.byTranscriber` (no-op, defers to the transcriber) | `.fluidAudioLID` (`Pipeline/LanguageDetectors.swift`'s `FluidAudioLanguageDetector`, transcribes a 60s prefix with FluidAudio Parakeet and classifies it with `NLLanguageRecognizer`) |
| Diarization | `diarizationEngine` | **`.fluidAudio`** (`FluidAudioDiarizer`, neural embeddings via `OfflineDiarizerManager`) — the one stage whose default *does* need a download; see "Choosing the diarizer" below | `.heuristic` (`SpeakerDiarizer`, pitch/timbre clustering) is the no-download fallback |
| Transcription | `transcriptionEngine` | `.appleSpeech` (`OnDeviceTranscriber`, fixed device locale) | `.fluidAudioParakeet` (`FluidAudioTranscriber`, multilingual, auto-detects language), `.whisperCpp` (`Pipeline/WhisperCppTranscriber.swift`, Whisper on device via whisper.cpp) or `.whisperAPI` (cloud) |
| Correction | `correctionEnabled` | `.none` (`NoOpTranscriptCorrector` — returns the input with no allocation or network work) | `.llm` (`Pipeline/LLMTranscriptCorrector.swift`, cloud LLM pass over the fused segments; off by default, see "LLM transcript correction" below) |

`TranscriptionService.transcribe` drives the stages in order:

1. **Preprocess** audio with the selected engine (`AudioPreprocessor` or a
   passthrough); on any failure it falls back to the original file so
   transcription never breaks. `AudioPreprocessor` runs **two passes**: the first
   renders the EQ'd signal into a `SpeechLevelMeter`
   (`Services/Pipeline/SpeechLevelMeter.swift`, O(1) memory) and the second applies
   the chain with the makeup gain that measurement implies. The chain used to lift
   every recording by a fixed +11 dB (a +8 dB makeup on top of the limiter's +3 dB
   pre-gain), which drives an already-healthy recording into near-constant limiting
   — and that distortion is the kind of artefact recent work finds *degrading*
   modern ASR rather than helping it. The gain decision itself
   (`SpeechLevel.makeupGainDB`) is pure and unit-tested: target speech at -20 dBFS
   RMS, never push the measured peak past -3 dBFS, clamp to 0…18 dB, never
   attenuate. Because the level is measured *before* the dynamics stage pulls peaks
   down, the peak bound is conservative by design — it errs quiet, and the limiter
   (now pre-gain 0, safety only) catches the rest.
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
   `diarizationPreprocessingEnabled` is off. That cleanup intentionally remains
   limited to the fast high-pass, stationary spectral subtraction and peak
   normalization stages, so cleanup does not block speaker separation.
   See "Diarization accuracy" below for how the `.fluidAudio` engine's speaker
   count is controlled and repaired.
5. **Fuse** transcript spans with speaker turns into `[TranscriptSegment]`
   via the pure, unit-tested `Pipeline/TranscriptFusion.swift`. A span is
   attributed to the speaker holding the most of its *duration* (not the
   speaker whose turn contains its midpoint — a sub-second turn under the
   midpoint would otherwise take the whole utterance), then consecutive
   same-speaker spans are merged, capped at 30s. `splitCoarseSpan` distributes a
   long span's words across turns proportionally when it crosses a handover;
   with word timestamps now available (below) it is the fallback, not the
   normal path.
6. **Correct** (opt-in) — an LLM pass over the already-fused, speaker-attributed
   segments, fixing spelling, punctuation and homophones. Skipped entirely when
   `effectiveCorrection == .none`, which is the default.

#### LLM transcript correction

The only pipeline stage that runs *after* fusion, and the only one that can be
enabled without a model download but still needs the network. It is off by
default because it makes paid cloud LLM calls on every transcription.

`TranscriptCorrecting` (`Pipeline/PipelineStages.swift`) states the contract
every conformer must honor, and the contract is the feature: **never throw,
always return `segments.count` segments in the same order, and only ever touch
`.text`.** A correction stage that could drop, merge or reorder segments would
invalidate every timestamp, speaker attribution and `[mm:ss]` citation
downstream of it, so those properties are not left to the prompt.

- **Enablement is a pair**, like `effectiveDiarization`: `effectiveCorrection`
  returns `.llm` only when `correction == .llm` *and* `correctionConsented`. The
  gate differs though — here it means "is this usable right now" (the correction
  provider has a key in the Keychain), not "has the user agreed to a download".
  This stage has no local model.
- **Not every segment is sent.** `isEligible` skips empty text, and sends a
  segment only when it carries no confidence signal at all (Apple Speech and
  FluidAudio Parakeet expose no per-token probability, so "can't rule it out")
  or a Whisper confidence below `lowConfidenceThreshold` (0.85). The target is
  marginal decodes; outright hallucinations were already dropped by
  `TranscriptQualityFilter` before fusion.
- **Batching** reuses the shape of `SummaryService.packWholeItems`: greedy packs
  bounded by both `maxBatchChars` (6,000) and `maxSegmentsPerBatch` (40), never
  splitting a segment.
- **`MeetingVocabularyExtractor`** (`Pipeline/`) builds a small vocabulary hint
  from the meeting's *own* transcript — recurring proper nouns, acronyms and
  terms with digits, `minOccurrences = 2` — so a word rendered correctly in one
  segment can resolve the same word misheard in another. It is sent once per
  request and deliberately not counted against `maxBatchChars`. Note the
  premise and its limit: this can only fix a term the ASR got right *somewhere*,
  so it does nothing for a name mis-heard consistently throughout.
- **`TranscriptCorrectionGuardrail`** bounds how far a proposed correction may
  drift before it is rejected: `maxWordChangeRatio` 0.35, `maxLengthRatio` 1.5,
  `minLengthRatio` 0.6 — a plausible spelling fix, not a paraphrase, invention,
  or emptied segment. It deliberately does **not** reuse
  `KurnTests/Support/Evaluation/`'s `WordErrorRate`/`TextNormalizer`: those are
  test-target-only, and `TextNormalizer` must never touch stored or displayed
  transcript text. The guardrail works on raw, unnormalized strings and only
  needs to bound the *magnitude* of a change, not produce a comparable metric.
- **Application is by id lookup.** `apply(corrections:to:)` walks the original
  array and replaces `.text` only where the id matches and the guardrail
  accepts. A missing id, a rejected correction, or an id matching no segment all
  leave the original untouched — which is what makes the "can't drop, merge or
  reorder" guarantee structural rather than a prompt instruction.
- **It fails open at every level.** `parseCorrections` reuses `ModelJSON`'s
  tolerant fence/prose stripping (the same parser behind `SummaryJSON.parse`);
  any JSON failure yields an empty map, so that whole batch silently leaves its
  segments unchanged rather than failing the transcription.

#### Word timestamps

Three engines report per-word timings and used to discard them; all four now
feed `TimedWordSpanBuilder` (`Services/TranscriptionTypes.swift`), which
FluidAudio already used. This is what lets `TranscriptFusion` place a speaker
handover *inside* a sentence instead of estimating the split from turn
durations (`splitCoarseSpan`, now the fallback).

| Engine | Where the timings come from |
| --- | --- |
| Apple Speech | `audioTimeRange` per `AttributedString` run, which the `.timeIndexedProgressiveTranscription` preset attaches. `String(result.text.characters)` used to flatten it away |
| whisper.cpp | `params.token_timestamps`, then `whisper_full_get_token_data`'s `t0`/`t1`; SentencePiece pieces are aggregated into words (a piece beginning with a space opens a new one) |
| Cloud | `timestamp_granularities[]` = `segment` + `word`, returned as a **flat top-level array** that `OpenAIProvider` regroups under the segment each word's midpoint falls in |

Two rules hold across all of them. **Missing timings are never an error** —
each engine falls back to exactly the span it produced before. And Apple's
timings are checked against the result's own range before being trusted:
timings on a different timeline would read as a correct transcript with every
word near zero, which nothing downstream could detect.

`timestamp_granularities[]` is an OpenAI extension a compatible endpoint need
not implement, so a `400`/`422` retries the upload once without it — losing word
timings to an old endpoint is acceptable, losing the transcription is not.

#### Where chunks are cut

`ChunkBoundary` (bottom of `Services/AudioChunker.swift`) moves each nominal
boundary to the nearest silence within 30 s, subject to a minimum chunk length,
and leaves it alone when there is none. A fixed grid cut wherever 5 or 10
minutes landed — mid-word far more often than not, and a boundary is also a
decoder restart, which is the condition Whisper invents text over.

The candidates come from `TranscriptionService`, because only it knows which
timeline the engine will see: **not** the original one when VAD compaction ran,
in which case the safe cuts are the gaps the compactor itself wrote
(`CompactionResult.map`), not the original speech regions. The chooser is pure
and must stay deterministic — a resumed transcription reuses its checkpoint only
when the chunk plan comes out identical, so a boundary that wandered between
runs would silently discard every completed chunk.

#### Choosing the diarizer

The default is `.fluidAudio`, and it is the only stage default that needs a
download. `.heuristic` — three scalars and one greedy nearest-centroid pass, one
speaker per VAD region — was what every user got who never opened Settings.

Flipping the default alone would have been worse than leaving it, because
FluidAudio downloads its models on first use: without consent that either
fetches a model for a feature the user never chose, or fails and returns one
turn for the whole meeting. So the selection is a **pair**:
`PipelineConfiguration.effectiveDiarization` reads `diarization` together with
`diarizationConsented` and steps back to `.heuristic` until the models are
consented to, with `diarizationFellBack` saying that it did.

That report is the other half. A user who never opens Settings never consents,
so without it "the default is now neural" would describe a setting rather than a
behaviour — which is why the transcript's diarization warning banner
(`MeetingDetailView`) carries the download action, and why
`ModelDownloadController` moved from `SettingsView` to `KurnApp`.

#### Diarization accuracy

The neural (`.fluidAudio`) diarizer's weak point is the speaker count, not the
segment boundaries — its VBx clustering step routinely drives every mixture
weight but one to ~1e-20 on far-field/single-mic audio, so the whole meeting
comes back as one speaker. Four things address that, all outside FluidAudio:

- **`AppSettings.fluidAudioSpeakerCount`** pins an exact count
  (`clustering.numSpeakers`), which makes the library re-cluster the raw
  embeddings with KMeans. It deliberately does *not* set `minSpeakers`: FluidAudio
  decides whether to apply a constraint by comparing the bounds against the
  *pre-clustering* estimate (tens, on any real meeting), so a floor is always
  already satisfied and never engages. Only an upper bound trips.
- **`Pipeline/SpeakerClusterRefiner.swift`** is the automatic rescue used when
  the count is left on Auto. `OfflineDiarizerConfig.exposeChunkEmbeddings` hands
  back the per-window speaker embeddings VBx clustered, so a collapse can be
  undone with no CoreML re-run: re-cluster them (average-linkage AHC, speaker
  count chosen by silhouette), keep the diarizer's own segment boundaries, and
  re-attribute them by overlap-weighted vote. A split is only accepted when the
  cluster centroids are at least `minSpeakerSeparation` apart — the same
  same-speaker calibration FluidAudio's own agglomerative step uses — so a
  genuinely single-speaker recording is left alone.
- **`Pipeline/SpeakerTurnSmoothing.swift`** runs on every FluidAudio result:
  merge same-speaker turns across short gaps, absorb sub-second turns into
  their neighbours (the mid-sentence flip), drop speakers with negligible total
  speech. It never returns an empty result for a non-empty input.
- **`FluidAudioDiarizer.processTimeout(forAudioDuration:)`** scales the
  processing budget to the recording. A flat timeout falls back to a single
  whole-clip turn, which reads as "diarization is inaccurate" rather than as
  the timeout it is.

#### Speaker identity

`"Speaker 2"` identifies nobody: the diarizer hands those labels out in order of
first appearance, freshly on every run, so a re-transcription routinely renames
the same voice. `Speaker` rows carry a name the user typed, and keying them on
the label was wrong in both available directions — deleting a row whose label
stopped appearing threw the name away, and keeping it under the old label would
hand that name to whoever the diarizer now calls Speaker 2.

So identity is the voice. `FluidAudioDiarizer` returns a `DiarizationOutcome`
(turns **plus** `voiceprints`) rather than turns alone; `SpeakerVoiceprints`
averages the model's per-window embeddings into one L2-normalized vector per
speaker, computed *after* smoothing and any collapse rescue so it describes the
speaker as finally reported. `Speaker.voiceprintData` persists it through
`VectorData`, in the store, never in a sidecar file.

`TranscriptionViewModel.syncSpeakers` then reconciles as a total assignment
rather than a diff: `SpeakerIdentityMatcher` matches **every** stored row
against **every** new label (the common case is the label set staying the same
while the assignment permutes — matching only what appeared or disappeared
misses exactly that), voice wins, label identity fills the rest, and the whole
mapping is applied at once so a swap has no colliding intermediate state. The
same-voice threshold is `SpeakerClusterRefiner.minSpeakerSeparation`, inherited
rather than invented.

Where no voiceprint exists — the heuristic engine, or a transcript from before
this — identity genuinely cannot be recovered, so only the conservative half
applies: **a row the user has named is never deleted.** Preserved rows can then
outlive their labels, which is why `MeetingDetailTabs` filters the chips and the
speaker list to labels actually present in the transcript.

Two limits worth knowing. Labels are produced per *recording* while `Speaker` is
per *meeting*, so two recordings' "Speaker 1" are still conflated. And nothing
crosses meetings — "Ana" in one has no relation to "Ana" in another; the stored
voiceprint is the material a future change would use for that.

#### Whisper hallucination filtering

Whisper's failure mode is not a wrong word, it is a fluent invention over
silence, music or noise — often the same sentence looped — with nothing in the
text to distinguish it from a real one. The decoder does report its doubt, so
both Whisper engines run their spans through
`Pipeline/TranscriptQualityFilter.swift` before returning:

- **silence** — `no_speech_prob > 0.6` **and** `avg_logprob < -1.0`. The
  conjunction is Whisper's own rule and matters in both directions: a confident
  decode overrides a high no-speech probability, and a low log-probability alone
  must not drop a quiet talker.
- **compression** — `compression_ratio > 2.4`. Cloud only; the field arrives in
  `verbose_json` (`WhisperVerboseResponse`, which modelled only start/end/text
  before) and whisper.cpp has no equivalent.
- **repetition** — found in the text instead, which is why the detector exists.
  It is deliberately blind to *what* repeats (a phrase blocklist would need
  maintaining in seven languages and still miss the next one): it looks for one
  cycle of tokens covering most of the segment. The coverage floor is what keeps
  a stutter inside a good sentence from taking the sentence with it, and scripts
  written without spaces fall back to per-character units.

Surviving spans are stamped with the confidence their log-probability implies
(`exp(avgLogProb)`), which is what finally fills `TranscribedSpan.confidence`. A
surviving segment carrying word timings is emitted **one span per word** rather
than one per segment (`TranscriptQualityFilter.ScoredSpan.words`); the words ride
with their segment through the filter rather than being judged separately,
because the quality signals are per segment and a hallucinated sentence's words
are exactly as invented as the sentence.
whisper.cpp's own temperature-fallback thresholds (`logprob_thold`,
`no_speech_thold`, `entropy_thold`) are set from the same constants, so its retry
and this post-filter judge a segment by one set of numbers.

VBx's warm-start priors are left at FluidAudio's community-1 defaults. Raising
them to fight the collapse (an earlier attempt) just trades it for the opposite
failure, since a diffuse prior makes VBx keep the agglomerative init's cluster
count.

Every stage call is preceded by `ResourceGuard.requireTranscriptionHeadroom()`
(`Infrastructure/ResourceGuard.swift`, 750MB disk floor), which throws
`AppError.resourceUnavailable` rather than let the pipeline run out of disk
mid-transcription; `TempFileCleaner.cleanupOrphanedTempFiles()` runs at the
start of every `transcribe` call to sweep temp files (`kurn_clean_`,
`kurn_vad_`, `kurn_diar_`, `kurn_chunk_`, `kurn_compact_` prefixes, plus stale
Whisper upload spool files) older than an hour that earlier interrupted runs left
behind; the same cleaner backs the manual "Free up space" action in Settings.

Progress is reported via a `@Sendable` `PhaseHandler` (`TranscriptionPhase`); the
receiver must hop to the main actor itself.

#### On-device Whisper (whisper.cpp)

`.whisperCpp` is Whisper's accuracy and language coverage with nothing leaving
the device. It is the one engine whose dependency is a **binary**: the app links
whisper.cpp's official prebuilt XCFramework through the local
`Packages/WhisperCpp` package (`.binaryTarget(url:checksum:)`, so nothing large
lands in git). Bumping the version means bumping the URL *and* the checksum
(`swift package compute-checksum` on the release zip). Everything that touches
the library is guarded by `#if canImport(whisper)` with a throwing `#else` stub —
the same pattern the FluidAudio files use, and required because `KurnTests`
doesn't link the package.

Three things are deliberately *not* parallel to the FluidAudio stack:

- **Its own downloader.** GGML weights come straight from HuggingFace
  (`Services/WhisperCppModelDownloader.swift`, a `URLSessionDownloadTask` bridged
  to async/await), because whisper.cpp ships no downloader of its own. This is
  the app's only direct model download. The files land in
  `Application Support/WhisperCpp/Models/<variant>/`, excluded from iCloud
  backup, and `ModelStore.ModelGroup.whisperCpp.root` points there rather than at
  FluidAudio's cache — the snapshot-diff folder discovery is skipped for this
  group since the app names the folders itself.
- **A variant axis.** `WhisperCppModel` (`Models/WhisperCppModel.swift`) offers
  base/small/large-v3-turbo, all q5-quantized, defaulting to `.small`. Because
  the model set has to say *which* file to fetch, `ModelSet` gained a payload
  (`.whisperCppASR(WhisperCppModel)`) and `TranscriptionEngine.requiredModelSet`
  is a function rather than a property. Switching variants re-runs the consent +
  download flow, and the variant is folded into the transcription checkpoint's
  `providerID` so a resume can't splice two models' output together.

  The variant axis forces two departures from the FluidAudio consent UI, both in
  `ModelDownloadController`. First, selecting the engine can't use the plain
  yes/no consent dialog: the size picker only renders once whisper.cpp *is* the
  selected engine, i.e. after the download it would otherwise have picked for
  the user. `showingWhisperCppModelChoice` breaks that circle with a
  `confirmationDialog` listing every variant and its size, so choosing a size
  and consenting are one step. (`showingWhisperCppConsent` remains for the size
  picker's own path, where the variant is already chosen.) Second, the download
  gate keys on the file being present, not on `whisperCppModelsConsented` —
  each variant is a separate file and Storage deletes them individually, which a
  single consent flag can't express. That individual deletion is why Storage
  lists one row per installed variant
  (`ModelStore.ModelGroup.listsFoldersSeparately`, the only group that does), and
  why `deleteModel` clears consent and reverts the engine only when the *last*
  variant is gone, re-pointing `whisperCppModel` at a surviving one otherwise.
- **Chunked, not single-pass.** `whisper_full` takes the whole clip as one
  `[Float]`, so the transcriber reuses `AudioChunker` +
  `ChunkedTranscriptionRunner` at 5-minute chunks (the cloud engine uses 10).
  That caps resident samples at ~19 MB instead of ~460 MB for a two-hour meeting,
  and brings resumable checkpoints and per-chunk cancellation with it. Audio is
  decoded to whisper's required 16 kHz mono float by the existing
  `VADAudioLoader.monoSamples`. `whisper_full` blocks, so the context lives on a
  private serial `DispatchQueue` and never occupies a cooperative thread.

`AudioChunker` **slices, it does not re-encode**: the export runs with
`AVAssetExportPresetPassthrough`, so a chunk inherits the source's format —
16 kHz mono, since `AudioPreprocessor` has already rendered it there. The fixed
`AVAssetExportPresetAppleM4A` it used to use carries the preset's own sample rate
and bit rate, unrelated to the source, so it re-encoded that cleaned audio *up*,
inflating every cloud upload and temp file and spending a lossy generation for
detail nothing downstream reads back. `preferredPreset` asks
`AVAssetExportSession.determineCompatibility` rather than assuming, and keeps the
old preset as the fallback. Two consequences to preserve: a passthrough export
cuts on compressed-frame boundaries, so `Chunk.offset` stays the *requested*
start (a running sum of measured durations folds that slop in once per chunk and
drifts forward), and `AudioChunkerTests` asserts the chunks keep the source's
format and size — the older assertions only covered counts and offsets, which is
why the inflation went unnoticed.

Like the FluidAudio engines it can't run from the background (Metal is
unavailable there), so `TranscriptionScheduler.pipelineUsesCoreML` covers it too.

#### FluidAudio on-device models and download consent

The FluidAudio-backed engines above (and the live transcription preview below)
download CoreML models on first use rather than bundling them, so enabling one
never fetches models for a feature the user hasn't opted into:

- `Infrastructure/ModelDownloadConsent.swift` is the single place that
  triggers a download, one `ModelSet` case (`.liveTranscriptionASR`,
  `.onDeviceASR`, `.diarization`, `.vad`, plus `.whisperCppASR`) at a time, gated
  behind a matching `AppSettings.*Consented` flag the user sets in Settings.
  `.whisperCppASR` is handled *before* the `#if canImport(FluidAudio)` branch so
  it still works in a build without FluidAudio linked. Each
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
instructions plus suggested sections; built-ins are `.general`, `.standup`,
`.interview`, and `.outline`, collected in `defaultTemplates`), and the model
returns a flexible
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

**A meeting accumulates summaries; it does not have one.** `Meeting.summaries`
is `[Summary]`, one per generation run, and each `Summary` records the
`templateName`, provider and model it came from. Running the same transcript
through General and then Standup keeps both, so templates can be compared
side by side instead of overwriting each other — which is why the summary
provenance is stored per summary rather than read from current settings.

The consequences show up across the UI, and new code should follow the same
convention rather than reaching for a singular summary:

- `Meeting.latestSummary` (max by `createdAt`) is the **default selection**,
  not the meeting's summary. `MeetingDetailView` holds `selectedSummaryID` and
  re-points it at the latest whenever `meeting.summaries.count` changes, so a
  freshly generated summary is the one shown.
- `MeetingDetailTabs` renders a switcher over `summaries` sorted newest-first,
  with per-summary delete. `MeetingsListComponents` shows a count badge, and
  `MeetingShareSelectionView` lets the user pick which summaries to export.
- `MeetingFilter`'s `hasSummary` tests `summaries.isEmpty`, not a nil check.
- Single-summary consumers pick deliberately: `MeetingExport` and the chat's
  context builder both take `latestSummary`, because "the newest one" is the
  sensible default when only one can be used.

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
  rows. Indexing is automatic after transcription completion and a low-priority
  launch/foreground **backfill** re-indexes meetings transcribed before the
  feature existed (or by an older embedder, tracked via `modelIdentifier`). Gated
  by `AppSettings.semanticSearchEnabled` (on by default). Title generation,
  indexing, and optional wiki generation run as independent best-effort
  post-transcription work: the recording is already `.done`, and the UI reports
  each enrichment phase separately instead of holding the transcription bar at
  "Finalizing".
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
  chat-related is persisted, so there is nothing extra to encrypt. When
  `wikiEnabled` is on, the library-wide path additionally grounds on the
  condensed per-meeting articles — see "Derived artifacts" below for why that
  answers synthesis and counting questions retrieval alone cannot.

### Derived artifacts: wiki and documents

Two further LLM-derived artifacts sit on top of a finished transcript. Both are
`@Model`s in the one app store, so their text is encrypted at rest by
`ModelStoreProtection` with everything else — the same rule as `SemanticChunk`:
transcript-derived text never goes to a loose file or a cache.

**`WikiArticle`** (`Models/WikiArticle.swift`) is one condensed article per
meeting: dense, factual, timestamped notes over the whole transcript —
decisions, action items, numbers, names. `Meeting.wikiArticle` is one-to-one and
`.cascade`, so it dies with its meeting.

- **Why it exists is `MeetingChatSynthesis`**, not the reading experience. The
  library-wide chat gives the model *both* groundings in one prompt: the
  retrieved verbatim excerpts (for exact quotes and tappable `[mm:ss]`
  citations) and the condensed articles of the meetings in play (for synthesis,
  comparison and counting). A hybrid question — "what did we decide about X and
  how did it evolve" — is then answered in a single pass instead of being routed
  to one strategy or the other. Articles are 1–4 KB, so a handful of them plus
  the excerpts fit the single-pass budget where whole transcripts never could.
  Over budget — chiefly a global aggregate over a large library — the articles
  are packed **whole, never split** into blocks and map-reduced in the same shape
  as `SummaryService.mapReduce`, with the excerpts carried into the reduce so
  citations survive. It is also readable from the meeting's detail screen
  (`MeetingWikiView`) for transparency.
- **`WikiService` delegates rather than reimplements.** It calls `SummaryService`
  with that service's internal `notesTemplate` — the same "capture every
  decision, action item, number, name, with `[mm:ss]`" format the summary's map
  stage already produces — so chunking, staging, cancellation, retry and
  rate-limit behaviour are inherited rather than duplicated. A long meeting is
  condensed in stages, a short one in a single pass.
- **Staleness is tracked, and a rebuild replaces.** `sourceContentHash` /
  `generatorModelIdentifier` are the wiki analogue of `SemanticChunk`'s
  `modelIdentifier` check; when the transcript or the generating model changes
  the article is rebuilt, never appended to. `WikiCoordinator` (`ViewModels/`)
  owns the main-actor/SwiftData half; the LLM call runs off-main in the service.
- Gated by `AppSettings.wikiEnabled`, **off by default** — it makes a paid cloud
  LLM call per transcription.

**`GeneratedDocument`** (`Models/GeneratedDocument.swift`) is free-form Markdown
synthesized from one or more transcripts against a user's prompt, surfaced by
`DocumentsListView` / `DocumentCreateView` / `DocumentDetailView`.

- Sources are chosen by `DocumentSourceKind` — `.transcripts`, `.tags`, or
  `.folders`. `DocumentSourceResolver` (`Models/`) holds that resolution,
  including folder traversal, as pure logic so the SwiftUI view never owns the
  domain rule about which meetings a tag or folder selection stands for.
- **Source labels and meeting ids are snapshots.** Deleting a meeting, retagging
  it, or moving it between folders must not retroactively damage a document that
  was already generated, so the document keeps its own copy of what it was built
  from rather than a live relationship.
- `DocumentGenerationService` map/reduces long selections, so picking a folder
  never silently truncates the meetings that happen to sort last.

### Settings & secrets

`AppSettings` (`@MainActor @Observable`) holds non-secret preferences in
`UserDefaults`, persisting on `didSet`. **API keys never go here** — they live in the
Keychain via `KeychainManager`, keyed by `AIProvider.keychainAccount`. Built-in
providers keep a `legacyKeychainAccount` for backward compatibility; custom providers
use `provider_<id>_api_key`. A few preferences also mirror to non-persistent global
state in their `didSet` — e.g. `logLevel` pushes to `AppLog.minimumLevel` so the
logging gate reflects the user's choice immediately (also synced once on init).

Settings is a **hub, not one long form**. `SettingsView` is a short list of
`NavigationLink` rows grouped into Intelligence / Capture / Library / System,
each pushing a focused screen in `Views/Settings/` (`ProvidersSettingsView`,
`SummarySettingsView`, `SemanticSearchSettingsView`, `RecordingSettingsView`,
`TranscriptionSettingsView`, `TagsSettingsView`, `StorageSettingsView`,
`DiagnosticsSettingsView`, `AboutSettingsView`). Three things deliberately stay
on the root because they can't belong to any one screen: the destructive
"Delete all data" reset, the `keyRevision` counter passed down so provider rows
re-read Keychain status, and `ensureSelectedProviderIsConfigured()` /
`ensureWhisperSelectionIsAllowed()` (`SettingsSections.swift`), which must run
whichever screen the user drilled into — a key removed anywhere must never leave
the summary or transcription provider pointing at one without a key.

`ModelDownloadController` (`ViewModels/`, `@MainActor @Observable`) owns the
FluidAudio download machinery — which `ModelSet` is in flight, the per-feature
consent dialogs, the engine choices deferred until a download succeeds, and the
installed-model list. It is created in `KurnApp` and injected app-wide: the
Transcription, Recording and Storage screens all read `isDownloading` and can
all start a download, and so can the diarization prompt on a meeting's
transcript — two controllers would each track a download the other knew nothing
about. Screens that can trigger one attach `.modelDownloadAlerts(_:settings:)`.

**Three settings are off by default, for two different reasons.** `wikiEnabled`
and `correctionEnabled` make paid cloud LLM calls on *every* transcription, so
neither can be a default. `templatesSyncEnabled` costs nothing per
transcription and involves no LLM at all, but it is the first setting that
sends anything off the device — which is reason enough here.

**Template sync is iCloud key-value, deliberately not CloudKit.**
`CloudSettingsSync` (`Infrastructure/`) is a thin wrapper over
`NSUbiquitousKeyValueStore`, in the same spirit as `KeychainManager`: no
business logic, just get/set/observe. Adopting SwiftData+CloudKit instead would
pull the app's whole model container — meetings, transcripts, summaries —
toward iCloud, which is exactly what the local-first design rules out. Only
`AppSettings` decides what gets written; the `CloudKeyValueStore` protocol is
the seam that keeps this testable on CI, which has no signed-in iCloud account.
`TemplateSyncMerger` is the pure merge: per id, whichever side has the later
`updatedAt` wins. Built-ins never sync — `AppSettings.mergedTemplates` already
re-seeds them locally — so only user-created templates are reconciled. Deletions
deliberately do **not** propagate in this v1: an id reappearing after a delete
just means the other device hasn't synced its own delete yet.

`UsageStats` (`Models/UsageStats.swift`) holds local-only counters — recordings
completed, per-`TranscriptionEngine` and per-`SummaryTemplate` tallies —
persisted as a JSON blob in `AppSettings` the same way `summaryTemplates` is,
and rendered by `UsageInsightsView`. Pure on-device self-observability; it is
never transmitted anywhere.

### Crash and hang diagnostics

`Infrastructure/CrashReporting/` turns MetricKit payloads into readable reports
that stay on the device unless the user explicitly shares one.

`DiagnosticsSubscriber` registers with `MXMetricManager` unconditionally in
`KurnApp.init()` — so subscription never depends on `AppSettings`' construction
order — and checks consent at **delivery** time instead, reading `UserDefaults`
directly in `didReceive(_:)`. Without consent every payload is discarded without
touching disk. Nothing is transmitted automatically under either setting:
reports leave the device only through the explicit Share action in
`DiagnosticReportsListView`. iOS usually delivers these in a batch on the next
launch after the crash or hang, not at the moment it happens.

`DiagnosticReportFormatter` is pure and MetricKit-free *in its signature* — it
takes primitives the caller already extracted from the live payload — so it is
unit-testable against hand-authored fixture JSON rather than OS-constructed
objects. It re-serializes Apple's own `jsonRepresentation()`, which already
carries symbolicated-if-available frames and thread state, instead of walking
the call stack by hand and risking silent information loss.
`DiagnosticReportStore` owns the on-disk side.

### Navigation chrome (Liquid Glass)

The app used to hide the navigation bar on every main screen and hand-draw its
own header, bottom bar and floating record button. It no longer does — the rule
now is **use the system's toolbar, and only fall back to custom content when a
toolbar would be the wrong control**:

- `MeetingsListView` uses `.navigationTitle` + `.searchable` and a single
  `.toolbar { listToolbar }`. The toolbar content lives in
  `Views/MeetingsListToolbar.swift` as an extension, which is why several of
  `MeetingsListView`'s members are non-private — a `private` member is invisible
  to an extension in another file.
- **`ToolbarSpacer` is how glass groups are split.** In `listToolbar`, the
  library/filter/Ask items share one glass capsule and
  `ToolbarSpacer(.flexible, placement: .bottomBar)` gives the record button
  (`.buttonStyle(.glassProminent)`, `.tint(Theme.accent)`) a capsule of its own.
  `MeetingDetailView`'s `toolbarContent` uses `ToolbarSpacer(.fixed,
  placement: .topBarTrailing)` the same way to separate the favorite toggle from
  the overflow menu.
- Two places deliberately stay custom content: `RecorderView`'s transport
  controls (full-width, thumb-sized targets mid-recording — they take
  `.buttonStyle(.glass)`/`.glassProminent` but are not toolbar items), and
  `MeetingChatView`'s composer (an input surface, attached via
  `.safeAreaBar(edge: .bottom)`).
- `MeetingDetailView`'s four sections are a segmented `Picker`, not a bottom
  bar: they're view modes of one meeting rather than top-level destinations, and
  a bottom bar there would collide with the Chat tab's composer.
- Do not reintroduce `.background(.bar)`, hand-drawn `Divider` bar tops, or
  `.toolbar(.hidden, for: .navigationBar)` on a main screen. The lock screen
  used to be the one exception; it no longer needs to be, because it is not in
  the navigation hierarchy at all — it renders in the cover window above it
  (see "Secure local storage for recordings"), so there is no toolbar to hide.
- Accessibility identifiers used by `KurnUITests/ScreenshotUITests.swift`
  (`nav.settings`, `meetingCard`) must survive any further chrome rework.

### Accessibility

VoiceOver, Dynamic Type, and Reduce Motion are supported throughout the app,
the Watch companion, and the Lock Screen/Dynamic Island Live Activity —
enforced by lint and by a CI audit test, not just convention:

- **`Kurn/Infrastructure/Accessibility/`** — `ColorAccessibility.swift` gives
  `FolderColorPalette`/`TagColorPalette` (closed, curated hex sets) a static
  `accessibleName(for hex:)` lookup into localized names, so a color swatch
  reads as "Red"/"Blue" rather than a hex string or nothing at all.
  `MotionSafeAnimation.swift`'s `View.kurnAnimation(_:value:)` wraps
  `@Environment(\.accessibilityReduceMotion)` so call sites don't each
  re-implement the check; a `repeatForever` loop (e.g. `RecorderView`'s
  `PulsingDot`) instead gates its own start on that environment value and
  renders the final static state when Reduce Motion is on, since wrapping a
  looping animation in `kurnAnimation` alone doesn't stop it from starting.
- **Dynamic Type** — `Theme.swift`'s "Typography" section provides semantic,
  Dynamic-Type-aware `Font` constants (`Font.system(_:design:weight:)`, never
  `Font.system(size:)`) that all real reading text should use. Fixed-geometry
  UI (icon glyphs, a circular avatar, `RecorderView`'s big timer) stays a
  fixed size via `@ScaledMetric(relativeTo:)` with a capped
  `.dynamicTypeSize(...DynamicTypeSize.accessibility2)` on that subtree,
  rather than scaling unbounded and breaking a fixed-dimension layout — this
  is a deliberate, narrow exception, not the app-wide default.
- **Lint guardrail** — `.swiftlint.yml`'s opt-in `accessibility_label_for_image`
  and `accessibility_trait_for_button` rules are `severity: error`, so a new
  unlabeled icon-only control or untraited tappable view fails CI, not just a
  warning. Note the rule attributes a violation to the *enclosing view's
  declaration line*, not the modifier call site — a misplaced
  `// swiftlint:disable:next` comment a few lines below the real declaration
  silently does nothing. When violations need triage beyond what the console
  log shows (SwiftLint lints in parallel, so log-line adjacency to a
  "Linting 'X'" message is not a reliable attribution signal), the CI job
  also uploads `swiftlint-report.json` (`--reporter json`, exact file/line)
  as a build artifact.
- **`KurnUITests/AccessibilityAuditUITests.swift`** — runs
  `XCUIApplication.performAccessibilityAudit(for: [.sufficientElementDescription,
  .trait])` over the Recorder, Meeting Detail (Transcript/Summary tabs),
  Settings root, and Folder Form screens, reusing the same seeded
  `"UI-Testing-Screenshots"` launch state and identifiers as the screenshot
  tests. It's wired into the `Kurn.xcscheme`'s default `TestAction` alongside
  `KurnTests` (`KurnUITests` wasn't in the scheme before this was added, so it
  never ran in CI), with `ScreenshotUITests` explicitly skipped there since it
  depends on fastlane's snapshot setup.
- **Speaker identity, not color, carries meaning** everywhere it matters: the
  Live Activity's Lock Screen status dot differs by *shape* (pause icon vs.
  filled circle), not only color, and status text is never color-only.
- **Locale parity** — `KurnWatch/` and `KurnLiveActivityExtension/` each carry
  the same 7 locales as the main app (`en`, `pt-BR`, `es`, `fr`, `it`, `de`,
  `zh-Hans`), not just `en`/`pt-BR` — a VoiceOver user on the Watch or reading
  the widget in one of the other 5 languages would otherwise hear/read
  English. Keep new strings in these two targets in sync across all 7 the
  same way the main app's `Localizable.strings` are.
- **Known gaps, left out of scope deliberately**: `ScreenshotUITests` and the
  accessibility audit both run at the system's default text size, so neither
  catches a layout break at large accessibility text sizes — that needs
  manual testing (Accessibility Inspector / Simulator) per screen.
  `KurnWatchUITests` doesn't run in `iOS CI` today (no separate watchOS test
  destination is configured), so Watch VoiceOver is verified manually, not by
  CI.

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
