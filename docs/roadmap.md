# Roadmap

Fourteen candidate capabilities, each judged against what Kurn is rather than
against what is fashionable: six to adopt, four to evaluate, four deliberately
out of scope. Then three focused engineering tracks that do not fit that
taxonomy: diarization, package extraction, and reliability/resilience hardening.

The verdicts matter less than the reasoning attached to them. A "no" with a
recorded reason stops the same idea from being re-litigated every few months; a
"yes" with its coupling point named is most of the design work already done.

## Premise: the filter

Kurn is a local-first meeting recorder. That sentence is load-bearing, and these
five invariants are what it decomposes into. Every entry below is judged against
them, and where an entry creates tension the tension is stated rather than
smoothed over.

|        | Invariant                                             | What holds it up today                                                                                                  |
| ------ | ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| **I1** | Nothing leaves the device without an explicit request | Network only on opt-in cloud transcription or a cloud summary provider; a fresh install works offline                   |
| **I2** | Meeting-derived content lives in the encrypted store  | `ModelStoreProtection` (`.completeUnlessOpen`) covers the SwiftData store; never a loose file, cache, or `UserDefaults` |
| **I3** | Accuracy is measured, not asserted                    | `KurnTests/Support/Evaluation/` (WER, DER, RTTM) plus the public-dataset matrix                                         |
| **I4** | The subject is meetings, not dictation                | The value is a 90-minute multi-speaker file, not a six-second insert                                                    |
| **I5** | Heavy dependencies are opt-in                         | `ModelDownloadConsent` gates every model fetch, with a working fallback when declined                                   |

Two further rules follow from I1 that are easy to violate by accident: a feature
that makes a paid cloud call *per transcription* cannot ship enabled (this is
why `wikiEnabled` and `correctionEnabled` default off), and a feature that
merely moves data off-device still needs consent even when no LLM is involved
(why `templatesSyncEnabled` defaults off).

## Capabilities already in place

Recorded here so none of the entries below is read as replacing something that
already exists, and so planning does not restart from a blank page.

- **Diarization** — `FluidAudioDiarizer` with `SpeakerClusterRefiner` rescuing
  VBx collapse, `SpeakerTurnSmoothing`, and per-`Speaker` voiceprints for
  identity that survives re-transcription. This is the most developed part of
  the pipeline and still the one with the most open questions — see the
  dedicated track below.
- **Measured accuracy** — WER/DER/RTTM harness, plus the public-dataset
  evaluation matrix and its recorded history in `pipeline-evaluation.md`.
- **Encryption at rest and access control** — file protection on recordings and
  the store, `RecordingAccessGate`, and the cover window above the whole
  hierarchy.
- **Resumable transcription** — checkpoints per chunk, background task, launch
  and foreground recovery sweeps.
- **Playback enhancement** — GTCRN neural denoise, BS.1770 loudness
  normalization, offline-rendered derived copies.
- **Semantic search and chat** — on-device embeddings, hybrid dense + BM25 with
  RRF, LLM rerank, `[mm:ss]` citations.
- **Multiple summaries per meeting** — `Meeting.summaries` is one-to-many, each
  `Summary` recording the template, provider and model it came from, with a
  switcher, per-summary delete and per-summary export already in the UI.
  Comparing two templates over one transcript is a shipped feature, not a
  roadmap item.
- **Derived artifacts** — per-meeting wiki articles and cross-meeting generated
  documents.
- **Transcript correction** — opt-in LLM pass with a change-magnitude guardrail
  and vocabulary auto-extracted from the meeting itself.
