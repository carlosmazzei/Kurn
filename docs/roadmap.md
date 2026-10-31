# Roadmap

The single list of **work that is still open**. Everything that has shipped is
documented where it lives permanently — `CLAUDE.md` for architecture,
invariants and conventions, the `README.md` for what the app does — and is
deliberately not repeated here. When an item below ships, move what is worth
keeping into those two files and delete the item; do not open a separate plan
document for a new track, add a section here instead.

The verdicts matter less than the reasoning attached to them. A "no" with a
recorded reason stops the same idea from being re-litigated every few months; a
"yes" with its coupling point named is most of the design work already done.

## The filter

Kurn is a local-first meeting recorder. That sentence is load-bearing, and these
five invariants are what it decomposes into. Every entry below is judged against
them, and where an entry creates tension the tension is stated rather than
smoothed over.

|        | Invariant                                             | What holds it up today                                                                                                  |
| ------ | ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| **I1** | Nothing leaves the device without an explicit request | Network only on opt-in cloud transcription or a cloud LLM provider; a fresh install works offline                       |
| **I2** | Meeting-derived content lives in the encrypted store  | `ModelStoreProtection` (`.completeUnlessOpen`) covers the SwiftData store; never a loose file, cache, or `UserDefaults` |
| **I3** | Accuracy is measured, not asserted                    | `KurnTests/Support/Evaluation/` (WER, DER, RTTM) plus the public-dataset matrix                                         |
| **I4** | The subject is meetings, not dictation                | The value is a 90-minute multi-speaker file, not a six-second insert                                                    |
| **I5** | Heavy dependencies are opt-in                         | `ModelDownloadConsent` gates every model fetch, with a working fallback when declined                                   |

Two further rules follow from I1 that are easy to violate by accident: a feature
that makes a paid cloud call *per transcription* cannot ship enabled (this is
why `wikiEnabled` and `correctionEnabled` default off), and a feature that
merely moves data off-device still needs consent even when no LLM is involved
(why `templatesSyncEnabled` defaults off).

## Product capabilities

### Adopt

Ordered by payoff, not by effort. None of them creates tension with the five
invariants.

#### F2 · User-maintained meeting glossary

|                |                                                                                                   |
| -------------- | ------------------------------------------------------------------------------------------------- |
| **Couples to** | New `@Model` in the store · `WhisperCppTranscriber` · `OpenAIProvider` · `LLMTranscriptCorrector` |
| **Invariant**  | I2 for storage; I3 because the effect is measurable                                               |
| **Effort**     | Medium                                                                                            |

`MeetingVocabularyExtractor` derives terms from the transcript itself with
`minOccurrences = 2`, on the premise that the term appears spelled correctly
*somewhere* in the same recording. That premise fails for exactly the words
that matter most in a meeting: a participant's name, a product name, an
internal acronym — mis-heard consistently, in all fourteen occurrences, with
nothing correct to copy from.

**Two application points, with uneven engine support.**

- *Before ASR, as a decoding hint.* whisper.cpp accepts `initial_prompt` in
  `whisper_full_params`; cloud Whisper accepts `prompt`; Apple Speech exposes
  contextual strings. FluidAudio Parakeet has no equivalent hook. This unevenness
  must surface in the UI rather than be promised uniformly across engines.
- *After ASR, as deterministic replacement* over `TranscriptSegment.text`, and as
  a term list handed to `LLMTranscriptCorrector` alongside the auto-extracted
  ones. This path works for every engine, which is what makes the feature
  coherent despite the gap above.

**The identity connection.** `Speaker` rows carry user-typed names. Those are
free glossary entries for the meeting they belong to — and because
`Speaker.voiceprintData` matches voices across runs and meetings, a name
learned once can seed the hint for later meetings with the same voice.

This is also the only entry whose effect the project can *prove*: run the
public-dataset matrix before and after and compare WER. Under I3, that is part
of shipping it, not an afterthought — and since KurnCore runs `swift test` on
Linux, the pure half of it is verifiable without waiting on simulator CI.

#### F4 · Calendar context at record time

|                |                                                                          |
| -------------- | ------------------------------------------------------------------------ |
| **Couples to** | `MeetingFormView` · `Speaker` · `SpeakerIdentityMatcher`                 |
| **Invariant**  | I2 — attendee names are meeting-derived content, so they go in the store |
| **Effort**     | Low-medium                                                               |

Offer the calendar event happening now as the meeting title, and its attendees
as pre-created `Speaker` rows. Read-only EventKit access with
`NSCalendarsUsageDescription`.

