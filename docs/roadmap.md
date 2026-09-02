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

The execution sequence, PR boundaries, dependencies, acceptance gates, and
cross-session handoff are maintained in
[`docs/resilience-megaplan.md`](resilience-megaplan.md). This section remains the
source of truth for product invariants, risks, and H1–H10 contracts; keep the two
synchronized when evidence changes.

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

### Current implementation status (2026-09-01)

Status here is evidence-based and deliberately distinguishes an injectable seam
from the production invariant that will eventually use it. PR
[#151](https://github.com/carlosmazzei/Kurn/pull/151) established the first
baseline; later rows include controls that predated that PR where they already
satisfy part of a planned contract.

| Track              | Status                 | Implemented evidence and remaining contract                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------ | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Baseline and seams | **In progress**        | `OperationID`/`ReliabilityEvent`, injectable `SleepClock`, scoped `FileSystem`, `ModelContainerFactory`, `AudioSinkWriting`, and deterministic fakes are present. Filesystem/store/network coverage is still intentionally narrow, and there is no complete fault-matrix harness.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| **H1**             | **Core implemented**   | `RecordingSink` latches write-path failures and exposes frame progress; a two-second watchdog pauses stalled capture with retry/stop actions. Recording preflights and measures storage runway. A `Recording` row now owns a UUID-derived file before open and moves durably through `preparing → recording → finalizing → ready/recoveryNeeded`; re-entry and cross-context ownership fail before capture. One shared finalizer reopens the closed file, measures duration/bytes and applies/verifies protection before `ready`. Launch/foreground recovery reconciles interrupted rows, preserves partial bytes, and exposes explicit retry while playback, transcription, export, compaction and enhancement reject non-ready rows. Focused fault suites and the full simulator suite cover the core; real-device protection, interruption/route, long-background and low-storage scenarios remain the release checklist.                                                                                                                                                                                                                                                               |
| **H2**             | **Done, merged (PR #155, #157, #158)** | `KurnSchemaV1`/`KurnSchemaMigrationPlan`, `ModelStoreBootCoordinator`, `ModelStoreBackupManager` (protected, bounded-generation backups + quarantine), `ModelStoreSalvage` (best-effort read-only recovery), `ModelStoreProtection.applyAndVerify`, and an expanded `ModelStoreRecoveryView` (restore/salvage/diagnostics/confirmed-fresh-start) are all on `main`. The recoverable production `fatalError` is gone, background-task registration runs before the store is ever opened, and a real use-after-free found during PR #158 (fetched `Meeting`s outliving their `ModelContainer`, which would have crashed users on the recovery screen) is fixed. See the H2 handoffs above the H2 plan for the full history. |
| **H3**             | **Done, merged (PR #159, #160, #162, plus the PR 6/PR 7 boundaries)** | PR 1 ([#159](https://github.com/carlosmazzei/Kurn/pull/159)) fixed the risk register's deletion hazard: `RecordingTrash` makes meeting/recording deletion move-then-purge instead of delete-then-delete, with launch/foreground reconciliation for an interrupted delete. PR 2 ([#160](https://github.com/carlosmazzei/Kurn/pull/160)) fixes the JSON-corruption hazard for `Transcript.segments`/`Summary.sections` — see the H3 PR 2 handoff above the H4 plan. PR 3 ([#162](https://github.com/carlosmazzei/Kurn/pull/162), the megaplan's "PR 5" boundary) removes the unprotected `recordingsDirectoryURL` fallback (writers throw `AppError.protectedStorageUnavailable`), quarantines unmatched/malformed/unreadable/too-short originals and legacy-migration collisions in `RecordingQuarantine` with size/date/reason metadata and recover/export/confirmed-delete in Storage Settings. The megaplan's "PR 6" boundary adds `RecordingOperationJournal`: durable delete/replace intent written before any file moves, launch/foreground replay/rollback from the record's own state ahead of the heuristic trash sweep, a journaled compaction swap, and accurate residual-file reporting for "Delete All Data". The megaplan's "PR 7" boundary extends the versioned authoritative envelope to the transcription checkpoint: `Recording.transcriptionCheckpoint` writes `JSONStorage.encodeAuthoritative` envelopes (a failed encode keeps the previous resumable point), `transcriptionCheckpointOutcome` distinguishes `.corrupted` from `.empty` while legacy bare payloads still decode and corrupted bytes are preserved, and both the transcribe path and `TranscriptionRecovery`'s stale sweep treat a corrupted checkpoint as an explicit non-resumable state instead of "never checkpointed". Operation reports do not exist yet (H5) and adopt the envelope when introduced. All boundaries are merged into `main`, closing the H3 track scope. |
| **H4**             | **Done, merged (PR [#165](https://github.com/carlosmazzei/Kurn/pull/165), [#166](https://github.com/carlosmazzei/Kurn/pull/166), [#167](https://github.com/carlosmazzei/Kurn/pull/167))** | `TranscriptionPipelineFingerprint` and `TranscriptionCheckpoint.isStructurallyValid` (PR 8, items 1–2 of the plan) replace the old engine/language/compaction/provider-only match with source size/duration/content-digest, effective preprocessing/VAD, exact ASR provider+model, a compaction-map digest, and a separately-checked exact chunk-plan digest. PR 9 (items 1, 2, 4) makes `ChunkedTranscriptionRunner`'s chunk-completion callback `async throws` and awaited before the next chunk starts, so a checkpoint-save failure stops the run instead of continuing past a chunk that was never made durable, and bounds automatic (unattended) resume attempts per recording (`Recording.automaticResumeAttempts`, reset by any manual retry) so a systemic failure can't retry forever — or, for a cloud engine, keep re-paying — every time the app launches or foregrounds. See the "Progress" note under H4 for what shipped in each PR and the one deliberate PR 8 compatibility break. PR 10 (item 6) extends the same gated-durable-progress contract to the map stage of staged summary and wiki generation (`SummaryMapCheckpoint`/`SummaryMapRunner`, one shared `Meeting.summaryMapCheckpointData`); `DocumentGenerationService` is deliberately excluded, since a document can span several meetings and has no single `Meeting` to checkpoint against. Only item 3 (the full explicit operation-state enum with reason codes/`nextAttemptAt`) remains, deliberately deferred.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| **H5**             | **Done (PR 11 merged in [#168](https://github.com/carlosmazzei/Kurn/pull/168); PR 12 merged in [#169](https://github.com/carlosmazzei/Kurn/pull/169); PR 13 implemented)** | Typed stage outcomes and a pipeline report persisted in `Transcript.pipelineReportData` are implemented for every stage (plan items 1–2 and the durable half of item 3, PR 11, merged). `TranscriptIntegrityGate` rejects a structurally broken fused/corrected result or an identity-violating correction before it can replace an existing transcript (items 4–5, PR 12, merged); summary and semantic-index replacement already kept the previous artifact until the new one was ready and needed no change. `MeetingDetailView` now surfaces a completed-with-warnings banner from the stored report, and correction — the one stage cheap enough to retry in isolation — gets its own retry action; every other warning falls back to the existing full re-transcribe confirmation (PR 13).                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| **H6**             | **Core implemented**   | Provider URLs fail closed and all new cloud traffic uses one origin-locked, deadline-bounded, 16 MB-capped foreground policy with exact budgeted `Retry-After`. Each logical request owns one UUID reused across attempts; official OpenAI chat requests also send it as the documented correlation header, never as an undocumented idempotency claim. Ambiguous POST timeouts/connection loss stop without automatic replay and surface a typed duplicate-charge warning. Background upload has no creation API or response-buffering state; its synchronized adapter only drains old system tasks. A durable per-provider circuit gates automatic title/wiki/backfill work. Large transfers default to unrestricted Wi-Fi: app-owned audio uploads/model sessions carry native expensive/constrained flags, while FluidAudio downloads fail preflight on a disallowed path. Cloud consent is pinned to provider plus URL and discloses hostname and estimated hourly audio size; model dialogs disclose source and approximate size. Non-blocking follow-ups are dedicated waiting UI under H9, FluidAudio’s unobservable mid-transfer path changes, and measured streaming evaluation. |
| **H7**             | **Done, merged ([#171](https://github.com/carlosmazzei/Kurn/pull/171)/[#172](https://github.com/carlosmazzei/Kurn/pull/172)/[#173](https://github.com/carlosmazzei/Kurn/pull/173))** | Typed `KeychainReadOutcome`/`KeychainWriteOutcome`/`KeychainFailureReason` replace the old API that collapsed every Security-framework failure into "not configured"; the accessibility migration now only completes after a confirmed outcome instead of after a failed fetch; provider credential edits commit only on explicit Save, after URL validation, with a failed write surfaced rather than silently assumed (PR 14). The whisper.cpp and sherpa-onnx downloaders now share one injectable `ModelDownloading` actor that verifies a completed download's exact byte count against the server's declared `Content-Length` and, when volunteered, its SHA-256; installs atomically with backup-and-restore on any post-install mismatch; keeps resume data across an interrupted transfer; and exposes a Cancel action wired into every download progress row (PR 15). `ModelVerification` now persists whether a model has actually been proven to load — a third fact next to consent and bytes-on-disk — via a real post-install health probe for whisper.cpp/sherpa-onnx and, for the four FluidAudio-backed sets, by recording the load their own download already performs; a storage-inventory pass flags on-disk size drift as corruption and repairs `isExcludedFromBackup`; Settings → Storage shows the result per row (PR 16, merged as [#173](https://github.com/carlosmazzei/Kurn/pull/173)). Remaining: whisper.cpp still resolves against a mutable HuggingFace branch rather than a pinned revision (no network path to obtain a real commit SHA in either PR's authoring environment) — the one item across all three PRs left open.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| **H8**             | **Done, plan fully addressed (PR 17/18/19/20)** | `MemoryPressureState` replaces the sticky memory-warning latch — a boolean set once by the first `UIApplicationDidReceiveMemoryWarning` and never cleared for the rest of the process — with an observed-at/cooldown/recheck model: new heavy work pauses for a measured interval after the *last* observed warning, then admission re-evaluates automatically, plus a live thermal-state check with no cooldown of its own. `ResourceScheduler`, a global actor-isolated weight budget, now gates preprocessing, transcription (per engine), diarization (per engine), enhancement, and model loading at their existing funnel points, so two concurrent transcriptions picking the same heavy engine can no longer both pass an independent preflight and then both hold that engine's memory at once (items 2–3, PR 17, merged as [#174](https://github.com/carlosmazzei/Kurn/pull/174)). A full audit of every `@unchecked Sendable`/`nonisolated(unsafe)`/continuation bridge fixed two "false timeouts" that raced a sleeping timer against a blocking call neither engine can actually abort — a `TaskGroup` can't return until every child finishes, so the race never bounded time, it just discarded a valid slow result for a fabricated error (`SherpaOnnxDiarizer`, `FluidAudioVAD`) — plus a leaked mic-picker continuation and an unsynchronized mutable property (items 4–5, PR 18, merged as [#175](https://github.com/carlosmazzei/Kurn/pull/175)). `LockScreenRecordingController` closes the ActivityKit start/end race with a `runID` generation counter checked synchronously right before the one non-cancellable `Activity.request` call (item 6, PR 19, merged as [#176](https://github.com/carlosmazzei/Kurn/pull/176)). `WatchCommand`/`WatchSessionKey` now compile from one shared file into both the `Kurn` and `KurnWatch` targets; Watch commands carry a `commandID` the phone deduplicates against, a bounded local timeout, and a three-phase `WatchAckPhase` reply; the phone reconciles a stale application context on every reconnect; `StartRecordingIntent` awaits an acceptance reply instead of assuming success; and `MeetingChatViewModel`'s reply task now cancels on dismissal (items 1, 7–8, PR 20).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| **H9**             | **In progress (PR 21, PR 22 merged; PR 23 implemented)** | `AppError.logCode` and the content-free `ReliabilityEvent` vocabulary were already present. `AppErrorCategory`/`AppErrorSeverity`/`AppErrorRecoveryAction`/`privateContext` add the presentation metadata item 1 asks for (PR 21). `TranscriptionViewModel.errorsByRecording` fixes the one concrete "concurrent failures overwrite each other" case found: the view model is a single app-wide shared instance, so two recordings' transcription failures used to clobber or misattribute each other through one `error` property (PR 21). `ReliabilityEventStore` gives the reliability-event vocabulary a bounded, protected on-device buffer, `transcribe` gets its own instrumentation, four public raw-error-description log sites are fixed, and a redaction-preview export screen lists/shares recent events (PR 22). `HealthRecoveryView` (Settings → Health & Recovery) aggregates pending recovery, quarantine, degraded transcripts, failed/deferred jobs, model verification and recent failure codes behind one screen, dispatching every action to the exact same recovery function its existing per-item UI already calls (items 7–8's repair surface, PR 23). Contextual recovery-action UI, optimistic-UI rollback, a reference ID in the UI error dialog, and health/recovery-center accessibility test coverage remain, deliberately deferred.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| **H10**            | **Started**            | Clock, filesystem, store-factory, reliability-event, and audio-sink fakes prove initial seams. The full transition fault matrix, split CI signals, retained failure artifacts, sanitizers/repetition, static policy checks, and device checklist remain.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |

### Foundation already present

The plan builds on these controls rather than replacing them:

| Area          | Existing control                                                                                                                                                 |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Error domain  | `AppError` provides localized, content-free `logCode`s; `errorAlert` gives views one presentation path                                                           |
| Capture       | Fixed-format `RecordingSink`, audio interruption/route observers, engine restart, `finalizeIfAbandoned`, protected recording storage, and orphan recovery        |
| Transcription | Per-chunk checkpoints, ordered pipeline events, foreground and launch recovery sweeps, background task cancellation, and per-recording/global in-flight guards   |
| Pipeline      | Resource checks between heavy stages, temporary-file cleanup, measured WER/DER, and useful fallbacks for optional preprocessing/VAD/diarization stages           |
| Network       | Fail-closed destinations, origin locks, total deadlines, response caps, logical request identity, bounded retry/cooldown, and Wi-Fi-first large-transfer consent |
| Diagnostics   | Leveled `os.Logger`, user-exported logs, opt-in local MetricKit crash/hang reports, and no automatic diagnostic upload                                           |
| Tests         | 600+ Swift Testing cases, provider stubs through `MockURLProtocol`, recovery/resource tests, accessibility audits, and Linux `KurnCore` CI                       |

### Risk register

These are verified code paths or direct consequences of them, not hypothetical
feature requests:

| Item    | Observed seam                                                                                                                                                                                                                       | Failure if it remains                                                                                                       | Priority              |
| ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- | --------------------- |
| **H1**  | Durable capture ownership, file-measured finalization, recovery rows and ready-only consumer gates are implemented; simulator tests cannot observe iOS Data Protection or reproduce physical route/interruption/background pressure | A device-only regression could still interrupt capture or misclassify protection until the release matrix is executed       | **P0 release gate**   |
| **H2**  | A `VersionedSchema`/`SchemaMigrationPlan` exists, the recoverable production `fatalError` is replaced by a classified boot state machine, and protected backup, restore, salvage, and confirmed-fresh-start are all merged (PR #155, #157, #158) | An open failure no longer crash-loops; only a genuinely un-migratable/corrupt store can strand the user beyond what salvage and restore already offer | **Done**               |
| **H3**  | Deletion no longer removes audio before the SwiftData save commits (PR 1, merged); a corrupted transcript/summary is no longer indistinguishable from an empty one (PR 2, merged); recovery quarantines unmatched originals instead of deleting them and writers fail closed on protected storage (PR 3, [#162](https://github.com/carlosmazzei/Kurn/pull/162), merged); `RecordingOperationJournal` records delete/replace intent before any file moves and replays or rolls it back on launch/foreground (PR 6, `d7e3dee`), and the versioned authoritative envelope now covers the transcription checkpoint (PR 7, `e7a156a`) | A non-delete mutation interrupted mid-flight now converges from its own recorded intent instead of inferred state; operation reports adopt the same envelope when H5 introduces them | **Done**              |
| **H4**  | A checkpoint fingerprints source content, preprocessing/VAD, exact ASR provider/model, the compaction map, and the exact chunk plan (PR 8); a checkpoint save is now awaited and gates the next chunk, and automatic resume attempts are bounded per recording (PR 9); the map stage of staged summary/wiki generation checkpoints the same way (PR 10); it still doesn't use the plan's full explicit operation-state enum (reason codes, `nextAttemptAt`) | Bounded automatic recovery and a throwing durable commit are both in place; a richer operation-state model remains open if a concrete need for it shows up | **P0 → closed except item 3** |
| **H5**  | `TranscriptIntegrityGate` rejects a structurally broken fused/corrected result or a correction that violated its identity contract before it can replace an existing transcript (H5 PR 12); VAD/LID/diarization degradation is recorded in `PipelineReport` rather than silently returning a normal-looking fallback (H5 PR 11); the report is now surfaced in the Transcript tab with a stage-specific retry for correction (H5 PR 13)                                                                                                                | Resolved for the paths above; H5's plan is fully addressed                                                    | **Done** |
| **H6**  | App-owned large transfers enforce user-selected expensive/constrained flags; FluidAudio is preflight-gated because its internal session is not configurable                                                                         | A network becoming expensive after a FluidAudio download starts cannot yet be cancelled through the library                 | **P1**                |
| **H7**  | `KeychainAccessing` now classifies absent vs locked/denied/transient instead of collapsing every failure to "not configured", and the accessibility migration only completes after a confirmed outcome (H7 PR 14); app-managed downloads now verify an exact declared size plus an opportunistic SHA-256 and install atomically with backup-and-restore on any failure (H7 PR 15); a model that installs cleanly is no longer assumed usable — a post-install health probe (or, for FluidAudio, its own unavoidable load-at-download-time) has to succeed first, and a storage-inventory pass catches later drift (H7 PR 16) — but whisper.cpp is not yet pinned to an immutable revision                                                                                                    | Resolved for the Keychain paths above; a model can no longer be silently truncated, destroy the previous valid copy on a failed replace, or sit corrupted-but-marked-installed until a real transcription fails; whisper.cpp still trusts a mutable branch pointer                                       | **P1 → closed except one item** |
| **H8**  | A memory warning now pauses new heavy work for a cooldown interval instead of latching a permanent block, and a live thermal-state check gates admission too (H8 PR 17); a global weight budget caps concurrent preprocessing/ASR/diarization/enhancement/model-loading across recordings (H8 PR 17); an audit of every concurrency bridge fixed two false timeouts, a leaked continuation, and an unsynchronized mutable property (H8 PR 18); the ActivityKit start/end race is closed by a `runID` generation counter (H8 PR 19); Watch commands are deduplicated, timed out, and acknowledged in three phases, the phone reconciles a stale application context on reconnect, `StartRecordingIntent` reports accepted rather than assumed, and the one remaining unowned chat task now cancels on dismissal (H8 PR 20); no Thread Sanitizer configuration exists yet                                                                                    | Resolved for every path above; **H8's plan is fully addressed**, with only the (deliberately out of scope for CI stability) Thread Sanitizer gap remaining, tracked under H10            | **Done** |
| **H9**  | Most screens still hold one optional error and the shared dialog has only "OK"; `AppError` now carries category/severity/retryability/a recovery-action id/private context (H9 PR 21), and `TranscriptionViewModel`'s one concrete concurrent-clobbering case is fixed (H9 PR 21); the reliability-event vocabulary now has a bounded, protected on-device buffer and an export screen, and the four exact sites publishing a raw `AppError.errorDescription` at `.public` are fixed (H9 PR 22); a "Health & Recovery" screen now aggregates pending recovery, quarantine, degraded transcripts, failed/deferred jobs, model verification and recent failure codes behind one repair surface, dispatching to existing recovery actions rather than reimplementing them (H9 PR 23)                                                                                                              | Contextual recovery actions, optimistic-UI rollback, a reference ID in the UI error dialog, and every other view model's shared error property remain; the broader non-`AppError` raw-log sweep is unaudited; the new health screen has no VoiceOver/Dynamic Type/UI-test coverage of its own    | **P1 → partially closed (H9's plan addressed except items 2 and 4)**                |
| **H10** | Clean-path CI does not inject store, filesystem, lock, process-death, route, redirect, or response-loss failures                                                                                                                    | The contracts above can regress while every ordinary test stays green                                                       | **P0, cross-cutting** |

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
4. **Implemented (2026-08-30).** A UUID-backed `Recording`/capture operation is
   durably saved before file open and moves through `preparing → recording →
   finalizing → ready` (or `recoveryNeeded`). New filenames bind the meeting and
   recording identities; filename parsing remains only for legacy orphan recovery.
5. **Implemented (2026-08-30).** Stop closes the encoder, then one shared finalizer
   reopens the file, validates readability, measured sample duration, non-zero size
   and protection before `ready`. Wall-clock duration remains diagnostic only.
6. **Implemented for the core flow (2026-08-30).** Start is re-entry/cancellation
   aware; failed or interrupted capture preserves a recovery row and any useful
   bytes. The detail screen exposes retry/finalize and confirmed deletion while
   normal consumers reject non-ready rows. Device interruption/route behavior
   remains in the release matrix.

**Done when.** Every injected write/conversion/disk-full failure is visible within
a bounded interval; no invalid/empty file is reported as saved; killing the app
before open, during capture, during close, and during the final SwiftData save
always converges to either a valid recording or an explicit recoverable artifact.

**Verification evidence.** Protocol-backed sink/finalizer seams cover write,
conversion, stall, final-drain, missing/empty/unreadable/protection failures and
provisional ownership before file creation. Recovery tests exercise `preparing`,
`recording`, `finalizing`, explicit acceptance of a validated partial, legacy
orphans and active-session exclusion. The 2026-08-30 simulator run passed 738
cases with six intentional skips after excluding the environment-dependent local-
model inventory suite; 83 KurnCore cases and SwiftLint also passed. Route/
interruption/media-reset tests and the real-device screen-lock, calls/Siri,
Bluetooth, long-background and low-storage matrix remain release gates.

#### H1 implementation handoff (2026-08-30)

This is the continuation point for a new engineering session. The implementation
was merged by PR #153 as commit `458a502`, following the H6 work in PR #152.
Start subsequent code work from updated `main`; do not recreate the deleted H1
branch or duplicate the merged lifecycle changes.

**Landed in the working tree.**

- `RecordingCaptureState.swift` defines the durable capture lifecycle and stable
  recovery reasons. `Recording` stores both raw values, defaults legacy rows to
  `ready`, and fails an unknown future state closed as `recoveryNeeded`.
- `RecorderViewModel.prepareCaptureOwnership()` inserts and commits a UUID-backed
  provisional row before `AudioRecorderService` can open its file. The filename
  contains both meeting and recording IDs. A foreign `ModelContext`, re-entrant
  start, or provisional-save failure stops before capture.
- `RecordingLifecycleSaving` is the narrow SwiftData commit seam. Tests inject
  provisional/final save failures and prove the last committed state remains the
  authority instead of the in-memory mutation.
- `AudioRecorderService.start(fileName:)` reserves the destination before async
  setup, rejects duplicate start, observes task cancellation around session/
  engine setup, and cleans up a cancelled or failed start. Explicit cancellation
  during setup cannot later produce a headless recording.
- `RecordingFileFinalizer` is shared by normal stop and recovery. It requires an
  existing non-empty readable file, derives duration from samples, and applies/
  verifies `.completeUnlessOpen` before returning authoritative metadata.
  Protection readback is intentionally skipped on the simulator because that
  environment does not expose iOS Data Protection; an injected failure covers
  the code path and the physical-device matrix covers enforcement.
- Stop commits `finalizing` before teardown and only commits `ready` after the
  finalizer succeeds. Sink/stall/validation failures preserve useful bytes as
  `recoveryNeeded`; a known failed start with zero bytes removes its provisional
  row instead of creating a false recoverable artifact.
- `RecordingRecovery` reconciles `preparing`, `recording` and `finalizing` rows at
  launch/foreground through the same finalizer, keeps the legacy filename scan
  for pre-lifecycle files, and exposes explicit retry to accept a validated
  partial recording.
- Meeting detail renders a recovery row and retry action. Playback,
  transcription/recovery scheduling, export/share, compaction and enhancement
  reject non-ready rows. `SegmentPlaybackScrubber` moved to its own file so this
  UI work did not push `MeetingDetailView` over its serious lint limit.
- All seven localizations contain the new capture/recovery strings. `CLAUDE.md`
  records the lifecycle and the single-finalizer rule.

**Verification observed locally.**

- `swiftlint lint --config .swiftlint.yml`: zero serious violations. Remaining
  warnings are the repository's existing warning-level debt; no new
  `RecorderViewModel` complexity warning remains.
- Focused ownership/finalizer/recovery/sink suites pass, including foreign-context,
  provisional-save, final-save, protection, interrupted-state and legacy-orphan
  cases.
- `xcodebuild ... test -skip-testing:KurnTests/WhisperCppModelTests`: 738 passed,
  zero failed, six intentional skips. The excluded suite inspects models installed
  on the developer machine and is the already documented environment-dependent
  local inventory test.
- `swift test` in `Packages/KurnCore`: 83 passed.
- Localization key parity/duplicates and `git diff --check`: clean.

The first full run provided useful fault evidence: a `RecordingLauncher` test left
a pending `Meeting` from a test `ModelContext` in the app-wide singleton, and the
app UI attempted to use it with the production context. SwiftData aborted in the
new provisional insert. The capture boundary now rejects that mismatch before
insert, and `RecorderCaptureOwnershipTests` pins the regression. Durable launcher
queue ownership/deduplication remains H8 rather than being expanded in this PR.

**Continuation checklist.**

1. Keep the Xcode-generated
   `Kurn.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` out
   of this resilience change unless dependency pinning is reviewed separately.
2. Open or inspect the H1 PR and use its GitHub `iOS CI` result as the final merge
   source of truth. The local suite excluded only the known model-inventory test;
   CI starts from a clean runner and should execute its normal configuration.
3. Keep the real-device H1 matrix open as a release gate: protection readback,
   lock during capture, calls/Siri, Bluetooth disconnect/reconnect, long
   background recording and nearly-full storage.

**Next code PR: H2 schema baseline only.** Start it from updated `main` after H1
merges; do not stack it on the unmerged H1 branch. Keep the first H2 review small:

1. Centralize the complete model list currently embedded in `KurnApp` so
   production, screenshot containers and `TestModelContainer` cannot diverge.
2. Declare that graph as the first `VersionedSchema` and add an explicit
   `SchemaMigrationPlan`; preserve current production bytes and treat local
   development reset only as a development convenience.
3. Establish committed synthetic fixtures for the oldest supported released
   layouts and a migration/open round trip covering relationships, transcript/
   summary JSON, checkpoints and the new capture recovery state. Investigate and
   document how the existing unversioned SwiftData store is adopted before
   changing the production configuration—do not assume it migrates.
4. Make schema/version selection injectable through `ModelContainerBootstrap`
   and extend `ModelContainerBootstrapTests`; do not add backup/salvage UI or
   remove the production `fatalError` in this first PR.
5. Done means current stores and every committed fixture open without silent
   reset, the centralized schema is used everywhere, Release and Debug builds
   pass, and a future model change cannot land without a migration stage/fixture.

The following H2 PR then introduces the boot state machine and failure
classification; protected backup/restore/salvage/recovery UI remains the third H2
PR, matching the dependency order below.

#### H2 schema-baseline PR — merged (2026-08-30)

[PR #155](https://github.com/carlosmazzei/Kurn/pull/155) merged into `main` as
commit `a14fab3`. This session has no macOS/Xcode toolchain, so — per
"Verifying without a local macOS/Xcode toolchain" above — nothing here was
claimed to compile or pass locally before CI ran; the GitHub `iOS CI` result on
the PR was the source of truth (see "Observed on PR #155" below), and it was
green before merge.

**Landed in the working tree.**

- `Kurn/Infrastructure/KurnSchema.swift` is new: `KurnSchemaV1: VersionedSchema`
  lists the same eleven `@Model` types production always used, tagged
  `Schema.Version(1, 0, 0)`; `KurnSchemaMigrationPlan: SchemaMigrationPlan`
  declares `schemas: [KurnSchemaV1.self]` with `stages: []` — correct and
  complete for a first-ever versioned schema, since there is nothing to
  migrate *from* yet. `KurnModelGraph` is the one place `KurnApp`,
  `ModelContainerBootstrap`, and `TestModelContainer` now read the model list,
  the versioned `Schema`, and the migration plan from, closing the divergence
  risk item 1 named.
- `ModelContainerBootstrap.makeStore` gained a `migrationPlan:` parameter
  (defaulting to `KurnModelGraph.migrationPlan`) alongside `schema:`
  (defaulting to `KurnModelGraph.schema`); `ModelContainerFactory` and
  `SystemModelContainerFactory` widened to match, so schema/version selection
  is injectable exactly as item 4 asked. The production `fatalError` in
  `KurnApp` and the DEBUG screenshot container are untouched otherwise — no
  boot state machine, no backup/salvage UI, matching item 4's "not in this
  PR" boundary.
- `KurnTests/LegacyStoreAdoptionTests.swift` is new and covers item 3's
  round-trip requirement: it builds a store at a temp file URL with a bare,
  unversioned `Schema(KurnModelGraph.currentModels)` — the exact shape every
  Kurn store predating this PR was created with — populates one of every
  model type (including a `.recoveryNeeded` recording with a live
  `TranscriptionCheckpoint`, JSON-backed highlights/summary sections/semantic
  vectors, and folder/tag/speaker relationships), then reopens the identical
  file through `KurnModelGraph.schema` + `KurnSchemaMigrationPlan` and asserts
  every field and relationship survives.
- **Deviation from item 3, and why:** the item asked for "committed synthetic
  fixtures for the oldest supported released layouts." No app version before
  this PR ever declared a schema version, so there is no earlier *released*
  layout structurally different from today's to fabricate — version 1.0.0
  *is* the oldest layout. A hand-built binary SwiftData/Core-Data store file
  was ruled out rather than attempted: this environment has no Xcode to
  produce or validate one, and a malformed hand-crafted fixture would fail in
  ways indistinguishable from a real regression. `LegacyStoreAdoptionTests`
  instead generates the legacy-shaped store at run time and round-trips it in
  the same test, on CI's real macOS/SwiftData runtime — deterministic,
  requires no binary in the repository, and is the concrete evidence for "how
  the existing unversioned SwiftData store is adopted" that item 3 asked to
  document. If a genuine pre-this-PR device store ever surfaces, it can be
  added as a second fixture without changing this test's shape.
- `KurnTests/ModelContainerBootstrapTests.swift` extended with
  `defaultsToTheCentralizedVersionedSchemaAndMigrationPlan` (proves `makeStore`
  reaches a factory with `KurnModelGraph`'s schema/migration plan by default)
  and a new `KurnModelGraphTests` suite (the eleven models are declared
  exactly once, the migration plan is the documented single-schema/no-stages
  shape, and `KurnSchemaV1.models` matches `KurnModelGraph.currentModels`).
  The two pre-existing tests now pass `migrationPlan: nil` explicitly, keeping
  their original narrow scope (the factory-failure/success plumbing only).

**First CI round found one compile error, fixed and re-verified.**
`LegacyStoreAdoptionTests.swift` originally referenced the bare type `Tag` in
two type-annotation positions (a return-tuple label and a parameter type);
`import Testing` brings its own `Tag` type (used for `@Test(.tags(...))`) into
scope, and the two collided — `'Tag' is ambiguous for type lookup in this
context` at both spots. Constructor calls like `Tag(name:...)` resolved fine
via argument-label overload resolution, only the bare type positions did not.
Fixed by qualifying both as `Kurn.Tag`; pushed as `e5b84eb`.

**Observed on PR #155 (2026-08-30, commit `e5b84eb`).** GitHub `iOS CI`:
`build-and-test` — pass (SwiftLint, `xcodebuild build`, and the full
`xcodebuild test` run, including the new `LegacyStoreAdoptionTests` and
`KurnModelGraphTests`/`ModelContainerBootstrapTests` cases); `kurncore-linux` —
pass. No unresolved review comments. This is the first real evidence that the
versioned schema/migration plan compiles and that the unversioned-store
adoption round trip holds on CI's actual macOS/SwiftData runtime — not just
that the reasoning above is internally consistent.

**Next code PR: H2 recoverable bootstrap state machine** (`docs/resilience-megaplan.md`
PR 3) — `waitingForProtectedData`/`opening`/`ready`/`recoveryRequired`,
failure classification, and removing the recoverable production `fatalError`.
Start it from updated `main` after this PR merges; do not stack it on this
unmerged branch. Backup/restore/salvage/recovery UI remains the PR after that
(PR 4), matching the dependency order in the megaplan.

#### H2 boot state machine PR — merged (2026-08-30)

[PR #157](https://github.com/carlosmazzei/Kurn/pull/157) merged into `main` as
commit `12850ae`, on top of `77f4d90`. `iOS CI` (`build-and-test`,
`kurncore-linux`) passed on the very first push (`fcb9c7b`) — no fix round
needed, unlike PR 2's `Tag`/`Testing.Tag` ambiguity. This session has no
macOS/Xcode toolchain, so nothing here was
claimed to compile or pass locally before pushing — `iOS CI`'s result was
the source of truth, per "Verifying without a local macOS/Xcode toolchain."

**Landed in the working tree.**

- `Kurn/Infrastructure/ModelStoreOpenFailure.swift` is new:
  `ModelStoreOpenFailureReason` (`protectedDataUnavailable`, `storageFull`,
  `migrationIncompatible`, `corruptOrUnknown`) and
  `ModelStoreOpenFailureClassifier`, a pure function over an `Error`'s NSError
  bridge that recognizes known POSIX (`EPERM`/`ENOSPC`), Foundation
  (`NSFileWriteOutOfSpaceError`, `NSFileReadNoPermissionError`, ...), and Core
  Data (`NSMigrationError`, `NSPersistentStoreIncompatibleVersionHashError`,
  ...) signatures — unwrapping one level of `NSUnderlyingErrorKey`, bounded to
  a depth of 5 — and falls through to `.corruptOrUnknown` for anything else.
  The classifier only ever narrows *toward* the safe default; a wrong mapping
  means an imprecise reason shown to the user, never a crash and never a
  fabricated success.
- `Kurn/Infrastructure/ModelStoreBootCoordinator.swift` is new: `@MainActor
  @Observable final class ModelStoreBootCoordinator: Sendable` walks the four
  states item 1 named. `beginBoot()` (called once from `KurnApp.init()`) and
  `retryIfNeeded()` (called on every foreground activation) both funnel
  through one `attemptOpen()` — check protected data first (no attempt at all
  if unavailable), then call the injected `makeStore` and classify any thrown
  error. `Sendable` is a real, checked conformance (not `@unchecked`): every
  stored property is either itself `Sendable` or a `@MainActor`-isolated
  function type, which the compiler treats as safely `Sendable` since calling
  it is structurally serialized through the actor.
- `Kurn/Views/ModelStoreBootViews.swift` is new: `ModelStoreLaunchProgressView`
  (shown for `.waitingForProtectedData`/`.opening`) and
  `ModelStoreRecoveryView` (shown for `.recoveryRequired`, with a per-reason
  message and a single Retry button — no destructive "start fresh" action,
  matching item 4's "not in this PR" boundary for backup/restore/salvage,
  which is PR 4). Both are deliberately store-independent: no `ModelContext`,
  no `AppSettings`.
- `Kurn/KurnApp.swift` is restructured: background-task registration
  (`TranscriptionScheduler.register`) now runs before the store is ever
  touched, satisfying item 3 directly — `TranscriptionScheduler`'s launch
  handler takes a `containerProvider` closure consulted only when a task
  actually fires, not at registration time. `boot.beginBoot()` runs at the end
  of `init()`; on the common path (protected data available, store opens
  cleanly) this resolves to `.ready` synchronously before `body` is ever
  evaluated, so behavior is unchanged from before this PR. The four
  store-dependent coordinators (`TranscriptionViewModel`,
  `PlaybackEnhancementViewModel`, `SemanticIndexCoordinator`,
  `WikiCoordinator`) plus `RecordingLauncher`/`RecordingRecovery`/
  `TranscriptionRecovery` wiring moved into `makeAppEnvironment(container:
  settings:)`, called from either the synchronous `init()` path or the
  deferred foreground-activation retry — both converge on identical behavior.
  The production `fatalError` on construction failure is gone; a failed open
  renders `ModelStoreRecoveryView` instead. `content` never renders
  `ContentView()` (and therefore never attaches `.securityCover`/
  `.modelContainer`) until `appEnvironment` exists, which is what keeps a
  failed or deferred boot from ever masquerading as a working app.
- `Kurn/DebugSupport/ModelStoreDebugInjection.swift` is new: `#if DEBUG` only,
  maps each `ModelStoreOpenFailureReason` to a real `NSError` carrying the
  classifier's exact signature. `KurnApp.makeStore()` throws one when launched
  with `UI_TESTING_STORE_OPEN_FAILURE_REASON` in the launch environment;
  `makeBootCoordinator()` similarly forces `.waitingForProtectedData` when
  launched with the `UI-Testing-StoreWaitingForProtectedData` argument. Both
  are compiled out of Release, alongside the existing `ScreenshotSeedData`
  seam.
- **Tests.** `KurnTests/ModelStoreOpenFailureClassifierTests.swift` pins the
  classifier against hand-built `NSError`s for every reason, the
  underlying-error unwrap, the depth bound, and an unrecognized/generic-Swift-
  error default. `KurnTests/ModelStoreBootCoordinatorTests.swift` drives the
  coordinator through injected `makeStore`/`isProtectedDataAvailable` seams
  (the same shape `ModelContainerBootstrapTests` already established) and
  pins the acceptance criteria directly: a locked launch never calls
  `makeStore` at all, a failure never leaves `container` non-nil, and retry
  only re-attempts from a non-`.ready` state.
  `KurnUITests/ModelStoreRecoveryUITests.swift` launches the real app with
  each synthetic failure and asserts the recovery shell appears (by
  accessibility identifier) with no real app content underneath, plus one
  locked-launch test for the waiting shell. This is the closest this session
  could get to item 5's "Release-configuration launch tests cover each
  classified failure" — it's a Debug-configuration simulator launch (same as
  `AccessibilityAuditUITests`/`ScreenshotUITests` already are in this scheme),
  not a true Release-configuration device run; that remains a release-
  checklist item, the same status H1's real-device matrix already carries.

**Deviations and known gaps, stated plainly.**

- The classifier's exact NSError code mappings (which POSIX/Cocoa/CoreData
  constant means which reason) are written from documented, long-stable
  Foundation/CoreData API names, not verified against a real device/simulator
  failure — this session has no way to trigger a genuine locked-store or
  full-disk `ModelContainer` construction failure and observe its actual
  error shape. A misclassification here is cosmetic (the wrong reason shown),
  never a crash or a fabricated store, per the classifier's fallback design —
  but the mapping itself should be checked against a real failure the first
  time one is available (e.g. during the H1 physical-device release matrix).
- Item 6 ("Make store/file protection verification part of bootstrap") is
  explicitly PR 4 scope in the megaplan's PR boundaries, not this PR's — left
  untouched here.
- No backup, restore, salvage, or "confirmed fresh start" action exists yet;
  Retry is the only recovery action, matching the megaplan's PR 3 scope
  exactly (PR 4 adds the rest).

**Observed on PR #157 (2026-08-30, commit `fcb9c7b`).** GitHub `iOS CI`:
`build-and-test` — pass (SwiftLint, `xcodebuild build`, and the full
`xcodebuild test` run, including the new `ModelStoreOpenFailureClassifierTests`,
`ModelStoreBootCoordinatorTests`, and `ModelStoreRecoveryUITests` cases);
`kurncore-linux` — pass. No unresolved review comments, no fix round needed.
Merged as `12850ae`. `xcodebuild` (Release configuration) and a true
Release-configuration device launch were not exercised — both remain the
release-checklist gap the section above already names.

**Next code PR: H2 protected backup, restore, salvage, and recovery UI**
(`docs/resilience-megaplan.md` PR 4) — preserve the store's original bytes
before a migration, offer restore/salvage/confirmed-fresh-start, and verify
protection on the store directory and sidecars during bootstrap (item 6
above). Start it from updated `main` after this PR merges.

#### H2 backup/restore/salvage/recovery-UI PR — merged (2026-08-31)

Branch `claude/plano-resiliencia-xe25b2`, on top of merged `main`
(`12850ae`), PR #158. This session has no macOS/Xcode toolchain, so nothing
here is claimed to compile or pass locally — the `iOS CI` result on the PR is
the source of truth. Several rounds of real, CI-confirmed compile errors were
found and fixed along the way (an exhaustive-switch miss, a throwing
nil-coalescing expression, a struct definite-initialization ordering bug in
`KurnApp.init()`, and a Swift Testing `#require` macro-expansion issue) —
none of that iteration is unusual for a from-scratch feature with no local
verification, and all of it is resolved.

**The CI blocker was a real, production-affecting bug in this PR's own
code, and it is now fixed.** CI repeatedly hit a crash, always the same
signature:

```
SwiftData/BackingData.swift:844: Fatal error: This model instance was
destroyed by calling ModelContext.reset and is no longer usable.
PersistentIdentifier(... <x-coredata://.../Meeting/p1>)
```

The cause was a use-after-free of SwiftData model objects in
`ModelStoreSalvage`. Its `openReadOnly` helper created a `ModelContainer`
in a **local**, fetched `[Meeting]` from that container's `mainContext`,
and returned the model objects. The container therefore deallocated the
moment the function returned — and SwiftData resets a container's
`mainContext` when the container goes away, destroying every instance
registered in it. The caller then passed those already-dead objects to
`exportMarkdown`, whose first property read (`title`/`notes`/`summaries`)
trapped the process. `Meeting/p1` in the message was simply the first row
fetched.

**This would have crashed real users**, on the recovery screen — the one
screen that exists precisely because something already went wrong — for
anyone whose store contained meetings. It was never a test-environment
artifact.

The fix (`recoverReadOnly`) does the fetch *and* the export inside the
container's lifetime and returns only value types, wrapped in
`withExtendedLifetime` so ARC cannot release the container after the fetch
but before the export reads. The rule worth carrying forward: **never let
a `@Model` instance outlive the `ModelContainer` it was fetched from.**
`ModelStoreSalvage` was the only place in the app returning fetched models
out of their container's scope.

**Four observations this explains that the earlier theories did not**, and
which are the reason the investigation took as long as it did:

| Observation | Explanation |
| --- | --- |
| Only `recoversMeetingsFromARealStoreWithoutTouchingTheLiveFiles` crashed | The only test where the fetch returns a non-empty array *and* the export then dereferences it. `returnsUnavailableWhenNoLiveStoreExists` never opens a container; `failsWithoutCrashingOnAnUnreadableStoreFile` is rejected by the SQLite header guard before any fetch. |
| The crash fired 10–70 ms after the test started | Create/insert/save is fast; the crash is in salvage immediately afterward — it only *looked* like it might precede salvage. |
| Releasing the **test's** container first changed nothing | The dangling container was the **salvage** one, inside production code. |
| `meetings.count` was fine but the export was not | `count` is `Array.count`; it never touches backing data. |

**The earlier diagnosis recorded here was wrong, and is kept as a warning.**
It attributed the crash to a known, radar-tracked SwiftData concurrency
issue (FB14089213-class: a container's async background housekeeping still
in flight when its owner deallocates). That reading was superficially
plausible — the crash signature matches, and Swift Testing runs the whole
~150-file suite in one process, unlike XCTest — but it was wrong, and
being wrong in the direction of "a framework bug, not ours" is what made it
expensive: it justified four rounds of test-infrastructure work instead of
one careful read of the failing code path. A crash that is fully
reproducible in isolation is a deterministic bug, not a race, and should
have been read that way much sooner.

An earlier occurrence *was* separately fixed and remains fixed:
`ModelStoreSalvage.attempt` handed a copy of a possibly-unreadable store
file straight to `ModelContainer` without checking it was SQLite first. The
16-byte magic-header pre-check stays as cheap input validation, but note it
was **not** the fix for the crash above — an earlier revision of this
document and of the code's own comments claimed otherwise.

Four mitigations were tried before the root cause was found. None of them
fixed it (nothing test-level could have), but two are worth keeping:

- **Suite nesting** (kept): `ModelStoreBootCoordinatorTests` and
  `ModelStoreSalvageTests` are both nested under a new, purely-organizational
  `SwiftDataConcurrencySensitiveTests` suite (since moved to
  `KurnSwiftDataTests/`, see below) carrying
  `@Suite(.serialized)`. Swift Testing documents that `.serialized` is
  inherited recursively by nested suites (unlike two independent top-level
  `@Suite(.serialized)` types, which still run concurrently *with each
  other* — confirmed the hard way, via a crash that hit right as both
  independently-serialized suites started at the same instant). The nesting
  fix is confirmed working in CI logs (the two suites now run strictly
  sequentially), but — as expected given the whole-suite scope of the real
  issue — did not eliminate the crash on its own.
- **Xcode Test Plan with `KurnTests` marked non-parallelizable** (tried,
  reverted): the Apple-documented structural mechanism for scoping down test
  parallelization. It resolved and ran cleanly (so the structural change
  itself was safe), but did not stop the crash either — it recurred at the
  exact same spot on the next run. Kept as unproven, permanent structural
  complexity (a new project-artifact type, a scheme resolution-mode change)
  is worse than the status quo when it demonstrably doesn't fix the problem
  it was added for, so it was reverted rather than left in place.
- **A separate `KurnSwiftDataTests` test target** (tried): after multiple
  runs kept marking unrelated files (`AudioChunkerTests`,
  `PlaybackEnhancementTests`, and others) as "failing" purely because
  xcodebuild's crash-restart only re-runs a small subset of the tests that
  were mid-flight — verified directly in CI logs (zero explicit
  `recorded an issue`/assertion failures anywhere; every "failing" test had
  `started` but never `passed`/`failed` before the crash, and the retry
  after restart only covered ~5 of the dozens interrupted) — two other
  documented xcodebuild levers were researched and ruled out first:
  `-retry-tests-on-failure` deliberately excludes crashes ("to ensure app
  crash errors are surfaced without confusion"), and `-only-testing`/
  `-skip-testing` have documented Swift Testing compatibility gaps (a
  suite-level identifier can silently select zero tests rather than fail
  loud). A genuinely separate Xcode *target* (not a suite filter) sidesteps
  both: each test target gets its own host-app process launch even when
  sharing the same `TEST_HOST`, which is well-documented xcodebuild
  behavior, not suite-level filtering with known gaps. `ModelStoreBootCoordinatorTests`,
  `ModelStoreSalvageTests` and the `SwiftDataConcurrencySensitiveTests`
  parent moved from `KurnTests/` to a new `KurnSwiftDataTests/` folder and
  target (`project.pbxproj`, mirroring `KurnTests`' existing target
  structure; the scheme lists it last in both `BuildAction` and
  `TestAction`). If this target's process still crashes on some runs, the
  damage is now contained to its own ~2 files instead of taking unrelated
  ones down as collateral, and the rest of the ~150-file suite keeps
  reporting real results regardless.

**The isolation is what made the root cause findable.** Once
`KurnSwiftDataTests` ran as its own process, `KurnTests` (~150 files) and
`KurnUITests` both passed cleanly and completely — no collateral damage,
exactly as intended — and the failure list collapsed to exactly one
honest entry instead of ~25 false ones. That single reproducible failure,
in isolation, is what finally made the bug legible as deterministic. The
target is worth keeping for that property alone, independent of this
crash.

The intermediate hypothesis (that the *test* held two `ModelContainer`s
over overlapping files at once, and that scoping the first would help) was
disproved by CI: the crash recurred at the identical point twice in a row.
That negative result was the useful signal that the dangling container was
in production code, not the test.

**Current status: green.** CI run 608 on `1ef02af` passed end to end —
`build-and-test` and `kurncore-linux` both green, `** TEST SUCCEEDED **`,
with `SalvageTests` explicitly passing:

```
✔ Test recoversMeetingsFromARealStoreWithoutTouchingTheLiveFiles() passed after 0.649 seconds.
✔ Suite SalvageTests passed after 0.653 seconds.
✔ Test run with 13 tests in 3 suites passed after 1.348 seconds.
```

plus `KurnUITests` 12/12. [PR #158](https://github.com/carlosmazzei/Kurn/pull/158)
merged into `main` on that basis (recorded in commit `e46ded2`).

**Landed in the working tree.**

- `Kurn/Infrastructure/ModelStoreBackupManager.swift` is new: copies the live
  store + WAL/SHM into a protected, timestamped generation folder before
  every open attempt (rate-limited to once per app version+build — an
  ordinary launch no longer re-copies the whole store), retains the newest 3
  generations, and can restore a chosen generation or quarantine the live
  store (move, never delete) for a confirmed fresh start. Every mutating
  operation is additive-safe by construction: the only deletion anywhere in
  the type is pruning a redundant backup copy.
- `Kurn/Infrastructure/ModelStoreSalvage.swift` is new: copies the live store
  aside and attempts a **read-only** (`allowsSave: false`) open of the copy —
  first with the production schema/migration plan, then with a bare
  unversioned schema — recovering meetings as Markdown when either succeeds.
  Never touches the live files; best-effort by design (see the megaplan's
  PR 4 scope note on what salvage cannot recover).
- `Kurn/Infrastructure/ModelStoreProtection.swift` gained `applyAndVerify`,
  the throwing counterpart to `apply` — item 6 ("make store/file protection
  verification part of bootstrap"). `ModelStoreBootCoordinator.attemptOpen()`
  now calls the backup before `makeStore()` (best-effort; a backup failure
  never blocks opening) and `applyAndVerify` after a successful open,
  discarding the container and routing to the new
  `.protectionVerificationFailed` `ModelStoreOpenFailureReason` if
  verification fails.
- `Kurn/ViewModels/ModelStoreRecoveryViewModel.swift` is new and
  `Kurn/Views/ModelStoreBootViews.swift`'s `ModelStoreRecoveryView` is
  expanded: restore-from-backup (a list of generations, each
  double-confirmed via `kurnDialog`), attempt-salvage (with a Share sheet for
  the recovered Markdown), export-diagnostics (a content-free report:
  classified reason + backup generation list, reusing `MeetingExport`'s
  temp-file/`ActivityView` share pattern), and a double-confirmed
  confirmed-fresh-start. All four join the existing Retry action; none is
  automatic.
- **Tests.** `KurnTests/ModelStoreBackupManagerTests.swift` exercises backup,
  rate-limiting, pruning, restore and quarantine against a real temporary
  directory with synthetic store files. `ModelStoreSalvageTests.swift`
  proves salvage recovers a real `Meeting` from a real store copy without
  touching the live container, and fails without crashing on an unreadable
  file. `ModelStoreBootCoordinatorTests.swift` gained coverage for
  the new backup-before-open and verify-after-open wiring — and every
  existing PR 3 test now passes an explicit temporary `appSupportDirectory`,
  since PR 4 added real filesystem I/O to `attemptOpen()` that would
  otherwise touch the test runner's actual on-disk state. Both, plus the
  `SwiftDataConcurrencySensitiveTests` parent suite, now live in their own
  `KurnSwiftDataTests/` target rather than `KurnTests/` — see the CI
  investigation above for why.
  `KurnUITests/ModelStoreRecoveryUITests.swift` gained a test that the new
  action buttons render and that salvage resolves without crashing when
  launched against a synthetic failure with no real store on disk.
- Localization: 12 new `store_recovery.*` keys (backup/restore/salvage/
  diagnostics/fresh-start copy) added to all seven `Localizable.strings`
  files.

**Known gaps, stated plainly.**

- Salvage's two strategies recover data for transient/environmental failures
  and migration-plan bookkeeping issues, not for a genuinely corrupt SQLite
  file or a real un-migratable schema mismatch — those fail salvage exactly
  as they failed the live open. This is inherent to what salvage can mean
  without a corpus of real corrupt stores to test repair heuristics against.
- The confirmation dialogs use the shared `kurnDialog` component, which has
  no per-call accessibility identifiers; the UI test suite verifies the
  actions render and that salvage resolves, not the full confirm/cancel
  interaction — that path is proven at the `ModelStoreBackupManager`/
  `ModelStoreRecoveryViewModel` level instead.
- "N-1/N-2 fixtures preserve relationships and recovery state" is satisfied
  the same way PR 2 satisfied it: this is still the app's first-ever
  versioned schema, so there is no earlier released layout to fabricate.

**Observed.** PR #158 (`iOS CI`) has run repeatedly: SwiftLint and the build
compile cleanly, and the simulator test suite (including the new UI tests)
passes on the runs that don't hit the CI test-infrastructure crash described
above. `xcodebuild` Release configuration and `swift test` in
`Packages/KurnCore` have not specifically been re-verified after the fixes
in this handoff, but neither is implicated by anything changed here.

**Next code work: H3 · Atomic model/file mutations and non-destructive
reconciliation** — the operation journal, protected trash/quarantine for
deletes, and typed authoritative JSON corruption. Start it from updated
`main` after this PR merges.

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

**Progress.** Split into narrowly-scoped PRs rather than landed as one large
change, the same way H2 split into four:

- **PR 1 (item 2, deletion trash-then-purge) — done, merged in
  [PR #159](https://github.com/carlosmazzei/Kurn/pull/159).** `RecordingTrash`
  moves every file aside before the model mutation and purges only once it
  commits, with launch/foreground reconciliation for an interrupted delete.
- **PR 2 (item 6, typed JSON corruption) — done, merged in
  [PR #160](https://github.com/carlosmazzei/Kurn/pull/160).** Scoped to exactly the two properties
  the risk register itself names — `Transcript.segments` and
  `Summary.sections` — not every `JSONStorage` consumer; see the handoff
  below for why and what stays on the lenient contract. `Recording.
  transcriptionCheckpoint` is deliberately excluded too: its decode already
  degrades safely (a failed decode means "no checkpoint, restart the chunk
  plan", never wrong-but-successful content), so it doesn't share the
  transcript/summary failure mode this item exists to close.
- **PR 3 (items 3, 4, 5 — quarantine, collision handling, fail-closed
  writers) — done, merged in
  [PR #162](https://github.com/carlosmazzei/Kurn/pull/162) (`fd4b417`).**
  `AudioFileStore.recordingsDirectoryURL` is a pure computed path; writers go
  through throwing `ensureRecordingsDirectory()`/`ensureEnhancedDirectory()`
  that surface `AppError.protectedStorageUnavailable` instead of falling back
  to an unverified location. `RecordingQuarantine` preserves every original
  the recovery sweep cannot place (unparsable name, missing meeting,
  unreadable container, negligible duration) plus ambiguous legacy-migration
  collisions, under `Recordings/Quarantine/<uuid>/` with a size/date/reason
  sidecar; Storage Settings exposes recover/export/confirmed-delete. Item 7's
  core property — derived enhanced copies stay separately disposable and are
  never quarantined — holds by construction. A fault during quarantine leaves
  the original in place; a missing sidecar degrades the listing, never drops
  the audio.
- **PR 6 (item 1, the durable operation journal) — done, merged into `main`
  as commit `d7e3dee`.** `RecordingOperationJournal` records durable
  delete/replace intent before any file moves, replays or rolls back
  unfinished operations from their own recorded state at launch/foreground
  (ahead of the heuristic trash sweep, which remains only for pre-journal
  leftovers), journals compaction's in-place swap, and makes "Delete All
  Data" report residual audio files instead of implying a clean wipe.
- **PR 7 (the remainder of item 6, versioned authoritative envelopes) —
  done, merged into `main` as commit `e7a156a`.**
  `Recording.transcriptionCheckpoint` now writes
  `JSONStorage.encodeAuthoritative` envelopes (an encode failure keeps the
  previous resumable point), reads distinguish `.corrupted` from `.empty`
  via `transcriptionCheckpointOutcome` — legacy bare payloads still decode,
  corrupted bytes are preserved rather than blanked — and both the
  transcribe path and `TranscriptionRecovery`'s stale sweep treat a
  corrupted checkpoint as an explicit non-resumable state instead of "never
  checkpointed". Operation reports do not exist yet (H5); they adopt the
  envelope when introduced.
- **Item 7's separate derived-copy reconciliation — still open.** Derived
  enhanced copies stay separately disposable and are never quarantined (that
  much holds by construction, per PR 3), but they have no reconciliation pass
  of their own.

#### H3 PR 2 handoff: typed JSON corruption for transcript/summary

`JSONStorage.encode`/`decode` had one failure contract for everything they
touch: a decode failure returns `[]`/`nil`, identical to a property that was
simply never written. For `Recording.highlights`/`speakerVoiceprints`, a
resumable `transcriptionCheckpoint`, or a `SmartFolder`'s saved-search
predicate, that's an acceptable, even correct, degrade — the content is
regenerable or the failure mode is already safe (see above). For
`Transcript.segments` and `Summary.sections` it is the exact bug the risk
register names: corrupted bytes on disk render as a legitimately empty
transcript, with nothing to tell a user or the code apart the two.

`encodeAuthoritative`/`decodeAuthoritative` (`JSONStorage.swift`) add a
second contract for exactly that content. Encoding wraps the payload in a
versioned envelope carrying an FNV-1a checksum of the payload bytes — chosen
over Swift's `Hasher`, which is deliberately randomized per process launch
and so cannot verify anything written by an earlier launch — and returns
`nil` on an encode failure (chiefly a NaN/infinite floating-point field,
which `JSONEncoder` cannot represent; a pipeline confidence score or
timestamp could in principle produce one) instead of the old `?? Data()`.
Decoding returns a `JSONDecodeOutcome<T>` — `.empty` for zero stored bytes,
`.value` for a successful envelope-and-checksum decode, `.corrupted` (still
carrying the original bytes, for a future recovery/diagnostic path) for
anything else — and, critically, still accepts a successful decode of the
*old*, un-enveloped format as `.value`: every row on a real device predates
this format, and without that fallback every one of them would appear
corrupted the moment this shipped. Only a payload that fails *both* reads is
`.corrupted`.

`Transcript.segments`/`Summary.sections` keep their existing `[T]` getter
signature (falling back to `[]` for both `.empty` and `.corrupted`, same as
before) so no other call site in the app has to change; a sibling
`isSegmentsDataCorrupted`/`isSectionsDataCorrupted` is the typed signal a
caller checks instead. `MeetingDetailView`'s transcript tab is the one
surfaced consumer: a per-recording banner (mirroring the existing
diarization-fallback banner, since a multi-recording meeting can have one
corrupted transcript alongside other good ones that would otherwise never
let the all-empty placeholder run at all) plus a dedicated branch in that
placeholder for the all-corrupted case, both ahead of the existing
"failed"/"no speech"/"never attempted" branches since corruption is the more
specific, more actionable diagnosis. `Summary` gets the same backend fix and
`isSectionsDataCorrupted` signal but no new UI in this PR — the risk
register names the transcript case specifically, and a summary-tab banner is
a small, natural follow-up rather than something this PR's scope requires.

The plan's "encoding must fail the operation rather than persist `Data()`"
half is handled at the two real call sites, both in
`TranscriptionViewModel.swift`: `saveTranscript` and the summary-generation
step each pre-check `encodeAuthoritative` *before* touching the existing
transcript/summary, so a pipeline run that produced unencodable content
can't destroy still-valid prior content on its way to failing to save the
new one, and each throws `AppError.persistenceFailed` into their existing
`catch let appError as AppError` clause — reusing the exact handling every
other pipeline failure already gets (mark `.failed`, persist, surface the
error) rather than adding a new path.

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

**Progress.** Split into PRs the same way H2 and H3 were:

- **PR 8 (items 1–2, pipeline fingerprint and checkpoint validation) — done,
  merged in [PR #165](https://github.com/carlosmazzei/Kurn/pull/165)
  (`08a0192`).** `TranscriptionPipelineFingerprint`
  (`Models/TranscriptionPipelineFingerprint.swift`) replaces the old
  engine/language/compacted/provider-only match with source file size,
  rounded duration, a SHA-256 digest of the *original* recording's bytes
  (`Infrastructure/PipelineDigest.swift`, streamed via `FileHandle` so hashing
  a multi-hour file never holds it fully in memory), the effective
  preprocessing and VAD engine, language, ASR engine and exact
  provider/model, whether VAD-compaction ran, and a digest of the compaction
  map itself — not just "compaction ran". `TranscriptionCheckpoint` now holds
  this `fingerprint` plus its own `chunkPlanDigest` (a digest of the exact
  chunk-plan offsets, checked separately by `ChunkedTranscriptionRunner`
  once chunking has actually produced a plan — the fingerprint itself can't
  contain it, since it's built before chunking runs). `isStructurallyValid`
  is the item-2 validation: `completedChunks` in bounds, and every span
  finite, non-negative, and within the original recording's duration (with a
  generous slack — this exists to catch gross corruption, not to
  re-derive the compacted timeline exactly). Both checks gate every resume
  attempt in `TranscriptionService.transcribeGated` and are also applied in
  `TranscriptionRecovery`'s launch/foreground sweep, so a checkpoint that is
  well-formed JSON but structurally nonsensical is treated the same as a
  decode failure (manual retry), not silently trusted.
- **A fingerprint with no verified source digest never matches anything —
  including another equally unverified one.** `TranscriptionPipelineFingerprint.==`
  requires both sides to carry a non-nil digest before comparing anything
  else; an unreadable file, a zero-byte read, or a non-finite duration
  produces a `nil` digest, and `nil != nil` here by design. This is the
  concrete shape of "restart safely rather than trust incompletely
  identified work" — an unverifiable source can never accidentally be
  treated as identical to a previous unverifiable source just because both
  happened to fail validation the same way.
- **Deliberate, one-time compatibility break, stated plainly.** A checkpoint
  written by any version of the app before this PR used a flat JSON shape
  (`engineRaw`/`languageRaw`/`compacted`/`totalChunks`/... at the top level).
  `TranscriptionCheckpoint`'s Codable shape changed to nest most of that
  under `fingerprint` and add `chunkPlanDigest`, so an old bare checkpoint
  payload fails to decode under the new type — exactly the same as bit-level
  corruption, and handled by the exact same path `JSONStorage.decodeAuthoritative`
  already has for that (H3 PR 2): `.corrupted`, bytes preserved, recording
  marked `.failed` for manual retry. The audio file itself is never touched
  by this — a manual retry re-transcribes from scratch, it does not lose the
  recording. This only affects a device that had a transcription genuinely
  in flight (chunked Whisper/whisper.cpp, mid-run) at the exact moment it
  updated across this change; a completed or not-yet-started transcription
  carries no checkpoint to break.
- **PR 9 (items 1, 2, 4 of the plan — throwing chunk commits and bounded
  automatic recovery) — done, merged in
  [PR #166](https://github.com/carlosmazzei/Kurn/pull/166) (`4efe374`).** `ChunkedTranscriptionRunner.run`'s
  `onChunkCompleted` is now `async throws` and **awaited** before the loop
  advances to the next chunk, rather than fired-and-forgotten; a thrown error
  propagates out of `run` and stops the loop with whatever was last durably
  committed, satisfying "do not start chunk N+1 until N is durably
  committed" directly. `TranscriptionService.CheckpointHandler` and the
  `checkpointSink` built in `transcribeGated` follow the same shape.
  `TranscriptionViewModel`'s `onCheckpoint` closure no longer goes through
  the fire-and-forget `AsyncStream`/`continuation.yield` it shared with
  phase/warning updates — it calls the new `storeCheckpointDurably`
  directly, which performs `recording.transcriptionCheckpoint = checkpoint`
  and `modelContext.save()` inline, throwing `AppError.persistenceFailed` on
  a save failure. Because this is now synchronously awaited by the pipeline,
  a save failure is caught by the same `catch let appError as AppError`
  block that already handles every other pipeline failure — the recording is
  marked `.failed` (checkpoint intact) instead of the pipeline silently
  continuing past a chunk that was never actually made durable. Removing the
  `AsyncStream` path for checkpoints also removes a subtlety rather than
  adding one: by the time `transcribe` returns, every checkpoint save has
  already completed, so there is no "enqueued but not yet applied" state
  left to race against `saveTranscript` clearing the checkpoint on success.
- **Bounded automatic recovery (item 4).** `Recording.automaticResumeAttempts`
  (defaulted, no migration needed) counts consecutive *automatic* (unattended)
  resume attempts that made no forward progress. `TranscriptionViewModel
  .resumePendingTranscriptions` — the single choke point for both the
  foreground-activation and `BGProcessingTask` resume paths — gates every
  row through `admitAutomaticResume`: under
  `TranscriptionViewModel.maxAutomaticResumeAttemptsWithoutProgress` (3), the
  counter increments (durably, before the risky work runs, so a crash
  mid-attempt still counts against it) and the resume proceeds; at the
  limit, the row is marked `.failed` instead — checkpoint intact, so a
  manual retry still resumes from the last completed chunk — closing
  "foreground activation must not create an endless retry loop or repeated
  paid request" without inventing a new status. `storeCheckpointDurably`
  resets the counter the first time an attempt saves a chunk beyond
  `completedChunksAtAttemptStart` (a baseline captured once when the attempt
  begins, not "whatever's currently stored" — see the code comment for why a
  fingerprint-mismatch restart's own first chunk must still count as
  progress even though its `completedChunks` is numerically lower than an
  abandoned prior run's). Every manual entry point
  (`MeetingDetailActions.startTranscription`, `TranscriptionViewModel
  .retranscribeAll`) calls the new `resetAutomaticResumeBudget` first, so a
  deliberate user action always gets a fresh budget — the "eventually
  requires user action" half of the plan. The bound itself is exposed as a
  pure, testable static function (`canAttemptAutomaticResume`), the same
  pattern `isResumableCancellation` already established.
- **Split out to stay under SwiftLint's file-length limit.** The new
  checkpoint/budget methods live in the new
  `TranscriptionViewModel+ResumeBudget.swift`, the same reason
  `TranscriptionViewModel+CrossMeetingSpeakerMatch.swift` exists; `PR 8` had
  already left the main file one PR away from the 900-line error threshold.
- **Item 3 (the full explicit operation-state enum — queued/running/
  paused-by-user/deferred-by-system/retry-scheduled/permanent-failure/
  completed, with reason codes, attempt count, and `nextAttemptAt`) — not
  started.** This PR's acceptance criteria (checkpoint save failure stops
  the run; process death loses at most the in-flight chunk; foreground
  activation cannot loop or re-pay endlessly) are met on top of the existing
  `TranscriptionStatus` enum plus the new attempt counter, which is simpler
  than the richer state model the plan describes but sufficient for what H4
  actually requires today. A future session should revisit item 3 only if a
  concrete need for the richer states (e.g. a visible "retrying in 2
  minutes" UI) shows up — this PR does not attempt it speculatively.
- **PR 10 (item 6, the same durable multi-step pattern applied to summary and
  wiki generation) — done, merged into `main` as
  [PR #167](https://github.com/carlosmazzei/Kurn/pull/167) (`663ab09`).**
  `SummaryMapCheckpoint`
  (`Models/SummaryMapCheckpoint.swift`) records a staged (map-reduce) summary
  or wiki run's map-stage progress: a SHA-256 digest of the transcript text
  fed to the map stage, the provider id and exact model, the plan's block
  count, and the notes condensed so far. `matches(...)` is the exact-identity
  resume check (content + provider + model + block count, mirroring the
  quality-mixing protection `TranscriptionPipelineFingerprint` already gives
  transcription checkpoints) and `isStructurallyValid` is the same
  "completed work can never exceed the plan" sanity check
  `TranscriptionCheckpoint.isStructurallyValid` already has for chunk counts.
  `SummaryMapRunner` (`Services/SummaryMapRunner.swift`) is the block loop,
  built the same way as `ChunkedTranscriptionRunner`: independent of
  `LLMProvider` so the resume/skip logic is unit-testable without a network
  mock. It resumes from `resume.completedNotes` only when the checkpoint is
  structurally valid and its identity matches the plan about to run, then for
  every new block `try await`s `onStageCompleted` with the updated checkpoint
  before moving to the next block — the exact "not durable until this
  returns" contract PR 9 established for `ChunkedTranscriptionRunner
  .run`'s `onChunkCompleted`, so a checkpoint-save failure stops the run at
  the last committed block instead of risking the next block's cost on top
  of unsaved progress.
- **One checkpoint field on `Meeting`, shared by Summary and Wiki, not one
  per artifact.** `Meeting.summaryMapCheckpointData` persists the same way
  `Recording.transcriptionCheckpointData` does — JSON `Data` behind
  `JSONStorage.encodeAuthoritative`/`decodeAuthoritative`, with the same
  corrupted-vs-empty distinction via `summaryMapCheckpointOutcome`. It is
  shared because `WikiService.generate` delegates its map stage to
  `SummaryService.generate`'s own `notesTemplate` regardless of caller, so
  for a given meeting's content, Summary and Wiki generation produce
  byte-identical map-stage notes. A Summary run and a Wiki run racing on the
  same meeting can therefore share or briefly overwrite each other's
  progress with no correctness risk — worst case, one already-completed
  block is redone, never spliced or incorrect notes — since both run on the
  same `@MainActor` context that already serializes `modelContext.save()`.
  `TranscriptionViewModel.generateSummary` (moved into the new
  `ViewModels/TranscriptionViewModel+Summary.swift` to keep
  `TranscriptionViewModel.swift` under SwiftLint's file-length limit, the
  same reason `TranscriptionViewModel+ResumeBudget.swift` exists) and
  `WikiCoordinator.generate` both read the checkpoint as a resume seed
  (only if `isStructurallyValid`), pass a `storeSummaryMapCheckpointDurably`
  closure through as `onMapStageCompleted`, and clear the checkpoint once the
  full run — map and reduce — succeeds. Both `storeSummaryMapCheckpointDurably`
  implementations key on the meeting's `UUID` rather than the `Meeting`
  itself and re-fetch it via `FetchDescriptor`, because `Meeting` is a
  SwiftData `@Model` (not `Sendable`) and the closure is the `@Sendable`
  `onMapStageCompleted` parameter — the same pattern
  `TranscriptionViewModel+ResumeBudget.swift`'s `activeRecordings` lookup and
  `RecordingRecovery.swift` already use for a cross-closure model lookup.
- **Deliberately excluded: `DocumentGenerationService`.** A `GeneratedDocument`
  can synthesize from multiple meetings' transcripts in one map-reduce run,
  so there is no single `Meeting` to persist a checkpoint against — the same
  reason `GeneratedDocument` already snapshots its sources rather than
  relating to them. Left out of scope rather than inventing a second,
  document-scoped checkpoint location speculatively; a future session should
  revisit only if a concrete need for document-generation resumability shows
  up.
- **"Partial prose or JSON is never displayed as final" was already true
  before this PR.** `TranscriptionViewModel.generateSummary` only inserts a
  `Summary` row after `SummaryService.generate` fully succeeds, and
  `WikiCoordinator.replaceArticle` is only called after `WikiService.generate`
  returns non-empty markdown — confirmed by reading both call sites, no
  change needed for that half of the PR 10 acceptance criteria.
- **Item 3 remains not started**, per PR 9's own handoff above — this PR
  does not revisit it. With PR 10 landed, H4's plan is fully addressed except
  item 3.

### H5 · Typed degradation and output-integrity gates — P1, done

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

**Progress — items 1–3 (the PR 11 boundary), merged into `main` as
[PR #168](https://github.com/carlosmazzei/Kurn/pull/168) (commit
`d9f5120`).** `PipelineReport`
and friends live in KurnCore, carrying only closed vocabularies and engine
`rawValue`s — no free-text field, so a provider message or file name cannot
reach a persisted, exportable report. `TranscriptionService` records one entry
per stage (preprocessing's fall back to the original audio, a detector
returning the caller's hint rather than a detection, compaction declining
versus failing, an empty transcription over detected speech, diarization
stepping down for missing model consent versus falling back to a synthetic
whole-clip turn, fusion losing every span, and correction's typed
`TranscriptCorrectionResult`), and `Transcript.pipelineReportData` persists the
aggregate in the same save as the segments — `nil` meaning *unknown*, never
*clean*. Cancellation is untouched: it still throws out of the pipeline and is
never recorded as an outcome. Item 3's UI half ("completed with warnings" plus
stage-specific re-run actions) is deliberately left to PR 13. See the
megaplan's "PR 11" section for the file-level detail.

**Progress — items 4–5 (the PR 12 boundary), merged into `main` as
[PR #169](https://github.com/carlosmazzei/Kurn/pull/169) (commit
`e3c1c54`).** `TranscriptIntegrityGate`
(KurnCore, pure and Linux-buildable) validates a run's fused, corrected
`[TranscriptSegment]` before `TranscriptionService.transcribe` returns it:
source duration finite/non-negative, fusion not having lost every span the
engine produced, every span's timestamps finite/ordered/within bounds (the
same 30s-slack tolerance `TranscriptionCheckpoint.isStructurallyValid` already
uses), and every segment carrying non-blank text and a non-blank speaker
label. It also verifies a `TranscriptCorrecting` conformer's output preserved
segment identity (same count, ids, order, and every field but `.text`) before
`TranscriptionServiceCorrection.correctIfRequested` trusts it — a violation
degrades the run (new `PipelineStageReason.correctionContractViolated`) and
falls back to the pre-correction segments instead of being trusted. A gate
failure throws `AppError.transcriptIntegrityFailed` instead of returning
`Output`, which is what makes item 5 ("keep the previous transcript... until
the replacement is valid and durable") true with no new plumbing:
`TranscriptionViewModel.saveTranscript` — the only place an existing
`Transcript` is deleted — is only ever reached after `transcribe` has already
returned successfully, so a thrown gate failure leaves it untouched and the
recording is marked `.failed` with its checkpoint intact, the same as any
other pipeline failure. Summary and semantic-index replacement already
satisfied their half of item 5 before this PR (new content is built/validated
before old rows are ever deleted) and needed no change. See the megaplan's
"PR 12" section for the full detail and known gaps.

**Progress — item 3's UI half (the PR 13 boundary), implemented on branch
`claude/resilience-roadmap-plan-fn23ki`.** `MeetingDetailView`'s Transcript
tab now shows a "completed with warnings" banner (`pipelineWarningsBanner`)
driven by the transcript's stored `PipelineReport`, naming every warned
stage via a new `PipelineStage.displayName`. Correction is the only stage
cheap enough to retry without repeating audio preprocessing, ASR, or
diarization — `TranscriptCorrecting.correct` needs nothing but the segments
and language it's given — so `TranscriptionViewModel.retryCorrection`
re-runs just that stage over the stored transcript and replaces only its
entry in the persisted report; every other warning falls back to the
existing full re-transcribe confirmation, since nothing else can be re-run
in isolation without new durable intermediate state this PR deliberately
doesn't add. The retry inherits PR 12's fail-closed guarantee: since
`correctIfRequested` already enforces identity preservation, the retry's
`TranscriptIntegrityGate.validate` call only needs a bound derived from the
original segments' own timeline, not a re-read of the source audio, and a
stale-write guard discards the retry's result rather than clobbering a
transcript that was fully re-transcribed while the retry was in flight. "Integrate with H9" is satisfied by *not* inventing a second warning-presentation system — the banner reuses the existing `diarizationWarningBanner`
pattern — since H9's own action-metadata/recovery-UI model doesn't exist yet
to integrate with. See the megaplan's "PR 13" section for the full detail
and known gaps (no end-to-end test of the retry path or the banner; a single
combined warning sentence rather than a per-stage reason, to bound
translation cost).

### H6 · Exact network boundaries, bounded retry, and cost control — Core implemented (P0/P1)

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
7. **Implemented (2026-08-30).** A content-free per-provider circuit persists in
   `UserDefaults`. Automatic title, wiki, and foreground backfill consult it;
   configuration failures require an explicit probe, ambiguous results stay blocked,
   and repeated transient failures back off from five minutes to one day across app
   activations. User-triggered wiki rebuild bypasses the gate, stops on first failure,
   replaces each article only after its successor is ready, and clears provider state
   only after success.
8. **Implemented with a documented library boundary (2026-08-30).** Large
   transfers default to unrestricted Wi-Fi; Settings separately opts into
   expensive/cellular and constrained/Low Data Mode access. App-owned Whisper,
   whisper.cpp, and sherpa-onnx sessions use native URLSession policy across path
   changes and map native policy rejection to a typed error. FluidAudio
   does not expose its session, so downloads fail a current-path preflight; a path
   change after start remains visible in the risk register. First cloud use is
   consented per provider+URL with provider, hostname, and hourly audio estimate;
   model dialogs disclose Hugging Face and approximate or variant-specific size.
9. **Deferred evaluation, not a core resilience blocker.** Streaming may improve
   perceived progress only after measured latency/memory evidence; partial prose/
   JSON is never final output and must not weaken the atomic commit rules above.

**Core done (2026-08-30).** No malformed custom URL produces a request to a default vendor;
redirect tests prove credentials/content stay on the approved origin; 401/403
fail without retry, 429 honors the server, transient 5xx/transport retries stay
inside one logical operation, cancellation stops waits/transfers, and automated
paid jobs cannot hammer a broken provider on every activation. Waiting-state UX
continues under H9; the FluidAudio library boundary remains in the risk register.

**Verification evidence.** Provider URL/transport/rate-limit suites cover malformed
and relative URLs, redirects, response caps, lost responses, cancellation, stable
request identity and network-cost flags; dedicated suites cover cooldown persistence,
consent destination changes, background relaunch handlers and model preflight. Real-
device path transitions and the FluidAudio mid-transfer boundary remain checklist work.

### H7 · Credential and model integrity — P1, items 1–2, 3, 5–7 done; item 4 half-closed

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

**Progress — items 1–2 (the PR 14 boundary), implemented on branch
`claude/resilience-roadmap-plan-fn23ki`.** `KeychainAccessing`
(`Kurn/Infrastructure/KeychainManager.swift`, mirroring `CloudSettingsSync`'s
`CloudKeyValueStore` seam) replaces the old API, which collapsed every
Security-framework failure into the same value "not configured" produced —
`get` returned `nil` for a locked device exactly as for a key never stored,
and `set`/`delete` discarded their `OSStatus` outright. `KeychainReadOutcome`
(`.found`/`.absent`/`.failed`) and `KeychainWriteOutcome`
(`.success`/`.failed`) now carry a `KeychainFailureReason`
(`.locked`/`.denied`/`.transient`) instead — `KeychainManager.classify(_:)`
is the one place the raw `OSStatus` is read, and it never leaves that
function. `migrateToBackgroundAccessible()` — the exact mechanism the old
ambiguity broke — now only sets its `UserDefaults` completion flag after a
confirmed outcome (`errSecItemNotFound`, or every item's re-save reporting
`.success`); any other fetch status or one item's failed re-save leaves the
flag unset so the next launch retries, closing item 1's "mark the
accessibility migration complete only after all items were migrated or
absence was confirmed" exactly. Item 2: `ProviderEditor`'s API-key field no
longer writes to the Keychain on every keystroke (`.onChange(of: key)` is
gone) — it's buffered in `@State` like every other field and committed only
from the toolbar Save action, which was already gated on
`LLMHTTP.isValidBaseURL` via `canSave`, satisfying "validate the provider URL
first" for free. A failed Keychain write surfaces
`AppError.keychainAccessFailed` and leaves the sheet open instead of
dismissing, so a retry doesn't lose the user's other edits. The optional
half of item 2 ("then optionally test a minimal endpoint") was not
attempted — it's explicitly optional in the plan text and out of scope for
this boundary. See the megaplan's "PR 14" section for the full contract,
the `FakeKeychainAccessing`-backed test coverage, and known gaps (no
locked-device migration test — same simulator limitation H1's physical
matrix already has; no end-to-end UI test of the Save-flow failure path,
since `ProviderEditor` isn't behind an injected `KeychainAccessing` — the
same known-gap shape H5 PR 12/13 each stated for their own view-model glue).
Items 3–7 (model download consolidation, pinned/verified revisions, atomic
staging, storage-inventory verification, owned download tasks) are PR
15/16's scope.

**Progress — items 3, 5, 7 (the PR 15 boundary) and half of item 4, merged
as [PR #172](https://github.com/carlosmazzei/Kurn/pull/172) (commit
`d66c10f`).**
`ModelDownloading` (`Kurn/Services/ModelFileDownloader.swift`, new protocol)
replaces the bare enum of static functions `WhisperCppModelDownloader` and
`SherpaOnnxModelDownloader` used to call directly — `ModelFileDownloader` is
now an `actor` conforming to it, injectable via `init(protocolClasses:)` for
tests, holding resume data per destination between attempts. Item 3's
"retry, cancellation, resume data, ... atomic staging directory" landed:
a completed download stages under a `kurn_model_` prefix in the temporary
directory (now swept by `TempFileCleaner` like every other pipeline temp
file), `ModelDownloadController.cancelDownload()` cancels the stored
`activeDownloadTask` and `ModelDownloadProgressRow` gained a Cancel button
wired into all three progress rows, and resume data captured from either a
user cancellation or a dropped connection is reused on the next `fetch` for
that destination. ("Retry" here is manual — re-triggering the same consent
flow continues rather than auto-retrying with backoff; see known gaps.)
Item 5's "validating the staged model, atomically replacing the
destination" landed: `verify(_:minimumPlausibleBytes:)` checks the exact
declared `Content-Length` (and an opportunistic SHA-256 — see item 4 below)
before `install(_:at:expectedHashHex:)` uses
`FileManager.replaceItemAt(_:withItemAt:backupItemName:)` to swap the file
in, re-hashes the *installed* copy when a hash was checked, and restores
the kept backup rather than deleting it on a mismatch — a failure at any
point now always leaves the previous valid model exactly as it was.
"Loading a small health probe" and "corruption offers re-download instead
of failing every transcription" — deferred here, and closed by PR 16 below.
Item 4 ("pin immutable model revisions and verify a published exact size
plus SHA-256") is **half-closed**: exact-size verification against the
server's declared length, and opportunistic SHA-256 verification via
HuggingFace's `X-Linked-ETag` header when the origin volunteers one, now
run on every install — but no commit SHA is hardcoded for whisper.cpp
(`WhisperCppModel.downloadURL` still resolves against a mutable
`resolve/main`), because this PR was authored in an environment with no
network path to `huggingface.co` to obtain a real one to pin, and a wrong
or stale hardcoded value would fail every future download outright.
sherpa-onnx's two models were already pinned to an exact commit SHA and an
exact release tag before this PR — pre-existing, not new work here. See
the megaplan's "PR 15" section for the full contract, the test coverage
(a private `StubDownloadProtocol` rather than the shared `MockURLProtocol`
— see PR 15's "Status" note for why), and the rest of the known gaps
(resume data does not survive a relaunch; no automatic retry-with-backoff;
no cancellation-timing test).

**Progress — item 6 and the rest of item 5 (the PR 16 boundary),
implemented on branch `claude/resilience-roadmap-plan-fn23ki`.**
`ModelVerification` (`Kurn/Services/ModelVerification.swift`, new) is the
third fact item 6 asks for: `.unverified` / `.verified(Date)` /
`.corrupt(reason:)` per model id, persisted separately from consent and
from `ModelStore.isInstalled`'s byte-count check. Item 5's remaining half
("loading a small health probe") landed for whisper.cpp and sherpa-onnx:
`WhisperContext.init` and `SherpaOnnxOfflineSpeakerDiarizationWrapper
.init?` were already failable on a corrupt file but nothing called them
until a real transcription/diarization run did — `WhisperCppTranscriber
.verifyModelLoads(at:)` and `SherpaOnnxDiarizer.verifyModelsLoad()` now
call exactly those same initializers once, right after each downloader
installs its bytes, off-actor (`Task.detached`, since both are blocking C
calls), deleting the file and failing the download outright if the probe
fails. The four FluidAudio-backed sets get the same fact without a new
probe: `ModelDownloadConsent.download`'s FluidAudio branch already fully
loads each model (CoreML/ANE compilation included) as an inseparable part
of downloading it, so `ModelDownloadController` now just records that
success via `ModelVerification.record(...)` instead of discarding it.
Item 6's "verify ... during storage inventory" is `ModelStore
.installedModels()`, which now attaches each row's verification state
(size drift against the last recorded verification reads as corrupt) and
quietly re-applies `isExcludedFromBackup` on whisper.cpp/sherpa-onnx
folders if it's ever found unset — the "verify and fix" shape
`ModelStoreProtection.applyAndVerify` already uses for the SwiftData store.
"Offer redownload for corruption" reuses the existing delete flow rather
than a new one: `ModelDownloadController.deleteModel` already reverts the
affected engine/consent when the deleted group is active, so removing a
corrupt model leaves the feature ready to re-enable, which re-triggers
consent + download + probe. Settings → Storage shows a checkmark for a
verified model and a warning line for a corrupt one; `.unverified` (every
model installed before this PR) renders with no badge, deliberately, so
existing working installs don't suddenly look suspect. See the megaplan's
"PR 16" section for the full contract, `KurnTests/ModelVerificationTests
.swift`'s coverage, and the known gaps (retroactive verification of
pre-existing installs is out of scope; digest checking stays
whisper.cpp/sherpa-onnx-only and is size-based drift detection, not a
routine re-hash; `isExcludedFromBackup` reconciliation can't reach
FluidAudio's own cache directory; whisper.cpp's revision pinning is still
open).

### H8 · Operation ownership, resource recovery, and external controls — P1, items 2–6 done

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

**Progress — items 2–3 (the PR 17 boundary), merged as
[PR #174](https://github.com/carlosmazzei/Kurn/pull/174).** Item 2's "replace sticky resource
state with a cooldown/recheck model": `ResourcePressureMonitor`
(`Kurn/Infrastructure/ResourceGuard.swift`) used to set a single boolean the
first time `UIApplicationDidReceiveMemoryWarningNotification` fired and
never clear it — every later transcription/model-download/enhancement
preflight saw a permanently unhealthy device for the rest of the process's
life, regardless of how much memory had since been freed (this file's own
H8 status row named exactly this). `MemoryPressureState` (new, pure value
type, mirroring `SecurityCoverState`'s shape) replaces it: new heavy work
pauses for a measured cooldown (60s) after the *last* observed warning,
then admission re-evaluates automatically — no explicit reset needed. A
second, live signal — `ProcessInfo.ThermalState`, checked independently
with no cooldown of its own — blocks admission on `.serious`/`.critical`
and clears itself the instant the device cools, closing "later admission
reevaluates memory, thermal state and storage instead of disabling work
until relaunch" (storage was already dynamic; only memory pressure was
sticky, and thermal state wasn't checked at all before this).
Item 3's "resource-aware scheduler/cap": `ResourceScheduler`
(`Kurn/Infrastructure/ResourceScheduler.swift`, new) is a global
actor-isolated weight budget (`defaultTotalWeight = 100`); `ResourceWorkKind`
weights preprocessing, transcription (per engine), diarization (per
engine), enhancement, and model loading, and every one of the five is wired
in at its existing funnel point — `TranscriptionService.transcribeGated`/
`.diarize` (every engine), `AudioPreprocessor.process`,
`PlaybackEnhancementRenderer.render`, `FluidAudioModelStore`'s coalesced
load, `ModelDownloadConsent.download`'s FluidAudio branch, and H7 PR 16's
two post-install health probes. This does not touch or duplicate
`TranscriptionService.transcribe`'s existing compile-time sequential/
concurrent branch for one recording's own ASR-vs-diarization overlap; the
weight table was chosen so the two agree (cloud transcription's weight
fits alongside any diarization engine's, matching that branch's concurrent
case; any on-device engine's weight never fits alongside FluidAudio's or
sherpa-onnx's diarization weight, matching its sequential case — both
pinned as regression tests) rather than fight it. What the scheduler adds
is the case that branch never covered: two *different* recordings' heavy
stages contending for memory at once, which nothing previously gated. See
the megaplan's "PR 17" section for the full contract, the test coverage,
and the known gap (the weight table, cooldown interval, and thermal
thresholds are first-cut estimates — no memory-cost benchmark exists
anywhere in this codebase to calibrate them against). Items 1 and 4–8
remain PR 18–20's scope.

**Progress — items 4–5 (the PR 18 boundary), merged as
[PR #175](https://github.com/carlosmazzei/Kurn/pull/175).** Every `@unchecked Sendable`
(20 sites) and `nonisolated(unsafe)` (12 sites) in non-test source, and
every continuation/callback bridge (11 sites), was read and classified;
most were already correctly justified (a lock, actor isolation, or a
synchronously-invoked `@Sendable` closure that never truly crosses
threads) and left alone, per item 4's own "keep the justified lock/queue
wrappers." Five things worth reporting came out of it — three real bugs
fixed here, one annotation checked and confirmed necessary, and one plan
item already fixed before this PR started: `SherpaOnnxDiarizer` and
`FluidAudioVAD` each raced their real work against a sleeping timer in a
`TaskGroup` and called the loser a "timeout" — but neither sherpa-onnx nor
FluidAudio's `VadManager` exposes any way to abort an in-flight call, and
a `TaskGroup` cannot return until every child task finishes, cancelled or
not, so the race never bounded wall-clock time at all: it blocked for the
real call's full duration and then discarded a valid, just-slow result for
a fabricated timeout error. Both now call the real work directly and log a
notice if it exceeded its budget instead of throwing an error and
discarding the result — same real-world latency, but honest, exactly item
5's "report deferred cancellation truthfully" (no engine abort hook exists
for either, unlike whisper.cpp's `abort_callback`, which is what item 5's
"use a real engine abort hook where available" already looks like in this
codebase). `RecorderViewModel`'s pending mic-choice continuation could be
silently overwritten by a second concurrent request, leaking the first —
it's now resolved to the default before a new one is stored, so every
continuation is resumed exactly once. `CloudSettingsSync
.didChangeExternally` was an unsynchronized mutable property on an
`@unchecked Sendable` type relying only on a comment's claim about which
actor touches it; now lock-guarded like every other such property in this
codebase. `LockScreenRecordingController.activity`'s `nonisolated(unsafe)`
looked removable (the whole type is `@MainActor` and every access site
already inherits that isolation) — removing it was tried and reverted
when CI's first push failed: `Activity<T>.update`/`.end` are `nonisolated`
async methods in ActivityKit's own API, and Swift 6's "sending" check
flags passing a main-actor-isolated value into a `nonisolated` call
regardless of whether it's genuinely shared across threads. Kept, now
with a comment explaining the real reason. A last finding — the plan's own
"background uploader session under synchronization rather than a racing
lazy property" — turned out to already be fixed by an earlier commit that
landed before this track branched; this PR adds the concurrent-access
test that fix never had. See
the megaplan's "PR 18" section for the full contract, the test coverage,
and the known gaps (no Thread Sanitizer configuration exists yet anywhere
in the project; three duplicated `nonisolated(unsafe)` logging-handler
globals share one unreasoned-about pattern; `FoundationModelsProvider`'s
timeout wraps a closed-source Apple framework call that couldn't be
verified either way). Items 1 and 6–8 remain PR 19–20's scope.

**Progress — item 6 (the PR 19 boundary), merged as
[PR #176](https://github.com/carlosmazzei/Kurn/pull/176).**
`LockScreenRecordingController.start()` used to fire an untracked `Task { }`
that unconditionally created and stored a Live Activity once it ran, with
nothing checking whether a same-instant `end()` had already decided there
was nothing to end. `Activity.request` is `throws` but not `async` — a fully
synchronous ActivityKit call — so the only real race was *scheduling order*
between independently-created `start()`/`end()` tasks on the same actor,
which Swift's concurrency model does not guarantee matches call order: if
`end()`'s task ran first, it correctly found `activity == nil` and did
nothing, and the later-running `start()` task would then create a real
activity nothing would ever end — an orphan on the Lock Screen/Dynamic
Island until the system evicted it on its own schedule. A `runID: UUID`,
bumped by both `start()` and `end()`, closes it: the queued start task
checks `runID` again synchronously, immediately before `Activity.request`,
with no intervening `await` for anything to invalidate the check in between
— a superseded `start()` skips creating an activity nothing would manage,
rather than creating one and only then discovering it's orphaned. `update()`
gained the same check as stale-work hygiene (not orphan-critical the way
`start()`'s is). `startTask` is retained so `end()` can also explicitly
cancel it, matching item 6's literal "track and cancel the in-flight
ActivityKit start task" — `runID`, not the cancellation, is what's
structurally load-bearing, since `Task.cancel()` cannot interrupt
`Activity.request` itself. See the megaplan's "PR 19" section for the full
contract and the known gap (no automated test proves the race is closed —
`Activity<RecordingActivityAttributes>` has no protocol seam to fake, and
forcing two unstructured tasks' relative scheduling order deterministically
isn't something Swift's concurrency runtime supports; verified by CI
compiling and the existing suite passing, and by the same `runID`
generation-counter pattern already proven elsewhere in this codebase, e.g.
PR 18's mic-choice continuation). Items 1, 7 and 8 remain PR 20's scope.

**Progress — items 1, 7 and 8 (the PR 20 boundary), implemented on branch
`claude/resilience-roadmap-plan-fn23ki`.** Item 7's "compile the Watch wire
protocol from one shared source": `WatchCommand`/`WatchSessionKey` were
independently typed in a per-target copy of `WatchSessionProtocol.swift` on
each side; `KurnWatch`'s copy is now deleted and the single remaining file
(`Kurn/Services/WatchSessionProtocol.swift`) compiles into both targets via
an explicit `project.pbxproj` Sources entry, the same dual-membership
pattern `RecordingActivityAttributes.swift` already uses to share one file
between `Kurn` and `KurnLiveActivityExtension`. "Add command IDs, timeout,
deduplication ... and acknowledgements for received, state-changed, and
durably-finalized": every Watch command now carries a `commandID`;
`RecordingCommandRouter` caches the last 20 outcomes so a redelivered
duplicate (the watch retrying after a lost reply) replays the cached result
instead of re-running the action, and the watch's `send()` gained a 10s
local timeout via a lock-guarded resume-exactly-once continuation box (the
same shape PR 18's `storeMicChoiceContinuation` established). Since every
`RecordingCommandRouter` handler in this app — `stop`'s file finalization
included — already runs synchronously to completion before its caller
learns the outcome, a single reply carrying a new `WatchAckPhase`
(`received`/`stateChanged`/`finalized`) covers all three cases the plan
asks for without a multi-message round trip; `onStop`'s type changed from
`() -> Void` to `() -> Bool` so `stopAndSave()`'s already-synchronous
finalization outcome reaches the reply. "Reconcile from application context
after reconnect": `PhoneSessionController` now checks
`RecordingCommandRouter.shared.hasActiveSession` on every `WCSession`
(re)activation and pushes a fresh idle context when false — a live session
never survives process termination, so without this a kill mid-recording
could leave the Watch showing a phantom in-progress recording indefinitely.
Item 8's "intents report accepted, not actual capture, until the recorder
confirms it": `StartRecordingIntent.perform()` now awaits an acceptance
reply from `RecordingLauncher` (bounded by a 3s timeout, same box shape)
instead of claiming success the instant it posted the request — closing a
cold-launch race where an unconfigured `RecordingLauncher` silently dropped
the request but the intent still reported success; actual capture
confirmation remains the Live Activity's job, unchanged, since this intent
has no channel back from `RecorderView`'s later mic-permission flow. Item 1
("give every long-running operation an owner, run ID and explicit
lifetime") was audited against the plan's own named example — "chat/search
tasks cancel on dismissal": `MeetingsListView`'s search debounce already
gets this for free from SwiftUI's `.task(id:)`, but `MeetingChatViewModel`'s
reply `Task` had nothing cancelling it when its owning view was dismissed
mid-reply, silently burning a paid cloud LLM call in the background; fixed
with a `deinit { task?.cancel() }`. See the megaplan's "PR 20" section for
the full contract, the new `RecordingCommandRouterTests` coverage, and the
known gaps (the Watch-side timeout, reconnect reconciliation, and intent
acceptance wait aren't covered by automated tests, for the same
real-device/non-deterministic-ordering reasons PR 19 already stated; item
1's general mechanism was audited against its named examples, not
exhaustively re-swept across the whole app). **H8's plan is now fully
addressed.**

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

**Progress — item 1's metadata plus item 3, scoped to one concrete case
(the PR 21 boundary), implemented on branch
`claude/resilience-roadmap-plan-fn23ki`.** `AppError` gains `category`
(`AppErrorCategory`), `severity` (`AppErrorSeverity.blocking`/`.warning`),
`isRetryable`, `recoveryAction` (`AppErrorRecoveryAction?`, a stable
identifier for the next step — item 2's actual contextual buttons are a
later PR), and `privateContext` (the raw associated-value detail a handful
of cases already carried, kept distinct from the safe, localized
`errorDescription`; not wired into export/redaction yet — item 6). One
correction along the way: `.authenticationFailed` reads as
provider-authentication by name but comes from `RecordingAccessGate`'s
biometric gate, not `AIProvider` — recategorized from `.provider` to
`.authentication`. For item 3's "concurrent failures remain attributable,"
audited every `TranscriptionViewModel` instantiation (exactly two: the
`KurnApp` shared instance every `MeetingDetailView` reads via
`@Environment`, and `TranscriptionScheduler`'s own separate one) and found
its single `error: AppError?` was exactly the bug item 3 describes: two
different recordings transcribing concurrently could clobber or
misattribute each other's failure through that one shared property.
`errorsByRecording: [UUID: AppError]` fixes it, mirroring the shape
`diarizationWarnings: [UUID: String]` right next to it already used for
the same problem with a non-`AppError` warning; `MeetingDetailView`'s
alert now binds to the recording it's actually showing rather than
whatever last touched the shared property. `persist()`'s own error surface
(13 call sites across 5 files, some meeting- rather than recording-scoped)
deliberately stays on the original `error` property — a separate,
broader change not required to fix the concrete bug this PR targets.
Cancellation-is-silent was audited across the app's four biggest
cancellable flows (`TranscriptionViewModel.transcribe`/`generateSummary`,
`DocumentGenerationViewModel`, `MeetingChatViewModel`) and found already
correct everywhere — no fix needed. See the megaplan's "PR 21" section for
the full contract, the new `AppErrorMetadataTests`/
`TranscriptionViewModelErrorAttributionTests` coverage, and the known gaps
(items 2, 4–8 remain PR 22–23's scope; `persist()` itself is unmigrated).

**Progress — items 5–6, scoped to one concrete adopter plus four exact
log sites (the PR 22 boundary), merged into `main` as
[PR #179](https://github.com/carlosmazzei/Kurn/pull/179) (commit
`0765891`, merge commit `ea6eae8`).** Item 6's "keep the reliability
event buffer local, encrypted and bounded": `ReliabilityEvent`/
`ReliabilityLog` already existed from an earlier "Baseline and seams"
step, but `ReliabilityLog.handler` only forwarded to `os.Logger` —
ephemeral, and only readable from a connected Mac's Console.app, not on
the device itself. `Kurn/Infrastructure/ReliabilityEventStore.swift`
(new) adds a durable buffer: one append-only JSON-Lines file, directory-
and file-protected the same `.completeUnlessOpen` way
`DiagnosticReportStore` already protects MetricKit reports, capped at 500
events with pruning that doesn't rewrite the whole file on every append,
and lock-guarded (not an actor — `ReliabilityLog.handler`'s synchronous
`@Sendable` signature doesn't support `await`ing at every call site) since
`TranscriptionViewModel` (main actor) and `DocumentGenerationService` (off
it) can both call it. `KurnApp`'s handler now writes to both the logger
and this store. Item 5's "standardize... events": widened adoption from
its one existing pair of call sites to `TranscriptionViewModel.transcribe`
— the app's single most important resilience path — with one
`OperationID` per attempt correlating its `.started` through whichever
terminal outcome it reaches; the Speech-permission-denied early return,
which PR 21 had missed migrating to `errorsByRecording`, is fixed the same
way here. Item 5's "remove public raw error descriptions... use
`AppError.logCode` consistently instead of publishing arbitrary
`localizedDescription`": grepped for the precise pattern (an `AppError`'s
own `errorDescription` — which can embed a raw underlying system error's
text via PR 21's `privateContext` — logged at `.public`) and fixed the
four exact sites found: two in `transcribe`'s own failure paths, one each
in `RecorderViewModel.startRecording` and
`AudioRecorderService.start`. Item 6's "redaction preview": every
`ReliabilityEvent` field is content-free by construction, so
`Kurn/Views/ReliabilityEventsListView.swift` (new, wired into
`DiagnosticsSettingsView`) showing exactly what would be exported already
delivers the transparency a redaction preview exists for — nothing needs
redacting because nothing sensitive was ever admitted in the first place.
See the megaplan's "PR 22" section for the full contract, the new
`ReliabilityEventStoreTests`/`ReliabilityEventTests` coverage, and the
known gaps (a reference ID surfaced in the UI error dialog itself needs
its own design pass on the shared `errorAlert` modifier, deferred to
PR 23; the broader 46-site non-`AppError` raw-log-description sweep is
unaudited; `ReliabilityEvent` adoption is now two operations, not every
resilience path).

**Progress — items 7–8's repair surface, without the accessibility test
coverage (the PR 23 boundary), implemented on branch
`claude/resilience-roadmap-plan-fn23ki`.** `Kurn/Views/Settings/
HealthRecoveryView.swift` (new, split into `HealthRecoveryView+Sections
.swift` to stay under SwiftLint's `type_body_length` warning) is item 7's
"repair surface, not analytics": one screen, reachable from Settings,
aggregating the six conditions item 7 names — pending recovery, quarantined
audio, degraded transcripts, failed/deferred jobs, model verification and
recent failure codes — three of which reuse an existing aggregation
wholesale (`RecordingQuarantine.items()`, `ModelDownloadController
.installedModels` filtered to `.corrupt`, `ReliabilityEventStore
.recentEvents(limit:)` filtered to `.failed`) and three of which needed a
new cross-library `FetchDescriptor`/decode pass (pending capture recovery,
stalled transcriptions, and degraded transcripts — the last decoding every
`Transcript.pipelineReport`, since the field is opaque JSON and can't be
expressed as a `#Predicate`). Every action dispatches to the exact same
recovery function its existing per-item counterpart already calls
(`RecordingRecovery.retryRecovery(for:context:)`, `TranscriptionViewModel
.startTranscription`/`.retryCorrection`, `RecordingQuarantine.recover`/
`.delete`/`.exportURL`, `ModelDownloadController.deleteModel`) rather than
reimplementing recovery logic, which is what makes "repair surface, not
analytics" true structurally and not just in the screen's framing. See the
megaplan's "PR 23" section for the full contract and known gaps: no new
test coverage was added (every action calls an already-tested recovery
function; the screen's own contribution is aggregation and dispatch, not
new recovery logic), item 8's VoiceOver/Dynamic Type/UI-test coverage is
not included (`HealthRecoveryView` is not one of the five screens
`AccessibilityAuditUITests` audits), the reference ID PR 22 deferred here
is still not built, and items 2 and 4 remain explicitly out of scope, as
stated in PR 21's own write-up. **This closes out H9's plan** except those
two items.

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
6. **Network lifecycle — core done; model integrity continues in H7.** Active
   traffic is foreground-only with unified destination/retry/cost policy, request
   identity and cooldown. Model digest, resume and atomic replacement remain.
7. **External and concurrency hardening.** Resource scheduler, non-cooperative
   cancellation truth, shared Watch protocol, command acknowledgements and
   Activity/intent race handling.
8. **Continuous release gate.** Split CI signals, retain failure artifacts, run
   migrations/faults/sanitizers/repetition, and record the scorecard alongside
   the existing accuracy history.

#### Current next execution order (2026-09-01)

1. **H2 versioned schema baseline — done, merged in [PR #155](https://github.com/carlosmazzei/Kurn/pull/155).** The
   current model graph is now a `VersionedSchema` (`KurnSchemaV1`) with a
   migration plan and an injectable `ModelContainerBootstrap`; the round-trip
   fixture is a same-run generated legacy store rather than committed N-1/N-2
   binaries (see the H2 schema-baseline handoff above the H2 plan for why).
   `build-and-test` and `kurncore-linux` both passed before merge.
2. **H2 recoverable bootstrap state machine — done, merged in [PR #157](https://github.com/carlosmazzei/Kurn/pull/157).**
   `ModelStoreBootCoordinator` replaces the production `fatalError` with
   `waitingForProtectedData`/`opening`/`ready`/`recoveryRequired`,
   `ModelStoreOpenFailureClassifier` names the reason, and background-task
   registration now runs before the store is ever opened. `build-and-test`
   and `kurncore-linux` both passed on the first push. See the H2 boot state
   machine handoff above the H2 plan for what shipped.
3. **H2 protected backup, restore, salvage, recovery UI — done, merged in
   [PR #158](https://github.com/carlosmazzei/Kurn/pull/158).**
   `ModelStoreBackupManager` preserves original store bytes
   (copy-only backup, quarantine-not-delete restore/fresh-start);
   `ModelStoreSalvage` offers best-effort read-only recovery;
   `ModelStoreProtection.applyAndVerify` covers bootstrap protection
   verification. Two real bugs were found and fixed during this PR, the
   second of which would have crashed users on the recovery screen (a
   SwiftData use-after-free: fetched `Meeting`s outliving the
   `ModelContainer` they came from). See the H2 backup/restore/salvage/
   recovery-UI handoff above the H2 plan for the full investigation, what
   shipped, and the known salvage limitations.
4. **H3 (P0), PR 1 of several: trash-then-purge deletion — done, merged in
   [PR #159](https://github.com/carlosmazzei/Kurn/pull/159).** The risk
   register's most concrete H3 hazard ("meeting/recording deletion removes
   audio before the SwiftData save") is fixed: `RecordingTrash` moves every
   file aside into a protected trash folder before the model mutation runs,
   purges it once `save()` commits, and restores it immediately on a
   synchronous save failure; `RecordingTrash.sweep(context:)` reconciles any
   trash folder a process death left behind, at launch and on foreground
   activation, against durable truth (whether a `Recording` row referencing
   that file still exists) rather than inferred state.
5. **H3 PR 2 of several: typed JSON corruption — done, merged in
   [PR #160](https://github.com/carlosmazzei/Kurn/pull/160).** The risk register's other named H3
   hazard ("`JSONStorage` turns decode failure into empty content") is fixed
   for `Transcript.segments`/`Summary.sections`: a versioned, checksummed
   envelope plus a typed `.empty`/`.value`/`.corrupted` decode outcome
   replace the old "decode failure silently means empty" contract, with a
   fallback that still accepts every pre-existing row's un-enveloped format
   as real content rather than corruption. See the H3 PR 2 handoff above the
   H4 plan for what's in scope and what stays on the old, lenient contract.
6. **H3 (P0) closed out — fail-closed protected storage and quarantine
   ([PR #162](https://github.com/carlosmazzei/Kurn/pull/162)), the durable
   operation journal (`d7e3dee`), and the versioned authoritative envelope
   for the transcription checkpoint (`e7a156a`) are all merged.** Item 7's
   separate reconciliation pass for derived copies is the one H3 plan item
   still open; see the H3 "Progress" list.
7. **H4 (P0) done — merged in
   [PR #165](https://github.com/carlosmazzei/Kurn/pull/165) (pipeline
   fingerprint and checkpoint validation),
   [PR #166](https://github.com/carlosmazzei/Kurn/pull/166) (throwing chunk
   commits and bounded automatic recovery), and
   [PR #167](https://github.com/carlosmazzei/Kurn/pull/167) (durable,
   resumable map-stage checkpointing shared by summary and wiki
   generation).** Item 3, the full explicit operation-state enum, is
   deliberately deferred until a concrete need for the richer states shows up.
8. **H5 (P1) done.** Typed stage outcomes and the persisted pipeline
   report (`docs/resilience-megaplan.md`'s PR 11 boundary) merged in
   [PR #168](https://github.com/carlosmazzei/Kurn/pull/168). Every stage now
   returns requested/effective engine plus a
   `succeeded`/`degraded`/`skipped`/`failed` outcome with a stable reason, and
   the aggregate report persists beside the transcript so "completed with
   warnings" is durable rather than inferred. The final integrity gate and
   correction-identity check (PR 12) merged in
   [PR #169](https://github.com/carlosmazzei/Kurn/pull/169): a structurally
   broken fused/corrected result, or a correction that violated its
   segment-identity contract, is rejected before it can replace an existing
   transcript. The completed-with-warnings banner plus a stage-specific
   retry for correction (PR 13) merged in
   [PR #170](https://github.com/carlosmazzei/Kurn/pull/170), closing H5's
   plan.
9. **H7 (P1) done, merged (#171/#172/#173).**
   Typed Keychain outcomes (`docs/resilience-megaplan.md`'s PR 14 boundary)
   replace the old API that collapsed every Security-framework failure into
   "not configured": a `KeychainAccessing` seam, a fixed accessibility
   migration that only completes after a confirmed outcome, and
   explicit-Save for provider credentials (URL validated first, a failed
   Keychain write surfaced rather than silently assumed) — merged in
   [PR #171](https://github.com/carlosmazzei/Kurn/pull/171). The PR 15
   boundary unifies the whisper.cpp and sherpa-onnx downloaders behind one
   injectable `ModelDownloading` actor: exact-size plus opportunistic-SHA-256
   verification, atomic install with backup-and-restore on failure, resume
   data across an interrupted transfer, and a wired-up Cancel action —
   merged in [PR #172](https://github.com/carlosmazzei/Kurn/pull/172). The
   PR 16 boundary adds `ModelVerification`, a third persisted fact —
   "proven to load," distinct from consent and from bytes-on-disk — backed
   by a real post-install health probe for whisper.cpp/sherpa-onnx and, for
   the four FluidAudio-backed sets, by recording the load their own
   download already performs; a storage-inventory pass flags on-disk size
   drift as corruption and repairs `isExcludedFromBackup` — merged in
   [PR #173](https://github.com/carlosmazzei/Kurn/pull/173). Pinning
   whisper.cpp to an immutable revision (no network path to HuggingFace to
   obtain a real one in either PR's environment) is the one piece of H7's
   plan still open.
10. **Done: H8 (P1), plan fully addressed.** The PR 17 boundary
    (`docs/resilience-megaplan.md`'s "PR 17") replaces the sticky
    memory-warning latch — a boolean set once and never cleared for the
    rest of the process's life — with `MemoryPressureState`, an
    observed-at/cooldown/recheck model that pauses new heavy work for a
    measured interval after the *last* warning and then re-evaluates
    automatically, plus a live thermal-state check. `ResourceScheduler`, a
    new global actor-isolated weight budget, gates preprocessing,
    transcription, diarization, enhancement, and model loading at their
    existing funnel points so two concurrent transcriptions can no longer
    both pass an independent preflight and then both hold a heavy engine's
    memory at once — merged as
    [PR #174](https://github.com/carlosmazzei/Kurn/pull/174). The PR 18
    boundary audited every `@unchecked Sendable`/`nonisolated(unsafe)`/
    continuation bridge in the app: two "false timeouts"
    (`SherpaOnnxDiarizer`, `FluidAudioVAD`) raced their real, un-abortable
    work against a sleeping timer and called the loser a "timeout," but a
    `TaskGroup` can't return until every child finishes, so the race never
    bounded time — it just discarded a valid slow result for a fabricated
    error, now fixed to run the work directly and report slowness
    truthfully instead; a leaked mic-picker continuation
    (`RecorderViewModel`) and an unsynchronized mutable property
    (`CloudSettingsSync`) were fixed the same way — merged as
    [PR #175](https://github.com/carlosmazzei/Kurn/pull/175). The PR 19
    boundary closes an ActivityKit start/end race: an untracked `start()`
    task could still create a Live Activity after a same-instant `end()`
    had already run and found nothing to end, orphaning it on the Lock
    Screen/Dynamic Island. A `runID` generation counter, checked
    synchronously immediately before the one non-cancellable call
    (`Activity.request`, `throws` but not `async`) that creates the
    activity, closes it — merged as
    [PR #176](https://github.com/carlosmazzei/Kurn/pull/176). The PR 20
    boundary closes the rest: `WatchCommand`/`WatchSessionKey` now compile
    from one shared source into both the `Kurn` and `KurnWatch` targets
    instead of two independently-typed copies; Watch commands carry a
    `commandID` `RecordingCommandRouter` deduplicates against (a
    redelivered duplicate replays its cached outcome instead of re-running
    the action), `WatchConnectivityManager.send` gained a bounded local
    timeout, and a three-phase `WatchAckPhase` reply
    (`received`/`stateChanged`/`finalized`) covers item 7's acknowledgement
    ask in one round trip, since every command handler already runs
    synchronously to completion (`stop`'s file finalization included)
    before its caller learns the outcome. `PhoneSessionController`
    reconciles a stale application-context recording state on every
    `WCSession` reconnect, since a live session never survives process
    termination. `StartRecordingIntent.perform()` now awaits an acceptance
    reply from `RecordingLauncher` (bounded timeout) instead of claiming
    success the instant it posted the request, closing a cold-launch race
    that used to silently drop the request — item 8's "report accepted, not
    actual capture." Item 1 was audited against its own named "chat/search
    tasks cancel on dismissal" example: the search debounce was already
    correct via SwiftUI's `.task(id:)`; `MeetingChatViewModel`'s reply task
    was not, and now cancels via `deinit` — merged as
    [PR #177](https://github.com/carlosmazzei/Kurn/pull/177) (commit
    `7d15192`, plus one follow-up CI fix, `45d96d0`, for a Swift 6 `deinit`
    isolation error). **H8's plan is now fully addressed.**
11. **In flight: H9 (P1/P2), PR 21/22 merged, PR 23 implemented.** `AppError` gains
    `category`/`severity`/`isRetryable`/`recoveryAction`/`privateContext`
    (`Packages/KurnCore/.../AppErrorMetadata.swift`), item 1's presentation
    metadata — `recoveryAction` is data only for now, not yet wired into
    contextual UI buttons (item 2, a later PR). For item 3 ("concurrent
    failures remain attributable"), audited every
    `TranscriptionViewModel` instantiation (the `KurnApp` shared instance
    every `MeetingDetailView` reads via `@Environment`, and
    `TranscriptionScheduler`'s own separate one — exactly two) and found
    its single `error: AppError?` was the concrete bug item 3 describes:
    two recordings transcribing concurrently could clobber or misattribute
    each other's failure. `errorsByRecording: [UUID: AppError]` fixes it,
    mirroring the existing `diarizationWarnings: [UUID: String]` shape
    right next to it; `MeetingDetailView`'s alert now binds to the
    recording it's actually showing. `persist()`'s own error surface stays
    on the shared `error` property — a broader, separate change not
    required to fix this PR's concrete target. Cancellation-is-silent was
    audited across the app's four biggest cancellable flows and found
    already correct everywhere — merged as
    [PR #178](https://github.com/carlosmazzei/Kurn/pull/178) (commit
    `674687c`). The PR 22 boundary adds `Kurn/Infrastructure/
    ReliabilityEventStore.swift`, a lock-guarded, bounded (500, pruned
    without a full rewrite per append), protected JSON-Lines buffer for
    the pre-existing `ReliabilityEvent`/`ReliabilityLog` vocabulary —
    `KurnApp`'s handler now writes to it alongside its existing
    `os.Logger` forwarding (item 6). Adoption widens to
    `TranscriptionViewModel.transcribe`, correlated by one `OperationID`
    per attempt (item 5), and the exact four sites logging an `AppError`'s
    raw `errorDescription` at `.public` (two in `transcribe`, one each in
    `RecorderViewModel`/`AudioRecorderService`) now log `logCode`/
    `privateContext` instead (item 5). `Kurn/Views/
    ReliabilityEventsListView.swift` lists and shares recent events;
    since every field is content-free by construction, showing them
    verbatim already is the redaction preview item 6 asks for — merged as
    [PR #179](https://github.com/carlosmazzei/Kurn/pull/179) (commit
    `0765891`, merge commit `ea6eae8`). The PR 23 boundary adds
    `Kurn/Views/Settings/HealthRecoveryView.swift` (split into
    `HealthRecoveryView+Sections.swift` to stay under SwiftLint's
    `type_body_length` warning), item 7's repair surface: one screen
    aggregating pending capture recovery, quarantined audio, degraded
    transcripts, failed/deferred transcription jobs, corrupt on-device
    models and recent reliability failure codes, three reused wholesale
    from existing aggregations and three from new `FetchDescriptor`/decode
    queries (pending recovery, stalled transcriptions, and degraded
    transcripts, the last decoding every `Transcript.pipelineReport` since
    the field is opaque JSON). Every action dispatches to the exact same
    recovery function its existing per-item UI already calls
    (`RecordingRecovery.retryRecovery`, `TranscriptionViewModel
    .startTranscription`/`.retryCorrection`, `RecordingQuarantine
    .recover`/`.delete`/`.exportURL`, `ModelDownloadController
    .deleteModel`) — implemented on branch
    `claude/resilience-roadmap-plan-fn23ki`. **This closes out H9's plan**
    except items 2 and 4 (contextual recovery-action UI, optimistic-UI
    rollback), deliberately deferred since PR 21; item 8's accessibility
    coverage of the new screen, the deferred UI reference-id, and the
    broader non-`AppError` log-site sweep also remain.
12. **Carry H1/H10 release work in parallel.** Complete the physical interruption,
    route, lock/background and low-storage matrix without delaying the next code P0.
13. **Defer H6.9.** Streaming is evidence-gated polish, not the next resilience
    dependency; H9 owns dedicated waiting/cancellation presentation.

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