- **On-device LLM provider** — `FoundationModelsProvider`
  (`Providers/FoundationModelsProvider.swift`, Apple's `FoundationModels`)
  resolves through the same `ProviderFactory` as every cloud vendor, with no
  API key and no network call; new installs default to it. `AutoTaggingService`
  and the retrieval-grounded chat path already run against it unmodified. See
  F1 below for what shipped and what's still a first-cut estimate.

## Adopt

Ordered by payoff, not by effort. None of the six creates tension with the five
invariants.

### F1 · Apple Foundation Models as a local provider — Implemented

|                |                                                                        |
| -------------- | ---------------------------------------------------------------------- |
| **Couples to** | `Providers/LLMProvider.swift`, `ProviderFactory`, `AIProviderKind`     |
| **Invariant**  | Closes I1, which the app used to violate in practice                   |
| **Status**     | Implemented — [PR #139](https://github.com/carlosmazzei/Kurn/pull/139) |

This closed the largest gap between what Kurn promises and what it does.
`SummaryService`, `MeetingChatService`, `AutoTaggingService`,
`LLMTranscriptCorrector`, `WikiService` and `DocumentGenerationService` used to
all resolve through `ProviderFactory` to a cloud vendor with an API key: a user
who never added a key got transcription and nothing else, and a user who did
add one shipped the entire transcript of a private meeting to a third party.

A new `AIProviderKind.appleOnDevice` case and `FoundationModelsProvider`
(`Providers/FoundationModelsProvider.swift`) resolve through the same
`ProviderFactory`, with no API key and no network call — the deployment target
is iOS 26.0, so `FoundationModels` needed no `#available` guard, the same
reason the app uses Liquid Glass chrome directly. New installs default
`AppSettings.aiProviderID` to it; an existing user's stored selection is
untouched.

**What shipped:**

- `AIProvider.isUsable` replaces the ad hoc `KeychainManager.hasValue(...)`
  checks that used to gate title generation, the wiki/correction toggles and
  `configuredProviders` — all of which would otherwise have treated the
  on-device provider as permanently unconfigured, since it has no Keychain
  entry at all. `ProviderFactory` checks `SystemLanguageModel.default.availability`
  in its place, throwing `AppError.onDeviceModelUnavailable` the same way a
  missing API key throws `AppError.noAPIKey` today.
- `AutoTaggingService` runs against it unmodified — its excerpt was already
  small enough. `MeetingChatService`'s retrieval-grounded chat
  (`answerAcrossLibrary`, and the `answerAboutMeeting` full-transcript path for
  meetings short enough to fit) and `SummaryService`'s map-reduce both do too,
  now that `maxSinglePassChars`/`mapBlockChars` and the retrieval pool sizes
  are per-provider — the on-device context window is far smaller than any
  cloud vendor's, so a long meeting takes more reduce rounds there than it
  would on a cloud provider, exactly as anticipated below.
- `summarize` uses guided generation (`@Generable`) rather than
  `SummaryJSON`'s tolerant JSON parsing for this provider, so
  `SummaryJSON.parse`'s fence-stripping and `AppError.summaryTruncated` are
  both unreachable on this path — the secondary benefit originally named here.

**Left for a follow-up, per I3:** the on-device char/token thresholds
(`SummaryService`'s on-device `maxSinglePassChars`/`mapBlockChars`,
`FoundationModelsProvider`'s output-token ceiling, `MeetingChatService`'s
on-device pool sizes) are conservative first-cut estimates against Apple's
documented ~4096-token session window, explicitly commented as such in the
code — not yet measured against real on-device runs the way the transcription
pipeline's accuracy is. `LLMTranscriptCorrector`, `WikiService` and
`DocumentGenerationService` can already select the on-device provider through
the generic factory path, but that hasn't been exercised or validated the way
tagging/chat/summary were.

**Availability is a runtime fact, not a compile-time one** remains true after
shipping: `SystemLanguageModel.default.availability` depends on Apple
Intelligence hardware and on the feature being enabled, so how often real
users actually get a usable on-device provider — versus falling through to
"no provider configured" on a fresh install with Apple Intelligence off — is
still unmeasured. That number is what F7 (below) should be reassessed against.

### F2 · User-maintained meeting glossary

|                |                                                                                                   |
| -------------- | ------------------------------------------------------------------------------------------------- |
| **Couples to** | New `@Model` in the store · `WhisperCppTranscriber` · `OpenAIProvider` · `LLMTranscriptCorrector` |
| **Invariant**  | I2 for storage; I3 because the effect is measurable                                               |
| **Effort**     | Medium                                                                                            |

`MeetingVocabularyExtractor` already exists, but it derives terms from the
transcript itself with `minOccurrences = 2`, on the premise that the term appears
spelled correctly *somewhere* in the same recording. That premise fails for
exactly the words that matter most in a meeting: a participant's name, a product
name, an internal acronym — mis-heard consistently, in all fourteen occurrences,
with nothing correct to copy from.

**Two application points, with uneven engine support.**

- *Before ASR, as a decoding hint.* whisper.cpp accepts `initial_prompt` in
  `whisper_full_params`; cloud Whisper accepts `prompt`; Apple Speech exposes
  contextual strings. FluidAudio Parakeet has no equivalent hook. This unevenness
  must surface in the UI rather than be promised uniformly across engines.
- *After ASR, as deterministic replacement* over `TranscriptSegment.text`, and as
  a term list handed to `LLMTranscriptCorrector` alongside the auto-extracted
  ones. This path works for every engine, which is what makes the feature
  coherent despite the gap above.

**The identity connection.** `Speaker` rows already carry user-typed names.
Those are free glossary entries for the meeting they belong to — and because
`Speaker.voiceprintData` matches voices across runs, a name learned once can seed
the hint for later meetings with the same voice.

This is also the only entry whose effect the project can *prove*: run the
public-dataset matrix before and after and compare WER. Under I3, that should be
part of shipping it, not an afterthought.

### F3 · Frictionless capture: App Intents, Siri, Control Center — Implemented

|                |                                                                              |
| -------------- | ---------------------------------------------------------------------------- |
| **Couples to** | `RecordingLauncher` · `RecordingCommandRouter` · `KurnLiveActivityExtension` |
| **Invariant**  | No tension — system integration, no network                                  |
| **Status**     | Implemented — [PR #143](https://github.com/carlosmazzei/Kurn/pull/143)       |

`StartRecordingIntent` now opens the app and posts a process-local request;
`RecordingLauncher` creates and queues the meeting through the existing
`RecorderView` path; `KurnShortcuts` exposes the action to Siri/Shortcuts; and
`StartRecordingControl` makes it available from Control Center, Lock Screen and
the Action Button. The existing Watch/Live Activity pause, resume, stop and
highlight commands still converge through `RecordingCommandRouter`.

This deliberately starts capture without waiting for `RecordingAccessGate` — a
lock-screen control that first required Face ID would miss the moment it exists
to capture — while the cover window still prevents meeting content from being
exposed. The remaining work is resilience rather than feature wiring: H8 below
requires the intent to distinguish “request accepted” from microphone permission
and actual capture, makes duplicate external commands idempotent, and verifies
that meeting persistence, the cover window and Live Activity state converge when
startup fails or the app is launched locked.

### F4 · Calendar context at record time

|                |                                                                          |
| -------------- | ------------------------------------------------------------------------ |
| **Couples to** | `MeetingFormView` · `Speaker` · `SpeakerIdentityMatcher`                 |
| **Invariant**  | I2 — attendee names are meeting-derived content, so they go in the store |
| **Effort**     | Low-medium                                                               |

Offer the calendar event happening now as the meeting title, and its attendees as
pre-created `Speaker` rows. Read-only EventKit access with
`NSCalendarsUsageDescription`.

This is more than a convenience. `SpeakerIdentityMatcher` already reconciles
stored rows against fresh diarizer labels by voiceprint, but a name only enters
the system when a user types one. An attendee list gives the app a *candidate
set* of names for the voices in the room — and once a voiceprint is bound to a
name, it can carry forward. That is the direct route to the limitation currently
recorded in `CLAUDE.md`: nothing crosses meetings today, and "Ana" in one has no
relation to "Ana" in another.

### F5 · Action items to Reminders

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

### F6 · Import audio recorded elsewhere

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
`RecordingProtection`.

**The format trap.** 24 kHz mono AAC is guaranteed for the app's own files, not
for imports. `RecordingCompactor`, `Recording.effectiveBitRate` and the offline
render path all assume the app's encoding. Either normalize on ingest —
`OfflineAudioRenderer` already performs exactly this kind of render — or make
tolerance of foreign formats an explicit, tested requirement at each of those
points. Choosing neither is how a silent corruption bug gets shipped.

## Evaluate

Good ideas carrying a condition, a disproportionate cost, or an unresolved
tension.

### F7 · OAuth for cloud providers

Signing in with an account the user already pays for, instead of a separately
provisioned API key. It changes nothing about the privacy posture — cloud is
still cloud — but it changes *who can reach it*: today the barrier is creating a
developer account and entering a credit card.

The cost is real: OAuth with PKCE, token refresh, a local callback.
**Condition:** F1 has now shipped, so reassess. On a device where the
on-device provider satisfies "works with no key at all", much of the
motivation evaporates — what's still unmeasured is how often that's actually
true across the install base (Apple Intelligence hardware and the feature
being enabled), which is exactly the number F1's write-up above flags as
outstanding.

### F8 · Reading mode

Filler-word removal and paragraph reflow for readability. This **cannot be a
pipeline stage**: `TextNormalizer` is explicitly comparison-only, and the stored
transcript keeps its punctuation and casing by design.

So: a render-time transform over `Transcript.segments`, plus an option in
`MeetingExport`. Cheap, pure and testable — a good first candidate for
extraction into the package described below.

### F9 · On-device translation

Apple's `Translation` framework runs entirely on-device with language packs
downloaded on demand. Kurn already transcribes many languages; reading an
English meeting in Portuguese is a real case and the fit with I1 is exact.

The pack download is a heavy dependency, so it goes through I5 — reuse the
`ModelDownloadConsent` pattern rather than fetching independently.

### F10 · Spotlight indexing

The value is obvious: find a meeting from system search. The problem is specific
and disqualifying by default. The `CoreSpotlight` index lives outside the app's
store, and I2 exists precisely so that `.completeUnlessOpen` covers every piece
of transcript-derived text. Indexing excerpts would place meeting content in a
system index the app does not control and cannot encrypt.

Two defensible versions: index **title and date only**, with no transcript text;
or make excerpt indexing an explicit opt-in with the trade-off written in plain
language. **Do not index excerpts by default.**

## Deliberately out of scope

These are not bad features. They are bad fits, and the reasoning is recorded so
the question doesn't reopen without new information.

**R1 · CloudKit content sync.** Syncing transcripts across devices is the one
change here that contradicts the premise outright. The detail that makes it worse
than it sounds: CloudKit's private database is encrypted in transit and at rest
but is not end-to-end encrypted the way `.completeUnlessOpen` is — those records
can be served under legal process. `CloudSettingsSync` is the correct precedent
and its own header says why: iCloud key-value for non-secret preferences,
deliberately not the SwiftData container.

**R2 · A system-wide dictation keyboard.** Different product (I4). A meeting
recorder delivers value in a 90-minute file; a dictation keyboard delivers it in
a six-second insert. Building one would double the target count and the
cross-process IPC surface for something nobody installs this app to get.

**R3 · Chasing provider count.** The three `AIProviderKind` shapes already reach
almost any vendor, because `openAICompatible` accepts a custom endpoint. Adding
seventeen named providers is a settings screen, not a capability. F1 and F7 add
capability; a longer list does not.

**R4 · Bridging to CLI agents on a desktop.** Routing AI processing through a
coding agent running on the user's own machine is clever and useless without that
machine powered on and serving HTTP. Anyone able to operate such a server is
already served by the custom OpenAI-compatible endpoint the app supports today.

## Diarization track

Diarization gets its own section because these six items are interdependent in a
way the F-list is not: **D2 gates D3, D4 and D5**, and deciding any of those
without it means arguing rather than measuring. Two are defects rather than
features, so they carry a different kind of urgency.

|        | Item                                                       | Verdict                                                                                                                                                                 |
| ------ | ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **D1** | Speaker labels conflated across recordings in one meeting  | Fixed                                                                                                                                                                   |
| **D2** | Raw diarizer turns are not measurable                      | Implemented                                                                                                                                                             |
| **D3** | The `Diarizing` seam cannot accept provider-supplied turns | Evaluate                                                                                                                                                                |
| **D4** | A segmentation-first diarizer as a third engine            | Shipped as an opt-in alternative; measures ~17pp behind `fluidAudio` on AMI, but the collapse case it targets is still untested (needs a per-file, same-run comparison) |
| **D5** | Overlapping speech is not representable                    | Decided — keep truncating; no engine here has overlap-aware ASR anyway                                                                                                  |
| **D6** | Voiceprints never cross meetings                           | Implemented (standalone; F4 half still open)                                                                                                                            |

### D1 · Speaker labels conflated across recordings in one meeting — Fixed

**This was a defect, not a missing feature.** `TranscriptionViewModel.syncSpeakers`
used to build `usedLabels` by walking **every** recording in the meeting and
collecting the speaker labels found in each transcript, while the `voiceprints`
argument held only the vectors from the run that had just finished.

The consequence was in the fallback branch: voice matching ran first and could
only speak for labels in the current run, so every other row fell through to
label-identity matching — the "Speaker 1" of recording B bound to the existing
"Speaker 1" row created for recording A. The diarizer hands out labels in order
of first appearance, independently per recording, so those two were the same
person only by coincidence. Two different people could end up merged into one
`Speaker` row, with whatever name the user typed sitting on both — and the
voiceprint refresh compounded it, since it described whichever recording ran
last rather than the person the row was named for.

**What shipped:** `Recording.speakerVoiceprintsData` (`Recording.speakerVoiceprints`)
persists each recording's own diarization run's voiceprints, not just the one
that just finished. `syncSpeakers` now reconciles **one recording at a time, in
`recordedAt` order**: each recording's own labels are matched via
`SpeakerIdentityMatcher` against whichever stored rows an earlier recording in
the same pass hasn't already claimed, a row already placed can still be
*reconfirmed* by a later recording's matching voice (never relabelled or
duplicated), and a label collision between two different recordings' same
raw number is resolved by handing the second one the next free `"Speaker N"`
rather than merging into the first's row. `KurnTests/SpeakerSyncTests.swift`
pins both halves as regression tests: two different voices independently
numbered the same across recordings stay distinct rows, and one voice heard
in two recordings under different numbers is still recognized as one person.

**Coupling point:** `TranscriptionViewModel.syncSpeakers`,
`Kurn/Models/Recording.swift`.

### D2 · Raw diarizer turns are not measurable — Implemented

`TranscriptionService.Output` used to carry `segments`, `language`,
`speakerLabels` and `speakerVoiceprints` — but not the diarizer's own turns.
The public-dataset harness therefore built its DER hypothesis from
`output.segments`, whose boundaries come from the ASR spans that fusion
attributed.

So the number the project called DER was really *fusion-output* DER: it
blends diarizer error with ASR boundary placement and fusion policy. That is a
fine end-to-end metric, and it was the wrong instrument for deciding whether
one diarizer beats another. The repository already documented that DER "is
not symmetric, since it is scored on the fused segments whose boundaries come
from the ASR spans"; this item turns that caveat into something actionable.

**What shipped:** `Output.turns` now carries the diarizer's raw,
pre-fusion `[SpeakerTurn]`. `PublicDatasetEvaluationHarnessTests` scores a
second DER (`Row.rawDER`) from those turns against the same reference RTTM,
reports it alongside the existing fused-segment DER in both the per-item and
aggregate `[pipeline-eval]` output, and persists it as four extra columns in
the CSV report; `Tools/evaluation/report_to_markdown.py` renders both as
separate "DER (fused)" / "DER (raw)" columns. Two numbers that diverge now
localize the error to a stage — this is what D3/D4/D5 need to be decided by a
table rather than by argument, per invariant I3.

**Effort:** low. **Coupling point:** `TranscriptionService.Output`,
`PublicDatasetEvaluationHarnessTests`.

### D3 · The `Diarizing` seam cannot accept provider-supplied turns

The protocol is `func diarize(url: URL) async -> [SpeakerTurn]`. It receives a
file and nothing else: no access to the ASR result, and no path for turns that
arrived *with* a transcript rather than being computed from audio.

That shape is why a cloud transcription provider's own speaker attribution can
never be used. Several speech APIs return speaker-labelled output as part of the
transcript, and on far-field multi-party audio — the app's whole subject — that
attribution is often better than a locally computed one, because the service runs
a larger model than fits comfortably on a phone.

**The tension is real and worth stating.** This is cloud, so it sits against I1.
But it does not widen the privacy surface: it rides on the opt-in cloud
transcription consent that already exists, and the audio is already being
uploaded on that path. What changes is that the turns come back instead of being
recomputed locally over the same file.

Shape of the change: widen the seam so a transcription result can carry optional
speaker turns, and add a diarization engine case that consumes them rather than
opening the audio. Fusion is unaffected — it already takes turns plus spans.

**Effort:** medium, and it presumes adding a provider whose API offers this,
which is a separate decision from the seam.

### D4 · A segmentation-first diarizer as a third engine

The documented failure of the current neural engine is VBx clustering collapsing
every mixture weight but one on far-field single-microphone audio, returning the
whole meeting as one speaker. `SpeakerClusterRefiner` exists specifically to undo
that after the fact.

Pyannote-style pipelines attack the same case from the other end: local
segmentation first (a small model that decides who is speaking in a short window,
overlap included), then clustering over those segments. The collapse mode is
structurally different, which is the reason to try it rather than a claim that it
scores better.

`DiarizationEngine` plus the `Diarizing` protocol make a third engine cheap to
add — the enum, one conforming type, and a consent entry for its model download
under I5. What makes this worth doing is D2: with raw-turn DER in the evaluation
matrix, "which diarizer is better on meeting audio" becomes a measurement on AMI
rather than a preference.

**Effort:** medium. **Sequencing:** after D2 (done). D5 is now decided
(keep truncating overlap — see below): adopting D4 would have to be justified
by its VBx-collapse resistance alone, since its overlap detection has nowhere
to go once fusion runs.

**Status: shipped and runtime-verified; collapse-resistance not yet measured.**
The candidate is [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
(Apache-2.0): local segmentation via `pyannote/segmentation-3.0` (MIT) then
clustering via a 3D-Speaker CAM++ embedding (Apache-2.0) — both permissively
licensed, so nothing blocked shipping it. `DiarizationEngine.sherpaOnnx`, its
own `ModelSet`/consent flag/Settings flow, `SherpaOnnxDiarizer` (mirroring
`FluidAudioDiarizer`'s contract), and the raw-turn-DER evaluation-matrix
wiring are all in place and merged.

sherpa-onnx exposes a C API with no importable Clang module of its own (its
SPM product is named `sherpa-onnx`, not a valid Swift module identifier), so
— unlike FluidAudio and whisper.cpp, both `import`ed directly — it needed a
bridging header and a `SHERPA_ONNX_ENABLED` compilation condition on the
`Kurn` target rather than the usual `#if canImport(...)` guard; that wiring
was completed and verified locally (Xcode) after the initial merge. The
2026-08-27 pipeline-eval dispatch (`docs/pipeline-evaluation.md`) confirms
the real engine runs in CI (0.08–0.92s per item, not the disabled stub's
instant fallback) and reports its first raw-turn DER on AMI (37.41%,
constant across preprocessing/VAD as expected).

**It loses to `fluidAudio` by ~17pp on AMI, which is evidence against
adopting it as more than an opt-in alternative.** That run swept
sherpa-onnx alone, but its English WER came back bit-identical to the
2026-08-03 `whisperCpp@small` + `fluidAudio` rows — and since fusion is
word-preserving, identical WER means the ASR path (and therefore the spans
fusion attributes) behaved identically in both runs, which makes the fused
DER difference attributable to the diarizer. On that basis `sherpaOnnx`
scores 63–67% against `fluidAudio`'s 44–50% and `heuristic`'s 72–89%, in
every one of the four preprocessing × VAD configurations. See "sherpa-onnx
vs. FluidAudio" under Cross-run findings in `docs/pipeline-evaluation.md`
for the table and its caveats.

That is not the same as failing D4's actual bar, which is collapse-resistance
specifically: FluidAudio's 44–50% on these four meetings is not a collapse
pattern, so the material may simply not exercise the failure this engine was
added to survive — and an engine cannot demonstrate resistance to a failure
that did not occur. **Next measurement needed**: a dispatch with
`diarization_engines: fluidAudio,sherpaOnnx` for both raw DERs in one run,
read **per file** rather than in aggregate — the question is whether any
single meeting shows FluidAudio collapsing and sherpa-onnx holding, which an
average over four meetings cannot show either way.

### D5 · Overlapping speech is not representable — Decided: keep truncating

`SpeakerTurn` is a flat `speakerLabel` / `start` / `end`, and `TranscriptFusion`
attributes each span to the single speaker holding most of its duration. Nothing
in the data model can express two people talking at once.

In a meeting that is not an edge case — interruptions, agreement noises and
crosstalk are routine. Representing it properly would mean `SpeakerTurn`
allowing concurrent intervals, fusion deciding what an overlapped span even
renders as, and the transcript UI and Markdown export both needing an answer
for two simultaneous speakers.

**The decision, and why it's smaller than it looks.** None of that is worth
building, because a harder constraint sits underneath all of it: **no
transcription engine in this app — Apple Speech, FluidAudio Parakeet,
whisper.cpp, or the cloud Whisper API — produces separate text for
simultaneous speech.** Every one of them returns one word sequence per audio
span. So "show what both people said" has no content to show regardless of
what the diarizer reports or how the UI is drawn; the question was never
really about `SpeakerTurn` or `TranscriptView`, it was gated on overlap-aware
ASR that doesn't exist here. Kurn keeps attributing an overlapped span to
whoever held most of its duration, exactly as today, and this stops being an
open question rather than a documented gap.

**What this means for D4.** A segmentation-first diarizer's overlap detection
would still be discarded at fusion, same as any other engine's — so if D4 is
ever adopted, it has to earn that on the VBx-collapse-resistance case (see
D4 above), not on overlap, which no engine here can turn into text anyway.

**If this is ever revisited**, the blocking question is upstream of anything
in this app: does an on-device- or cloud-feasible ASR approach exist that
produces independent hypotheses per overlapping speaker (e.g. re-running
transcription per diarized track over the overlapped window)? Without an
answer to that, a data-model/UI redesign here would have nothing real to
render.

### D6 · Voiceprints never cross meetings — Implemented (standalone, without F4)

`Speaker.voiceprintData` persisted an L2-normalized embedding per speaker, but
the only consumer was `syncSpeakers(for:)` — scoped to one meeting. A person
who attends every week got an unrelated, freshly-named row each time.

The roadmap paired this with **F4** (calendar attendees supplying candidate
names), but F4 isn't built, and the other half — cross-meeting *voiceprint*
continuity — stands on its own: the only candidate names available today are
ones already typed on `Speaker` rows in other meetings, which is still a real
improvement over never checking at all.

**What shipped:** `SpeakerIdentityMatcher.match` assumes each side is
addressable by a unique label — true within one meeting, false across the
whole store, where `"Speaker 1"` is the label of countless different people.
A new `SpeakerIdentityMatcher.closestMatch(to:among:)` sidesteps that: nearest
single candidate to one voiceprint, over an arbitrary `(value, voiceprint)`
pool with no uniqueness assumption. `TranscriptionViewModel.syncSpeakers`
calls it exactly once per sync, at the point a brand-new `Speaker` row is
created (step 4) — the only place a row is ever created from nothing, so the
only place "have we heard this voice before, under a name, elsewhere" is
worth asking — against every *other* meeting's named, voiceprinted rows
(`crossMeetingSpeakerCandidates`, an unfiltered store-wide fetch filtered in
Swift, same shape as `SemanticIndexCoordinator`'s sweeps). A hit is staged on
`pendingCrossMeetingMatches`, never applied directly: `CrossMeetingSpeakerMatchView`
(a sheet, wired into `MeetingDetailView` scoped to the meeting on screen) lets
the user confirm or dismiss, mirroring `AutoTagConfirmView`'s "suggest, never
apply silently" shape. Self-limiting by construction: a given row can only
reach step 4 — and so only ever get one suggestion — the first time it's
created; every later re-sync finds it again via intra-meeting voice matching,
never step 4, so confirming or dismissing is a one-time event, not a repeat
nag. No new settings toggle — a pure on-device vector comparison over
already-collected, already-encrypted data, gated by the same explicit-confirm
step a toggle would add.

**Left open:** the F4 half (attendee names as candidates, independent of
whether that name has ever been typed before) is still exactly the gap D6's
original write-up named — see F4 above.

**Coupling point:** `TranscriptionViewModel+CrossMeetingSpeakerMatch.swift`
(split out of `TranscriptionViewModel.swift` to stay under SwiftLint's
file-length limit, the same reason `MeetingDetailAutoTagging.swift` exists),
`SpeakerIdentityMatcher`, `CrossMeetingSpeakerMatchView`.

## The change that isn't a feature: SPM extraction — Implemented

**Status:** Implemented — [PR #142](https://github.com/carlosmazzei/Kurn/pull/142).
`Packages/KurnCore` now exists, wired into `Kurn.xcodeproj` the same way
`Packages/WhisperCpp` is, with a `kurncore-linux` CI job running `swift test`
on Linux in parallel with `build-and-test`, gating every release job the same
way.

The app is a single Xcode target plus the whisper binary package. Splitting the
pure logic into local Swift packages fixes a bottleneck this repository already
documents in detail.

The bottleneck, from "Verifying without a local macOS/Xcode toolchain": builds
and tests require macOS with Xcode, so they cannot run on a Linux agent or in
generic CI. The prescribed loop is push the branch, open a PR, read the
`build-and-test` logs, grep for `error:`, repeat — several rounds, because the
Swift compiler stops at the first error.

Much of the most heavily tested logic here is already plain Foundation, with no
UIKit, no SwiftData and no AVFoundation:

| Domain             | Types that are already pure                                                                     |
| ------------------ | ----------------------------------------------------------------------------------------------- |
| Fusion and quality | `TranscriptFusion`, `TranscriptQualityFilter`, `TranscriptCorrectionGuardrail`, `ChunkBoundary` |
| Speakers           | `SpeakerClusterRefiner`, `SpeakerIdentityMatcher`, `SpeakerTurnSmoothing`                       |
| Audio decisions    | `SpeechLevel`, `PlaybackTuning`                                                                 |
| Text and data      | `MeetingVocabularyExtractor`, `SummaryJSON`, `MeetingFilter`, `MarkdownBlockParser`             |
| Security           | `SecurityCoverState`                                                                            |
| Evaluation         | All of `KurnTests/Support/Evaluation/` — WER, DER, RTTM, `TextNormalizer`                       |

Extracted into a `KurnCore` package, these run under `swift test` **on Linux, in
seconds, without a simulator**. A change to transcript fusion or DER scoring
becomes verifiable before the push, by CI or by an agent with no Xcode. There is
no product risk in the move: these types have no platform dependencies today —
the package only makes that boundary enforceable by the compiler instead of
maintained by convention.

**What shipped, and where this table was wrong.** All of "Fusion and quality"
and "Text and data" moved (`MeetingVocabularyExtractor`, `SummaryJSON`,
`MeetingFilter`, `MarkdownBlockParser`), plus `SecurityCoverState` and
`Evaluation`'s already-independent files — but two entries in this table
turned out not to be pure as claimed, discovered only once each was actually
read line by line rather than trusted from its file's import statement:
`MeetingFilter` imported SwiftData and its `matches(_:)` read straight off
the `Meeting` `@Model` class; it's now a pure predicate over a new
`MeetingFilterAttributes` snapshot, with the SwiftData-facing translation
left behind as an adapter (`Kurn/Models/MeetingFilter+Meeting.swift`).
`SecurityCoverState` imported SwiftUI for `ScenePhase`; it now resolves
against a portable `AppLifecyclePhase` KurnCore defines itself, with a
one-line `ScenePhase` mapping left at the single app call site. Both kept
their existing call-site signatures, so nothing outside either file noticed.

Extraction also pulled in dependencies this table didn't list, because a
type's own file compiling as Foundation-only doesn't mean nothing *it
depends on* reaches into SwiftData or AVFoundation — `TranscriptSegment`
(needed by `TranscriptFusion` and `MeetingVocabularyExtractor`),
`TranscriptionStatus`/`TranscriptionEngine`/`TranscriptionMode`/
`MeetingLanguage` (needed once `AppError` and `SummaryJSON` moved),
`SummarySection` plus its `String.unescapingLiteralWhitespace()` helper
(needed by `SummaryJSON`), and `SpeechRegion`/`TimelineSegment`/`ChunkBoundary`
split out of files that also carry an AVFoundation-dependent actor.
`TranscriptionEngine.requiredModelSet(whisperCppModel:)` stayed behind as an
app-side extension rather than dragging `ModelSet` (which orchestrates real
FluidAudio/whisper.cpp downloads) into the package — Swift extensions can add
methods to a type from another module, so the split needed no call-site change.

**Left out, deliberately: the "Speakers" row and `SpeechLevel`.**
`SpeakerClusterRefiner`, `SpeakerIdentityMatcher` and `SpeechLevel`
(`SpeechLevelMeter.swift`) all import `Accelerate`, which doesn't exist on
Linux — moving them would buy none of this change's actual point (a Linux
`swift test` signal) while adding an Xcode-project change this session had
no way to verify locally. If picked up later, the plan is a second package
target (`KurnCoreAccelerate`, gated by `#if canImport(Accelerate)` in
`Package.swift` so a Linux `swift test` never sees it), not a portable
rewrite of the `vDSP` calls.

One caution to carry into any coverage work that follows: a test plan gathers
coverage for every linked target, third-party dependencies included, which makes
the raw percentage meaningless. Filter to first-party targets before trusting any
coverage number.

## Reliability and resilience track

This track is not a claim that Kurn is generally unreliable. It is the result of
a static, repository-wide failure-path audit on 2026-08-29, covering capture,
SwiftData, file mutation, transcription, cloud providers, model downloads,
background execution, WatchConnectivity, Live Activities, diagnostics, UI state,
and CI. The code already contains unusually strong recovery work; the purpose of
this section is to turn the remaining implicit assumptions into explicit,
testable contracts.

Items below are **planned unless marked otherwise**. A green CI run proves that
the tested paths compile and pass; it does not prove that disk exhaustion, a
locked background launch, process death, a broken route, or a malformed provider
behaves safely until that failure is injected. As with accuracy under I3,
resilience must be measured rather than inferred from clean-path tests.

### Reliability invariants

The five product invariants at the top of this document still apply. Hardening
adds six operational invariants:

|          | Invariant                                                                                                                                              |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **H-I1** | Once capture is acknowledged as running, a write failure is detected and surfaced; the app never continues counting while silently dropping audio      |
| **H-I2** | The only copy of user audio is never automatically deleted merely because metadata is missing, malformed, or unreadable                                |
| **H-I3** | Success is reported only after the authoritative state is durable; a failed save cannot leave the UI claiming an operation completed                   |
| **H-I4** | A fallback may preserve useful work, but it is recorded and visible; degraded output is never indistinguishable from the requested pipeline succeeding |
| **H-I5** | A custom network destination is exact: invalid configuration fails closed and never falls through to another vendor or host                            |
| **H-I6** | Cancellation, transient failure, permanent failure, and resource deferral are distinct states with bounded automatic retry                             |

Priorities in this track mean:

- **P0** — possible loss of the only user copy, an unintended network
  destination, a persistent launch failure, or false success. Address before
  expanding the affected surface.
- **P1** — silent quality degradation, repeated paid work, stuck state, or a
  failure the user cannot recover from without relaunching.
- **P2** — diagnosability, integration polish, and continuous verification that
  make P0/P1 guarantees sustainable.

### Current implementation status (2026-08-29)

Status here is evidence-based and deliberately distinguishes an injectable seam
from the production invariant that will eventually use it. PR
[#151](https://github.com/carlosmazzei/Kurn/pull/151) established the first
baseline; later rows include controls that predated that PR where they already
satisfy part of a planned contract.

| Track              | Status                 | Implemented evidence and remaining contract                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ------------------ | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Baseline and seams | **In progress**        | `OperationID`/`ReliabilityEvent`, injectable `SleepClock`, scoped `FileSystem`, `ModelContainerFactory`, `AudioSinkWriting`, and deterministic fakes are present. Filesystem/store/network coverage is still intentionally narrow, and there is no complete fault-matrix harness.                                                                                                                                                                                                                                                                                                                                                                                        |
| **H1**             | **In progress**        | `RecordingSink` latches write-path failures and exposes frame progress; a two-second watchdog pauses stalled capture with retry/stop actions. Recording now preflights 30 minutes of configured-rate headroom, keeps an unavailable capacity query visibly `unknown`, and refreshes runway every five seconds using measured file growth after ten seconds (never below the conservative configured rate). `RecorderViewModel` preserves warned partial output. Provisional rows, authoritative final-file validation, and the process-death/device matrix remain.                                                                                                       |
| **H2**             | **Seam only**          | Container creation is injectable through `ModelContainerBootstrap`, but production still terminates with `fatalError`; versioned schemas, migrations, backups, failure classification, and recovery UI remain.                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| **H3**             | **Foundation only**    | Recovery preserves some large unreadable orphan files, but unmatched/malformed/small originals can still be deleted and model/file mutations have no journal, trash, quarantine, or typed authoritative JSON corruption path.                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| **H4**             | **Partial, pre-track** | Per-chunk checkpoints and recovery sweeps exist, but identity is not a full source/configuration/model/chunk-plan fingerprint and checkpoint persistence does not yet gate forward progress with a throwing durable commit.                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| **H5**             | **Planned**            | Useful stage fallbacks exist, but typed degradation, persisted pipeline reports, integrity gates, and previous-artifact preservation are not implemented.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| **H6**             | **In progress**        | Provider URLs fail closed and all new cloud traffic uses one origin-locked, deadline-bounded, 16 MB-capped foreground policy with exact budgeted `Retry-After`. Each logical request owns one UUID reused across attempts; official OpenAI chat requests also send it as the documented correlation header, never as an undocumented idempotency claim. Ambiguous POST timeouts/connection loss stop without automatic replay and surface a typed duplicate-charge warning. Background upload has no creation API or response-buffering state; its synchronized adapter only drains old system tasks. Dedicated waiting UI, cooldown, and connection-cost policy remain. |
| **H7**             | **Planned**            | Existing Keychain/model flows work on the clean path, but typed `OSStatus`, explicit credential save, cryptographic model verification, resumable staging, atomic replacement, and health probes remain.                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| **H8**             | **Partial, pre-track** | Several long jobs have app-level owners and run IDs, but memory pressure is sticky until relaunch and the scheduler, cancellation truth, Activity race handling, shared Watch protocol, deduplication, timeout, and durable acknowledgements remain.                                                                                                                                                                                                                                                                                                                                                                                                                     |
| **H9**             | **Started**            | `AppError.logCode` and the content-free `ReliabilityEvent` vocabulary are present. Action metadata, per-operation queues/reports, bounded encrypted event storage, health UI, redaction preview, and recovery accessibility coverage remain.                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **H10**            | **Started**            | Clock, filesystem, store-factory, reliability-event, and audio-sink fakes prove initial seams. The full transition fault matrix, split CI signals, retained failure artifacts, sanitizers/repetition, static policy checks, and device checklist remain.                                                                                                                                                                                                                                                                                                                                                                                                                 |

### Foundation already present

The plan builds on these controls rather than replacing them:

| Area          | Existing control                                                                                                                                               |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Error domain  | `AppError` provides localized, content-free `logCode`s; `errorAlert` gives views one presentation path                                                         |
| Capture       | Fixed-format `RecordingSink`, audio interruption/route observers, engine restart, `finalizeIfAbandoned`, protected recording storage, and orphan recovery      |
| Transcription | Per-chunk checkpoints, ordered pipeline events, foreground and launch recovery sweeps, background task cancellation, and per-recording/global in-flight guards |
| Pipeline      | Resource checks between heavy stages, temporary-file cleanup, measured WER/DER, and useful fallbacks for optional preprocessing/VAD/diarization stages         |
| Network       | Central status validation, origin-locked requests, total deadlines, response caps, bounded retry with jitter, and explicit cloud/model consent defaults        |
| Diagnostics   | Leveled `os.Logger`, user-exported logs, opt-in local MetricKit crash/hang reports, and no automatic diagnostic upload                                         |
| Tests         | 600+ Swift Testing cases, provider stubs through `MockURLProtocol`, recovery/resource tests, accessibility audits, and Linux `KurnCore` CI                     |

### Risk register

These are verified code paths or direct consequences of them, not hypothetical
feature requests:

| Item    | Observed seam                                                                                                                                                                                      | Failure if it remains                                                                                                       | Priority              |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- | --------------------- |
| **H1**  | Sink failures, a written-frame watchdog, and configured/measured storage runway are visible; elapsed duration is still wall-clock and there is no provisional capture row or final-file validation | Process death still relies on filename recovery, and an unreadable or empty file can still pass finalization                | **P0**                |
| **H2**  | Production `ModelContainer` construction ends in `fatalError`; there is no `VersionedSchema`/`SchemaMigrationPlan`                                                                                 | Corruption, incompatible schema, or a locked protected store can create a launch crash loop                                 | **P0**                |
| **H3**  | Meeting/recording deletion removes audio before the SwiftData save; recovery deletes some unmatched files; `JSONStorage` turns decode failure into empty content                                   | A partial failure can lose the only audio, resurrect/delete the wrong state, or hide data corruption as an empty transcript | **P0**                |
| **H4**  | A checkpoint identifies provider but not the cloud model, source content, full pipeline configuration/version, or exact chunk plan                                                                 | Resume can splice spans produced from a different model/file/VAD map when superficial fields still match                    | **P0**                |
| **H5**  | VAD, language detection, and diarizers intentionally return normal-looking fallback values on failure                                                                                              | A transcript can be marked done with whole-file VAD or one-speaker diarization and no durable indication of degradation     | **P1**                |
| **H6**  | Active requests are origin-pinned, bounded, correlated across attempts, and refuse ambiguous POST replay; background upload is disabled, while durable cooldown remains incomplete                 | Repeated automated activation can still retry paid work across separate operations                                          | **P0**                |
| **H7**  | Keychain writes/deletes ignore `OSStatus`; app-managed models are accepted by loose size bounds and replaced non-transactionally                                                                   | The UI can claim a key/model is ready when it is missing, corrupt, or an older valid copy was destroyed                     | **P1**                |
| **H8**  | One memory warning latches resource failure until relaunch; some task and ActivityKit/Watch continuations lack robust lifetime/timeout contracts                                                   | Work can stay disabled, outlive its UI, hang, race start/end, or acknowledge a command before durable completion            | **P1**                |
| **H9**  | Most screens hold one optional error and the shared dialog has only “OK”; many logs publish raw `localizedDescription`                                                                             | Concurrent failures overwrite each other, recovery is opaque, and diagnostic exports can carry more detail than intended    | **P1**                |
| **H10** | Clean-path CI does not inject store, filesystem, lock, process-death, route, redirect, or response-loss failures                                                                                   | The contracts above can regress while every ordinary test stays green                                                       | **P0, cross-cutting** |

### H1 · Lossless capture and truthful finalization — P0

**Plan.**

1. **Implemented (2026-08-29).** `RecordingSink` latches the first conversion/
   write/final-drain failure, attempted input/written output frame counts, and
   the last successful write time. Its render-thread failure path latches only
   bounded locked state; the main-actor meter tick handles logging, pause, and UI.
2. **Implemented (2026-08-29).** A monotonic watchdog tracks written output
   frames rather than microphone level. Two seconds without progress while the
   engine is running pauses capture and offers Resume-to-retry or Stop-to-keep;
   a retry resets the active deadline without erasing the historical warning.
3. **Implemented (2026-08-29).** Start requires 30 minutes of conservative
   configured-rate headroom above a 10 MB reserve. Capacity is refreshed every
   five seconds; after ten seconds of output, file growth raises the estimate to
   the measured byte rate. Query failure remains a visible `unknown` warning.
4. Create and durably save a provisional `Recording`/capture operation before
   opening the file. Move it through `preparing → recording → finalizing → ready`
   (or `recoveryNeeded`) so process death does not rely only on parsing a file
   name to rediscover ownership.
5. On stop, close the encoder, reopen the file, validate readability, actual
   sample duration, non-zero size, and protection class, then commit `ready`.
   Keep wall-clock duration only as diagnostic context; the file is authoritative.
6. Make resume/start failures actionable. If an engine restart fails, retain the
   partial recording and offer retry input, finish/save, or stop — never a silent
   no-op.

**Done when.** Every injected write/conversion/disk-full failure is visible within
a bounded interval; no invalid/empty file is reported as saved; killing the app
before open, during capture, during close, and during the final SwiftData save
always converges to either a valid recording or an explicit recoverable artifact.

**Verification.** Add a protocol-backed sink/file writer, deterministic frame and
clock probes, disk-full/write-failure tests, route/interruption/media-reset tests,
and a real-device matrix covering screen lock, calls/Siri interruptions,
Bluetooth disconnect/reconnect, long background capture, and low storage.

### H2 · Recoverable store bootstrap and explicit migrations — P0

**Plan.**

1. Replace the static `fatalError` container initializer with a boot state machine:
   `waitingForProtectedData`, `opening`, `ready`, `recoveryRequired`. A foreground
   failure presents a minimal recovery UI; a locked background-only launch defers
   work and completes/reschedules the system callback without first opening the
   protected store.
2. Introduce `VersionedSchema` and an explicit `SchemaMigrationPlan`. Every
   released schema gets a fixture and every non-additive change gets a reviewed
   migration stage before model code lands.
3. Classify open failures without guessing: protected data unavailable, storage
   full, migration incompatible, and suspected corruption need different actions.
4. Before a migration, create a consistent, protected backup of the store and its
   WAL state. Keep bounded generations and record which app/schema version made
   each one.
5. Never delete, replace, or silently abandon the existing store automatically.
   Offer retry after unlock/freeing space, export diagnostics, attempt salvage
   into a separate container, restore a known-good protected backup, or an
   explicitly confirmed fresh start. A new empty store must never masquerade as
   successful recovery.
6. Make store/file protection verification part of bootstrap. A directory or
   sidecar that could not be stamped is a visible privacy failure, not an
   unprotected fallback path.

**Done when.** A locked background launch, full disk, corrupt-store fixture, and
all supported N-1/N-2 schema fixtures avoid a crash loop; existing bytes remain
untouched until the user chooses a destructive action; migrations preserve
recordings, relationships, transcript JSON, summaries, and recovery state.

**Verification.** Add old-store fixtures to CI, migration round trips, protected-
data and capacity injection, backup/restore tests, and a Release-configuration
launch test. Production startup must contain no recoverable `fatalError` path.

### H3 · Atomic model/file mutations and non-destructive reconciliation — P0

SwiftData and the filesystem are two stores with no shared transaction. Treating
sequential calls as one transaction is the source of the current delete and
recovery hazards.

**Plan.**

1. Add a small durable operation journal for create/finalize/delete/replace work,
   with a stable operation ID and idempotent steps. On launch, replay or roll back
   unfinished operations instead of inferring intent from whichever side changed.
2. For deletion, save intent first, atomically move original audio and derived
   copies into a protected app trash, commit the model mutation, then purge. A
   failure before commit restores the files; a failure after commit leaves a
   retryable purge, not a visible row pointing to missing audio.
3. Stop automatically deleting readable or unreadable unmatched originals.
   Move them to a protected quarantine with size/date/reason metadata and expose
   recover/export/delete actions. Quarantine can warn about storage pressure, but
   retention is user-controlled because H-I2 outranks automatic cleanup.
4. On legacy migration collisions, verify identity/size before removing either
   copy; otherwise quarantine both under unique names.
5. Remove the unprotected fallback from `recordingsDirectoryURL`. Writers should
   throw a typed privacy/storage error if the protected directory cannot be
   created or verified.
6. Replace `JSONStorage`’s “decode failure means empty value” contract for
   authoritative content. Use versioned envelopes/checksums and return a typed
   decode result while preserving the original bytes for recovery. Encoding a
   transcript/summary/checkpoint must fail the operation rather than persist
   `Data()`.
7. Make derived copies explicitly disposable and reconcile them separately;
   originals, transcripts, and user edits use the stricter path.

**Done when.** Fault injection at every journal boundary converges after relaunch;
a failed delete never loses the only original; “Delete all data” reports residual
files accurately; malformed stored JSON is identified as corruption rather than
rendered as an empty transcript; no privacy-sensitive file is written outside a
verified protected location.

**Verification.** Add table-driven operation-journal crash points, filesystem
permission/full-disk failures, legacy collision fixtures, JSON corruption and
schema-version fixtures, plus row-without-file/file-without-row reconciliation
tests.

### H4 · Checkpoint identity and durable operation state — P0

**Plan.**

1. Replace the current partial checkpoint match with a versioned pipeline
   fingerprint containing source identity, source size/duration (and a stable
   content digest), effective preprocessing/VAD/language/ASR settings, provider
   **and exact model**, algorithm/prompt versions, compaction map, and chunk
   offsets/ranges.
2. Validate checkpoint structure before use: monotonic finite spans within source
   bounds, `completedChunks` consistent with spans, and an exact chunk-plan
   fingerprint. A mismatch discards reuse, never the source audio.
3. Make checkpoint persistence throwing. Do not start the next chunk until the
   completed chunk is durable; if saving fails, park the run with the in-memory
   result discarded rather than claim a checkpoint that only existed in RAM.
4. Persist operation state with stable reason codes, attempt count,
   `nextAttemptAt`, and last durable transition. Replace ambiguous
   `.inProgress/.pending/.failed` interpretation with explicit queued, running,
   paused-by-user, deferred-by-system/resource, retry-scheduled, permanent-failure,
   and completed semantics.
5. Bound automatic recovery. Repeated failure of the same stage/fingerprint
   backs off and eventually requires user action; foreground activation must not
   create an endless retry loop or repeated paid request.
6. Apply the same pattern selectively to expensive multi-step summary/wiki/
   document jobs: keep completed map stages or restart clearly, but never display
   a partial generation as final structured output.

**Done when.** Changing the audio, cloud model, VAD/preprocessing choice, chunk
boundaries, or algorithm version invalidates reuse; process death after any chunk
loses at most that in-flight chunk; a checkpoint save failure stops forward
progress; retries are bounded and explain why/when they resume.

**Verification.** Extend `TranscriptionCheckpointTests` and
`ChunkedTranscriptionRunnerTests` with fingerprint mutations and corrupt spans;
run kill/relaunch tests after each durable transition; script provider
response-loss to prove an already durable chunk is not rejoined under a different
configuration.

### H5 · Typed degradation and output-integrity gates — P1

Fallback is valuable: preprocessing can use the original and a transcript is
usually better than no transcript because diarization failed. The defect is not
fallback; it is losing the fact that fallback happened.

**Plan.**

1. Have each stage return a typed result carrying requested engine, effective
   engine, outcome (`succeeded`, `degraded`, `skipped`, `failed`), stable reason,
   and safe diagnostics. Cancellation remains throwing and can never be converted
   into fallback output.
2. Distinguish legitimate “no speech detected” from VAD decode/model failure.
   Likewise distinguish a genuine one-speaker result from a synthetic one-turn
   diarization fallback, and a user language hint from successful detection.
3. Accumulate a pipeline report and persist it beside the transcript. Show
   “completed with warnings” and stage-specific re-run actions rather than a
   generic success badge; exports should optionally include provenance, not raw
   private errors.
4. Add a final integrity gate: source exists and is readable; spans are finite,
   ordered, bounded and non-empty when speech was detected; text and speaker
   attribution counts are internally consistent; correction preserved segment
   identity. Reject invalid output before replacing the last known-good
   transcript.
5. Keep the previous transcript/summary/index until its replacement is fully
   validated and durably committed. Optional-stage failure must not destroy a
   usable older artifact.

**Done when.** Every injected optional-stage failure either yields valid output
with a persisted warning or leaves the previous artifact untouched; no synthetic
fallback is counted as the requested engine succeeding; users can identify and
retry the degraded stage without retranscribing unrelated work where technically
possible.

**Verification.** Build a stage-failure matrix for preprocessing, LID, VAD, each
ASR, each diarizer, fusion, correction and persistence; add invariant/property
tests for malformed timestamps, empty/oversized responses and fallback
provenance; keep WER/DER evaluation separate from reliability pass/fail.

### H6 · Exact network boundaries, bounded retry, and cost control — P0/P1

**Plan.**

1. **Implemented (2026-08-30).** Runtime destination fallback URLs are removed. Settings,
   provider factories, JSON requests, transcription, and model listing share a
   fail-closed policy requiring a public HTTPS hostname, standard port, and no
   credentials/query/fragment. HTTP, local and IP-literal destinations remain
   unsupported until an explicit policy and disclosure exists.
2. **Implemented (2026-08-30).** Each foreground request snapshots the initial
   scheme, hostname, and effective port; cross-origin/user-info redirects return
   `nil`. iOS background sessions cannot enforce this — they always follow
   redirects — so new Whisper uploads use the origin-locked foreground transport.
3. **Implemented for active traffic (2026-08-30).** `LLMHTTP` gives every new
   request typed transport/status/size errors, one total deadline, a remaining
   per-attempt timeout, a 16 MB incremental cap, cooperative cancellation,
   bounded jitter/retry, and a monotonic test clock. Background remains disabled.
4. **Implemented for active traffic (2026-08-30).** Delta-seconds and all HTTP-
   date `Retry-After` forms are honored exactly when they fit the operation’s
   explicit wait budget; longer instructions fail as the original provider error
   instead of being truncated. Interactive work allows 30 seconds, transcription
   up to 300; sleeps are logged and cancellable. Dedicated waiting UI remains.
5. **Implemented as foreground-only (2026-08-30).** No background upload entry
   point or response-buffering state remains because iOS cannot reject redirects.
   The synchronized legacy adapter only reattaches old system tasks, retains every
   relaunch completion handler, and cancels all response bodies before buffering.
6. **Implemented (2026-08-30).** One client-generated UUID identifies every
   logical request and is reused across attempts and logs. Official OpenAI chat
   endpoints receive the documented `X-Client-Request-Id` correlation header;
   no provider receives an undocumented idempotency header. A timeout or lost
   connection after an ambiguous POST returns a typed warning without auto-replay;
   the outer chunk deadline also fails instead of becoming auto-resumable. Launch
   recovery resumes only checkpoints proven on-device; cloud/unknown runs require
   manual retry. Idempotent reads and explicit HTTP failures retain bounded retries.
7. Persist a per-provider cooldown/circuit state for automated wiki/backfill/title
   work. Authentication/quota/configuration failures stop immediately; repeated
   transient failures back off across foreground activations; an explicit user
   retry can bypass the cooldown.
8. Add user policy for cellular, expensive and constrained connections,
   especially model downloads and large cloud audio uploads. Show estimated
   transfer size/destination before first use of a cloud provider.
9. Treat streaming as a separate, measured enhancement: it can improve perceived
   progress, but partial prose/JSON is not final output and must not weaken the
   atomic commit rules above.

**Done when.** No malformed custom URL produces a request to a default vendor;
redirect tests prove credentials/content stay on the approved origin; 401/403
fail without retry, 429 honors the server, transient 5xx/transport retries stay
inside one logical operation, cancellation stops waits/transfers, and automated
paid jobs cannot hammer a broken provider on every activation.

**Verification.** Extend `ProviderHTTPTests`/`LLMHTTPRetryTests` for malformed and
relative URLs, cross-origin redirects, response-size limits, lost responses,
HTTP-date rate limits, cancellation during backoff, connectivity transitions,
background relaunch, cooldown persistence and provider-specific idempotency.

### H7 · Credential and model integrity — P1

**Plan.**

1. Make Keychain get/set/delete return typed results (including `OSStatus`) and
   surface failures. Mark the accessibility migration complete only after all
   items were migrated or absence was confirmed; protected-data/transient errors
   must remain retryable.
2. Keep API-key edits in memory and commit on explicit Save instead of writing on
   every keystroke. Validate the provider URL first, then optionally test a
   minimal endpoint, and never log/display the key.
3. Consolidate the duplicate app-managed downloaders into an injectable download
   service with retry, cancellation, resume data, progress, network policy and
   an atomic staging directory.
4. Pin immutable model revisions and verify a published exact size plus SHA-256
   (or stronger signed manifest) before install. A plausible minimum size is not
   an integrity check.
5. Install by validating the staged model, atomically replacing the destination,
   then loading a small health probe. An interrupted/failed update keeps the
   previously valid model. Corruption offers re-download instead of failing every
   transcription.
6. Verify `isExcludedFromBackup`, file protection, model version and digest during
   storage inventory. Treat a consent flag as permission to fetch, not proof that
   usable bytes currently exist.
7. Give app-wide downloads an owned task and cancel/pause action; background
   expiration/process death should leave resumable state, not a permanently busy
   UI flag or an unexplained restart from zero.

**Done when.** Injected Keychain failures are visible and do not set a false
migration/success flag; wrong/truncated model bytes are rejected; cancelling or
killing an update preserves the old valid model and can resume; Settings reports
consent, download state and verified installation as separate facts.

**Verification.** Add protocol-backed Security-framework tests, locked-device
migration tests, wrong-hash/truncation/redirect/no-space download fixtures,
resume-data tests, atomic-replacement crash points and model-load smoke probes.

### H8 · Operation ownership, resource recovery, and external controls — P1

**Plan.**

1. Give every long-running operation an owner, run ID and explicit lifetime.
   Recording/transcription/downloads that intentionally outlive a screen belong
   to app-wide coordinators; chat/search tasks cancel on dismissal; stale callbacks
   must check the run ID before mutating current state.
2. Replace sticky resource state with a cooldown/recheck model. A memory warning
   pauses new heavy work for a measured interval; later admission reevaluates
   memory, thermal state and storage instead of disabling work until relaunch.
3. Add a resource-aware scheduler/cap so concurrent preprocessing, ASR,
   diarization, enhancement and model loading cannot each pass an independent
   preflight and then exceed memory together.
4. Audit every `@unchecked Sendable`, `nonisolated(unsafe)`, continuation and
   callback bridge. Keep the justified lock/queue wrappers, but make ownership
   and exactly-once completion executable through assertions and stress tests.
   Initialize the background uploader session under synchronization rather than a
   racing lazy property.
5. A timeout must actually bound work. Blocking C/CoreML calls that ignore task
   cancellation cannot be “timed out” merely by racing a sleeping child task if
   structured concurrency still waits for the blocked child; use an engine abort
   hook or report deferred cancellation truthfully.
6. Track and cancel the in-flight ActivityKit start task so `start → immediate
   end` cannot create an orphan after teardown. Keep Activity mutations on one
   actor and tag them with the recording/run ID.
7. Compile the Watch wire protocol from one shared source. Add command IDs,
   timeout, deduplication and acknowledgements that distinguish “received”,
   “state changed” and “recording durably finalized”; reconcile from application
   context after reconnect.
8. Apply the same semantics to F3 intents/controls: an intent can report that the
   request was accepted, but the in-app UI/Live Activity must confirm microphone
   permission and actual capture before claiming recording started.

**Done when.** Heavy work resumes after transient pressure, respects a global
resource cap, and has no stale callback state corruption; chat/provider work does
not continue invisibly after dismissal; rapid Live Activity start/end and lost or
duplicated Watch/intent messages converge on the recorder’s authoritative state.

**Verification.** Add deterministic clock/resource-scheduler tests, repeated
start/cancel/restart tests, continuation exactly-once tests, Thread Sanitizer runs
for first-party bridges, fake `WCSession` command loss/duplication/reordering, and
ActivityKit adapter race tests.

### H9 · Actionable error UX and privacy-safe diagnostics — P1/P2

**Plan.**

1. Extend the error presentation model around `AppError` with stable code,
   category, severity, retryability, safe user explanation, private diagnostic
   context, and recovery actions. Keep cancellation out of error dialogs.
2. Replace the universal “OK” dead end with contextual actions: Retry, Resume,
   Free Space, Open Settings, Change Provider/Model, Keep Original, Recover
   Quarantined Audio, and Export Diagnostics. Use inline state for local/degraded
   work and modal presentation only when progress is blocked.
3. Store errors per operation/recording rather than one shared optional that a
   concurrent failure can overwrite. Queue blocking errors and retain non-blocking
   warnings in the artifact’s operation report.
4. Roll back or refresh optimistic UI mutations after a persistence failure. A
   favorite/delete/title/status shown in memory must not disagree with the last
   durable state while an alert merely says “OK”.
5. Standardize structured reliability events with run/operation ID, stage,
   duration, attempt, outcome and content-free error code. Raw provider messages,
   transcript text, meeting titles, full URLs/query/user-info and API keys are
   private or omitted; use `AppError.logCode` consistently instead of publishing
   arbitrary `localizedDescription`.
6. Keep the reliability event buffer local, encrypted and bounded. MetricKit
   crash/hang capture stays opt-in and nothing is transmitted automatically.
   Export should show a redaction preview and a short reference ID that also
   appears in the UI error.
7. Add an on-device health screen for pending recovery, quarantined audio,
   degraded transcripts, failed/background jobs, model verification and recent
   error codes. It is a repair surface, not analytics.
8. Cover recovery UI with VoiceOver labels, Dynamic Type and UI tests; a robust
   backend with an inaccessible recovery action is not recoverable in practice.

**Done when.** Every P0/P1 failure has a concrete next action; concurrent failures
remain attributable; cancellation is silent/intentional; a sentinel API key,
transcript, title and URL query never appear in exported diagnostic events; a
support report can reconstruct durable transitions without containing meeting
content.

**Verification.** Add error-to-action table tests, persistence rollback UI tests,
concurrent error queue tests, diagnostic redaction fixtures, export snapshots and
accessibility audits of offline, low-storage, permission, degraded, quarantine
and store-recovery states.

### H10 · Fault injection and CI resilience — P0, cross-cutting

The architecture needs seams that fail on command. Without them, most of this
track remains prose.

**Plan.**

1. Introduce narrow protocols for filesystem mutation, model-context commit,
   clock/sleep, resource probes, Keychain, HTTP transport, audio sink/writer,
   ActivityKit and WatchConnectivity. Production adapters stay small; tests script
   exact failures and completions.
2. Maintain a fault matrix and require a test whenever a durability/network state
   transition is added. The minimum matrix is:

| Operation      | Inject at                                                                                                         | Invariant asserted after retry/relaunch                                    |
| -------------- | ----------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Capture        | prepare, file open, Nth write, route reset, disk full, close, metadata save, process kill                         | Only valid partial/full audio survives; state never reports false success  |
| Store launch   | protected data unavailable, no space, corrupt SQLite/WAL, N-1/N-2 schema                                          | No crash loop or automatic reset; recovery options preserve original bytes |
| Delete/replace | intent save, trash move, model save, purge, legacy collision                                                      | Original is restorable until durable commit; journal replay is idempotent  |
| Stored JSON    | truncated, wrong version/checksum, unknown fields                                                                 | Corruption is explicit and raw bytes remain recoverable                    |
| Transcription  | every stage, checkpoint save, process kill after each chunk, changed fingerprint                                  | At most the in-flight chunk is lost; incompatible work is never spliced    |
| Provider       | offline/DNS/TLS, timeout before/after server work, 401/403, 429, 5xx, malformed/huge body, redirect, cancellation | Destination and retry/cost bounds hold; cancellation is prompt             |
| Model/key      | locked Keychain, denied write, partial/wrong-hash model, replacement crash                                        | No false configured/installed state; prior valid material survives         |
| Integrations   | Watch reply loss/duplicate/reorder, Activity start/end race, intent double invocation                             | Commands are idempotent and reconcile to recorder truth                    |

3. Split CI signals by purpose: fast pure/unit tests, simulator integration tests,
   and UI/accessibility tests should report separately so a flaky UI launch does
   not obscure a deterministic data-integrity failure.
4. Always upload the `.xcresult`, failed-test screenshots, simulator/system logs,
   SwiftLint JSON and relevant local diagnostic artifacts on failure. Preserve
   privacy by seeding only synthetic fixtures.
5. Add a scheduled/release hardening lane: repeated cancellation/concurrency
   tests, sanitizer runs where supported, migration fixtures, Release build, and
   selected UI tests repeated to measure flake rate. Do not use blanket retries to
   turn a real failure green; classify infrastructure retries separately and
   retain the first failure artifact.
6. Add static policy checks, with explicit allow-list annotations, for new
   production `fatalError`/`preconditionFailure`, `try?` at durability boundaries,
   raw public error descriptions, custom HTTP destinations, and unowned long-lived
   tasks.
7. Keep a manual real-device release checklist for failures simulators cannot
   reproduce: lock before/after first unlock, memory/thermal pressure, nearly-full
   storage, phone-call/Siri interruption, Bluetooth route changes, background
   expiration, Watch disconnect and model compilation.

**Done when.** Every P0 item has a deterministic failing test before its fix and a
post-relaunch assertion after it; CI retains enough evidence to diagnose one run;
release candidates exercise old stores and fault paths, not only clean installs;
flake rate is measured rather than hidden.

### Reliability scorecard

The scorecard is local/test-derived first, consistent with I1. No third-party
analytics SDK or automatic report upload is required.

- **Capture:** starts, durable finalizations, partial recoveries, quarantines,
  write/watchdog failures, and actual-vs-wall-clock duration.
- **Persistence:** open/migration outcomes, failed commits, journal replays,
  protection verification, JSON corruption, and backup/salvage outcome.
- **Pipeline:** runs by requested/effective stage, checkpoints reused/discarded,
  resume attempts, degraded-stage codes, permanent failures, and prior-artifact
  preservation.
- **Network/cost:** logical operations, attempts, rate-limit wait, ambiguous
  response loss, cooldown activation, bytes sent, and approved destination ID —
  never transcript text or credentials.
- **Resources/integrations:** memory/thermal deferrals, background windows,
  Watch/Activity/intent command outcomes, timeout and reconciliation counts.
- **Quality:** crash/hang reports from the existing opt-in MetricKit path, CI
  fault-matrix pass rate, migration fixture pass rate and UI flake rate.

Do not invent a numeric reliability SLO before a baseline exists. The first
instrumented release establishes rates; later releases compare the same counters.
The immediate release gates are invariants: no loss of the only original under an
injected failure, no unintended network destination, no recoverable launch
`fatalError`, no false durable success, and every supported old-store fixture
migrates.

### Implementation sequence

1. **Baseline and seams.** Land operation IDs, safe event vocabulary, injectable
   clock/filesystem/store/network/sink adapters, and the fault-matrix harness.
   This makes every later claim reproducible.
2. **Small P0 containment.** Fail closed on invalid/custom endpoints; latch audio
   write failures; stop auto-deleting unmatched originals; detect authoritative
   JSON decode failures; make Keychain status visible.
3. **Durability core.** Ship versioned store migration/bootstrap, protected
   backups, provisional capture rows, the operation journal/trash/quarantine and
   throwing commit boundaries.
4. **Resume correctness.** Version and fingerprint checkpoints, make checkpoint
   writes gate the next chunk, validate final output, and bound automatic retries.
5. **Visible degradation and recovery.** Persist stage reports, add actionable
   error UI/health surfaces, previous-artifact preservation and repair actions.
6. **Network/model lifecycle.** Unify foreground/background HTTP policy,
   rate-limit/cooldown semantics, request identity, model digest/resume/atomic
   replacement and explicit network policy.
7. **External and concurrency hardening.** Resource scheduler, non-cooperative
   cancellation truth, shared Watch protocol, command acknowledgements and
   Activity/intent race handling.
8. **Continuous release gate.** Split CI signals, retain failure artifacts, run
   migrations/faults/sanitizers/repetition, and record the scorecard alongside
   the existing accuracy history.

P0 containment and durability take precedence over new features that widen the
same surfaces (capture entry points, import, provider work, or filesystem
mutation). Independent feature work may continue, but it does not redefine these
failure contracts.

## Suggested sequence

Unlike the rest of this document, the numbering here is real — each step makes
the next cheaper or more verifiable.

1. **Extract the pure types into a package — done.** First, because it speeds
   up verification of everything after it — including the pipeline changes F2
   introduces. The Accelerate-dependent "Speakers" group is the one deliberate
   gap; see the section above.
2. **F3 · Frictionless capture — done.** Shipped in
   [PR #143](https://github.com/carlosmazzei/Kurn/pull/143); external-command
   acknowledgement and race hardening continue under H8 rather than reopening
   the feature itself.
3. **F1 · Apple Foundation Models — done.** Shipped in
   [PR #139](https://github.com/carlosmazzei/Kurn/pull/139): provider
   plumbing, auto-tagging, retrieval chat and per-provider summary thresholds,
   in that order. Left open: measuring the on-device thresholds against real
   runs, and exercising correction/wiki/document generation against the new
   provider.
4. **F2 · Meeting glossary.** After step 1, so the WER effect can be measured
   without waiting on simulator CI.
5. **F4 · Calendar context.** Feeds F2 real names and unlocks cross-meeting
   speaker identity, so it wants F2 in place to pay off.
6. **F5 · Reminders and F6 · Import.** Independent of each other and of the
   rest; slot them in as room appears.
7. **Reassess F7, F8, F9 and F10.** F7 especially: F1 now delivers "works with
   no key" wherever the on-device provider is actually available — see F7's
   own entry above for what's still unmeasured.

The diarization track runs on its own clock, because two of its items are
defects and because D2 is a prerequisite rather than a feature:

- **D2 first, and early — done.** It was cheap, and every later diarization
  decision was guesswork without it.
- **D1 next — done.** It was a correctness defect that silently attached a
  user's typed name to the wrong person, which is worse than any accuracy
  number here.
- **D6 — done standalone, ahead of F4.** The voiceprint half shipped without
  waiting on calendar context; the two halves of speaker identity still pay
  off more together, so F4 remains worth doing for the names it would add as
  candidates.
- **D5 decided — keep truncating.** No transcription engine in the app
  produces separate text for simultaneous speech, so an overlap-aware
  diarizer would have nothing to render regardless of the UI; this was never
  really a UI question. **D4 is downgraded accordingly**: it would have to be
  justified purely by VBx-collapse resistance on far-field audio (measurable
  via D2's raw-turn DER), not by overlap handling. Still just "evaluate", not
  scheduled.
- **D3 whenever the provider question is reopened**, not before: it presumes a
  transcription provider the app does not have today.