This is more than a convenience. Cross-meeting voice matching already suggests
a name typed in another meeting (`TranscriptionCoordinator+CrossMeetingSpeakerMatch`),
but a name only enters the system when a user types one *somewhere*. An
attendee list gives the app a *candidate set* of names for the voices in the
room, independent of whether a name was ever typed before — the half of
speaker identity the voiceprint work could not deliver on its own. It wants F2
in place to pay off fully, since attendee names are also glossary entries.

#### F5 · Action items to Reminders

|                |                                                                       |
| -------------- | --------------------------------------------------------------------- |
| **Couples to** | `SummarySection.items` · the `AutoTagConfirmView` review pattern      |
| **Invariant**  | Compatible — local write; any syncing is the user's Reminders setting |
| **Effort**     | Low-medium                                                            |

`Summary.sections` already produces `SummarySection.items`. Today they are text a
person retypes somewhere else. Writing them as `EKReminder`s, with the meeting in
the note and a deep link back, is a small amount of work on top of output that
already exists.

Non-negotiable: a review step before anything is written. LLM output must never
silently create reminders — which is precisely the pattern `AutoTagConfirmView`
already establishes for suggested tags. Reuse it rather than inventing a second
review flow.

#### F6 · Import audio recorded elsewhere

|                |                                                                       |
| -------------- | --------------------------------------------------------------------- |
| **Couples to** | New extension target · `RecordingProtection` · `OfflineAudioRenderer` |
| **Invariant**  | Compatible — a file comes in, nothing goes out                        |
| **Effort**     | Medium                                                                |

Kurn can only transcribe what Kurn recorded: there is no Share Extension, no
Action Extension, no document picker. But plenty of meetings are captured by
something else — the system voice recorder, a conferencing tool's export, a file
a colleague sent.

The pipeline already starts from a file: `TranscriptionService.transcribe` works
from a `Recording`'s `.m4a`. Import is mostly creating the `Meeting` and
`Recording` and landing the file in `Documents/Recordings/` through
`RecordingProtection` — and through the same `RecordingCaptureState` /
`RecordingFileFinalizer` contract a capture uses, since every consumer gates on
`Recording.isReadyForConsumption`.

**The format trap.** 24 kHz mono AAC is guaranteed for the app's own files, not
for imports. `RecordingCompactor`, `Recording.effectiveBitRate` and the offline
render path all assume the app's encoding. Either normalize on ingest —
`OfflineAudioRenderer` already performs exactly this kind of render — or make
tolerance of foreign formats an explicit, tested requirement at each of those
points. Choosing neither is how a silent corruption bug gets shipped.

### Evaluate

Good ideas carrying a condition, a disproportionate cost, or an unresolved
tension.

#### F7 · OAuth for cloud providers

Signing in with an account the user already pays for, instead of a separately
provisioned API key. It changes nothing about the privacy posture — cloud is
still cloud — but it changes *who can reach it*: today the barrier is creating a
developer account and entering a credit card.

The cost is real: OAuth with PKCE, token refresh, a local callback.
**Condition:** the on-device provider (`FoundationModelsProvider`) already
delivers "works with no key at all" wherever Apple Intelligence is available.
How often that is actually true across the install base is unmeasured (see
"On-device LLM" under follow-ups) — that number decides whether F7 is worth it.

#### F8 · Reading mode

Filler-word removal and paragraph reflow for readability. This **cannot be a
pipeline stage**: `TextNormalizer` is explicitly comparison-only, and the stored
transcript keeps its punctuation and casing by design.

So: a render-time transform over `Transcript.segments`, plus an option in
`MeetingExport` (an `ExportDocument` transform, so every format gets it). Cheap,
pure and testable — a natural KurnCore candidate.

#### F9 · On-device translation of transcripts

Apple's `Translation` framework runs entirely on-device with language packs
downloaded on demand. Kurn already transcribes many languages; reading an
English meeting in Portuguese is a real case and the fit with I1 is exact.
(Summary translation through the selected LLM provider already exists; this is
about the transcript, and about doing it with no provider at all.)

The pack download is a heavy dependency, so it goes through I5 — reuse the
`ModelDownloadConsent` pattern rather than fetching independently.

#### F10 · Spotlight indexing

The value is obvious: find a meeting from system search. The problem is specific
and disqualifying by default. The `CoreSpotlight` index lives outside the app's
store, and I2 exists precisely so that `.completeUnlessOpen` covers every piece
of transcript-derived text. Indexing excerpts would place meeting content in a
system index the app does not control and cannot encrypt.

Two defensible versions: index **title and date only**, with no transcript text;
or make excerpt indexing an explicit opt-in with the trade-off written in plain
language. **Do not index excerpts by default.**

## Diarization

### D4 · Does sherpa-onnx actually resist the VBx collapse?

`.sherpaOnnx` shipped as an opt-in, segmentation-first diarizer whose only
justification is surviving the failure `FluidAudioDiarizer` is known for — VBx
collapsing a far-field meeting into one speaker. On AMI it measures ~17pp
*behind* `fluidAudio` on DER (`docs/pipeline-evaluation.md`, "sherpa-onnx vs.
FluidAudio"), but FluidAudio did not collapse on that material, so the run
could not test the one thing the engine was added for.

**Next measurement:** a dispatch with `diarization_engines: fluidAudio,sherpaOnnx`
for both raw DERs in one run, read **per file** rather than in aggregate — the
question is whether any single meeting shows FluidAudio collapsing and
sherpa-onnx holding. If none does on a corpus that exercises the collapse
(VoxConverse, single far-field mic), the engine is a candidate for removal.
Its clustering threshold (`SherpaOnnxDiarizer`) is likewise untuned until that
data exists.

### Speaker names from outside the app

Cross-meeting voice matching is in place, but it can only suggest a name the
user already typed somewhere. Candidate names from the calendar are F4.

## App Store presence

The listing itself is in the repository (`fastlane/metadata/`, the captions in
`scripts/screenshots/config.json`) and `Tools/validate_store_metadata.py`
enforces the search rules it is written against. What is left needs App Store
Connect or a decision the repository cannot make:

- **Custom product pages with keywords.** Since July 2025 a custom product page
  can be assigned keywords and is then shown in organic search for them, each
  keyword pointing to one page only. Candidates: students (lecture, class),
  interviews (journalists, hiring), and privacy-sensitive work (legal, health).
  Fastlane's `deliver` has no model for these, so they are created by hand or
  by a small Spaceship lane like `accessibility_labels.rb`.
- **In-App Events.** Indexed in search and shown as cards in results. A
  release with a user-visible feature, or the start of a school term, is the
  natural occasion.
- **Featuring nomination** (App Store Connect → Featuring Nominations) before
  each larger release: Liquid Glass, Apple Intelligence through
  `FoundationModelsProvider`, accessibility and privacy are the story Apple's
  editors look for.
- **Traditional Chinese (`zh-Hant`)** is the default store language of Hong
  Kong, Macau and Taiwan, which fall back to English today. It needs the app
  UI localized first — a store page in a language the app does not speak
  would mislead — and then a `zh-Hant` metadata directory.
- **Apple Search Ads** on the brand term and on the long-tail terms the
  listing already targets, once there is a rating count worth showing.

## Follow-ups on shipped work

Gaps each shipped track recorded about itself. None blocks feature work; each
is listed so it is not rediscovered.

### On-device LLM (`FoundationModelsProvider`)

- **Measure the on-device budgets.** `ContextBudget.onDevice`,
  `FoundationModelsProvider`'s output-token ceiling and `MeetingChatService`'s
  on-device pool sizes are conservative first-cut estimates against Apple's
  documented ~4096-token session window, commented as such in the code — not
  measured against real on-device runs the way the transcription pipeline is.
- **Exercise the untested paths.** `LLMTranscriptCorrector`, `WikiService` and
  `DocumentGenerationService` can select the on-device provider through the
  generic factory path, but that has not been exercised or validated the way
  tagging, chat and summaries were.
- **Measure availability.** `SystemLanguageModel.default.availability` depends
  on Apple Intelligence hardware and the user's setting; how often a fresh
  install actually gets a usable on-device provider is unknown, and is what F7
  should be decided against.

### KurnCore

- **`KurnCoreAccelerate`.** `SpeakerClusterRefiner`, `SpeakerIdentityMatcher`
  and `SpeechLevel` stayed in the app because they import `Accelerate`, which
  does not exist on Linux. If picked up, the plan is a second package target
  gated by `#if canImport(Accelerate)` in `Package.swift` so a Linux
  `swift test` never sees it — not a portable rewrite of the `vDSP` calls.
- **Pure presentation types still in `Views/`.** `MarkdownPresentation` (and
  any sibling) is excluded from coverage by living there; move it beside the
  type it presents, as `CLAUDE.md` asks of new code.

### Reliability

The H1–H10 hardening track is closed; its invariants and types are in
`CLAUDE.md` ("Durability & recovery"). What each track left open:

- **Release gate, recurring.** The physical-device matrix in
  `docs/release-physical-checklist.md` (Data Protection, interruptions, route
  changes, background expiry, low storage, thermal/memory, Watch, model
  compilation) — run per release, not a one-off task.
- **Model integrity.** Pin `WhisperCppModel`'s download source to an immutable
  HuggingFace revision instead of `resolve/main` (sherpa-onnx is already
  pinned); a wrong hardcoded SHA would break every download, so it needs a real
  commit hash fetched with network access. Models installed before verification
  existed read `.unverified` until re-downloaded. Download resume data survives
  backgrounding but not a relaunch, and there is no automatic
  retry-with-backoff.
- **Operation state.** A full operation-state enum (queued / running / paused /
  deferred / retryScheduled / permanentFailure with reason codes and
  `nextAttemptAt`) was deferred — the bounded `automaticResumeAttempts` counter
  over `TranscriptionStatus` suffices until a concrete UI need appears (e.g.
  "retrying in 2 minutes"). `DocumentGenerationService` has no durable map-stage
  checkpoint, because it spans several meetings and has no single `Meeting` to
  checkpoint against.
- **Network.** A dedicated "waiting / rate-limited" UI; FluidAudio's
  mid-transfer network path changes are unobservable (the library exposes no
  session to preflight against); background cloud upload stays off while
  origin-lock cannot be guaranteed there.
- **Error UX.** Contextual recovery actions reading `AppErrorMetadata.recoveryAction`
  (the data exists, no UI reads it); a short reference ID shared by an error
  dialog and the reliability-events list (needs widening `errorAlert`'s shared
  binding at ~19 call sites); optimistic-UI rollback; `persist()` and AI-title
  errors are not yet recording-scoped; the non-`AppError` raw-log sweep (~46
  sites) is unaudited.
- **Untested by construction today.** End-to-end resume of a staged
  summary/wiki against a mocked `LLMProvider` (the `SummaryMapRunner` loop is
  tested in isolation); `TranscriptionService.transcribe` actually throwing
  `transcriptIntegrityFailed` (the gate is tested in isolation); the
  ActivityKit start/end race; Watch command timeouts, reconnect reconciliation
  and intent acceptance (no `WCSession` seam, `KurnWatchUITests` not in CI);
  Keychain migration on a locked device; `ModelStoreOpenFailureClassifier`'s
  `NSError` mappings against a real device failure.
- **Unmeasured constants.** `ResourceScheduler`'s weight table and the
  memory/thermal cooldowns are first-cut estimates, not measurements.
- **CI.** The fault-injection seams exist per component (`ClockProviding`,
  `FakeFileSystem`, `ModelDownloading`, …) but there is no single fault-matrix
  artifact; the three macOS jobs each run a full clean build (no
  build-once/test-many — see "UI test stability and speed").

### Design and accessibility

- **iPad split view needs a hands-on pass.** `ContentView`'s
  `NavigationSplitView` on regular width is structurally complete but has never
  been checked on an iPad simulator/device: sidebar balance, collapse/expand in
  Split View and Slide Over, VoiceOver order sidebar → detail.
- **Audit coverage.** Bring `RecorderView` (the screen with the most icon-only
  controls) and `FolderFormView` into `AccessibilityAuditUITests`; no automated
  check covers large accessibility text sizes; Watch VoiceOver is verified
  manually because `KurnWatchUITests` does not run in CI; the Chat tab's live
  conversation UI only renders against a real provider.

### UI test stability and speed

The flow suites (`KurnUITests/Flows/`) are a required check, so a flake costs a
re-run and a slow one costs every PR. Already in place: identifiers instead of
text, the seeded in-memory store per launch, per-launch name suffixes, no
sleeps, `tapUntilCovered`/`tap(_:until:)` for taps that start a transition,
UIKit animations off and the language pinned to English
(`UITestLaunchOptions`, `FlowUITestCase`), test timeouts in CI, and the
measured `ui-flake-rate` lane. Open, in the order they pay off:

1. **Measure every new flow suite before trusting it.** Dispatch
   `reliability-hardening.yml` on the branch that adds it; 5/5 green attempts
   is the bar the existing suites met. A suite that later flakes is demoted with
   a `-skip-testing` line in `swift.yml` and fixed, never retried into green.
2. **Build once, test many.** Each `ui-tests` shard and `unit-tests` runs its
   own `clean test`, so the app and test bundles are compiled three times per
   PR — most of each job's wall time. `build-for-testing` in one job, the
   `.xctestrun` plus products uploaded as an artifact, and
   `test-without-building` in the shards removes two builds; the artifact
   transfer has to be measured against the build it saves.
3. **Boot the simulator before `xcodebuild`.** `xcrun simctl boot` +
   `simctl bootstatus -b` in `prepare-simulator` keeps the cold boot out of the
   first test's time budget, which is where launch-time waits most often run
   out.
4. **Fewer launches per suite.** Each test relaunches the app (~10–15 s on a
   CI runner); checks that share a screen belong in one test, as
   `testMeetingDetailTabs` already does for the audit. Separate tests only
   where a failure would otherwise hide the next check.
5. **Rebalance the shards from measured times.** `main` now also runs
   `BulkSelectionFlowUITests`; read the per-suite durations from the
   `.xcresult` and move suites so neither shard waits on the other.
6. **Replace the remaining text handles.** Menu-picker options, segmented
   segments ("Single file") and the selection title ("Selected: N") are still
   matched by their en string, because SwiftUI does not surface an identifier
   set on a picker option. A custom `Menu` of identified `Button`s, or an
   `accessibilityValue` on the title, would remove the last locale coupling.

Deliberately not used: `-retry-tests-on-failure`. It would turn a flaky test
green on its second attempt and hide exactly the signal the flake-rate lane
exists to count.

### Test coverage

Every in-scope layer is above the 80% target and the floor ratchets
(`Tools/coverage_floor.json`). Still below the target at file level:
`RecorderViewModel` (~74%) and the core of `TranscriptionCoordinator` (~76%).
Changes to `TranscriptionService` or `AudioRecorderService` seams should run the
Thread Sanitizer lane (`reliability-hardening.yml`) before merge.

## Deliberately out of scope

These are not bad features. They are bad fits, and the reasoning is recorded so
the question doesn't reopen without new information.

**R1 · CloudKit content sync.** Syncing transcripts across devices is the one
change here that contradicts the premise outright. CloudKit's private database
is encrypted in transit and at rest but is not end-to-end encrypted the way
`.completeUnlessOpen` is — those records can be served under legal process.
`CloudSettingsSync` is the correct precedent: iCloud key-value for non-secret
preferences, deliberately not the SwiftData container.

**R2 · A system-wide dictation keyboard.** Different product (I4). A meeting
recorder delivers value in a 90-minute file; a dictation keyboard delivers it in
a six-second insert. Building one would double the target count and the
cross-process IPC surface for something nobody installs this app to get.

**R3 · Chasing provider count.** The `AIProviderKind` shapes already reach
almost any vendor, because `openAICompatible` accepts a custom endpoint. Adding
seventeen named providers is a settings screen, not a capability.

**R4 · Bridging to CLI agents on a desktop.** Routing AI processing through a
coding agent running on the user's own machine is useless without that machine
powered on and serving HTTP. Anyone able to operate such a server is already
served by the custom OpenAI-compatible endpoint.

**R5 · Representing overlapping speech.** `SpeakerTurn` is flat and fusion
attributes an overlapped span to whoever held most of its duration. Modelling
concurrent speakers would mean a new turn shape, a fusion policy and UI/export
answers — and none of it would have content to show, because **no transcription
engine in this app produces separate text for simultaneous speech**. Revisit
only if an ASR approach producing independent hypotheses per overlapping
speaker becomes feasible; that question is upstream of anything here. It also
means a diarizer's overlap detection is never a reason to adopt it (see D4).

**R6 · Automatic diagnostic upload or a third-party analytics SDK,** and a
numeric reliability SLO before an instrumented baseline exists. Diagnostics
stay on device and leave only through an explicit share.

## Suggested sequence

1. **F2 · Meeting glossary.** Its WER effect is measurable, and the pure half
   is verifiable on Linux.
2. **F4 · Calendar context.** Feeds F2 real names and supplies the candidate
   names cross-meeting voice matching lacks.
3. **F5 · Reminders and F6 · Import.** Independent of each other and of the
   rest; slot them in as room appears. F6 widens the capture surface, so it
   lands with the same fault-injection discipline as capture itself.
4. **D4's per-file measurement**, on its own clock — it is a dispatch, not code.
5. **Reassess F7–F10.** F7 after the on-device availability number exists.

The follow-ups above are picked up opportunistically, ahead of any feature that
widens the surface they concern.
