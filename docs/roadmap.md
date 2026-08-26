# Roadmap

Fourteen candidate capabilities, each judged against what Kurn is rather than
against what is fashionable: six to adopt, four to evaluate, four deliberately
out of scope. Then two focused tracks that do not fit that taxonomy — six
diarization items, and one engineering change that is not a feature at all.

The verdicts matter less than the reasoning attached to them. A "no" with a
recorded reason stops the same idea from being re-litigated every few months; a
"yes" with its coupling point named is most of the design work already done.

## Premise: the filter

Kurn is a local-first meeting recorder. That sentence is load-bearing, and these
five invariants are what it decomposes into. Every entry below is judged against
them, and where an entry creates tension the tension is stated rather than
smoothed over.

| | Invariant | What holds it up today |
|---|---|---|
| **I1** | Nothing leaves the device without an explicit request | Network only on opt-in cloud transcription or a cloud summary provider; a fresh install works offline |
| **I2** | Meeting-derived content lives in the encrypted store | `ModelStoreProtection` (`.completeUnlessOpen`) covers the SwiftData store; never a loose file, cache, or `UserDefaults` |
| **I3** | Accuracy is measured, not asserted | `KurnTests/Support/Evaluation/` (WER, DER, RTTM) plus the public-dataset matrix |
| **I4** | The subject is meetings, not dictation | The value is a 90-minute multi-speaker file, not a six-second insert |
| **I5** | Heavy dependencies are opt-in | `ModelDownloadConsent` gates every model fetch, with a working fallback when declined |

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

| | |
|---|---|
| **Couples to** | `Providers/LLMProvider.swift`, `ProviderFactory`, `AIProviderKind` |
| **Invariant** | Closes I1, which the app used to violate in practice |
| **Status** | Implemented — [PR #139](https://github.com/carlosmazzei/Kurn/pull/139) |

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

| | |
|---|---|
| **Couples to** | New `@Model` in the store · `WhisperCppTranscriber` · `OpenAIProvider` · `LLMTranscriptCorrector` |
| **Invariant** | I2 for storage; I3 because the effect is measurable |
| **Effort** | Medium |

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

### F3 · Frictionless capture: App Intents, widget, Control Center

| | |
|---|---|
| **Couples to** | `RecordingCommandRouter` · `KurnLiveActivityExtension` |
| **Invariant** | No tension — system integration, no network |
| **Effort** | Low-medium · best effort-to-value ratio here |

`RecordingCommandRouter` already dispatches pause, resume, stop and toggle from
the Watch and from Live Activity deep links. What is missing is the first
command: there is no way to *start* a recording without unlocking the phone,
opening the app and tapping. `KurnLiveActivityExtension` contains only
`RecordingLiveActivityWidget.swift` — no home or lock-screen widget, no
`ControlWidget` — and the project contains no `AppIntent` types at all.

The use case is the product's own: realizing forty seconds late that this call
should have been recorded. The dispatcher exists; this is largely wiring.
`AppShortcutsProvider` brings Siri along, and a `ControlWidget` brings the
Action Button with it.

**Security check before shipping.** Starting a recording from a lock-screen
control means capture begins before `RecordingAccessGate` has authenticated.
That is correct — capture must not wait on Face ID — but it makes the cover
window load-bearing in a new path. Verify `SecurityCoverState` resolves to
`.locked`, not `.hidden`, when an intent brings the app forward.

### F4 · Calendar context at record time

| | |
|---|---|
| **Couples to** | `MeetingFormView` · `Speaker` · `SpeakerIdentityMatcher` |
| **Invariant** | I2 — attendee names are meeting-derived content, so they go in the store |
| **Effort** | Low-medium |

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

| | |
|---|---|
| **Couples to** | `SummarySection.items` · the `AutoTagConfirmView` review pattern |
| **Invariant** | Compatible — local write; any syncing is the user's Reminders setting |
| **Effort** | Low-medium |

`Summary.sections` already produces `SummarySection.items`. Today they are text a
person retypes somewhere else. Writing them as `EKReminder`s, with the meeting in
the note and a deep link back, is a small amount of work on top of output that
already exists.

Non-negotiable: a review step before anything is written. LLM output must never
silently create reminders — which is precisely the pattern `AutoTagConfirmView`
already establishes for suggested tags. Reuse it rather than inventing a second
review flow.

### F6 · Import audio recorded elsewhere

| | |
|---|---|
| **Couples to** | New extension target · `RecordingProtection` · `OfflineAudioRenderer` |
| **Invariant** | Compatible — a file comes in, nothing goes out |
| **Effort** | Medium |

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

| | Item | Verdict |
|---|---|---|
| **D1** | Speaker labels conflated across recordings in one meeting | Fixed |
| **D2** | Raw diarizer turns are not measurable | Implemented |
| **D3** | The `Diarizing` seam cannot accept provider-supplied turns | Evaluate |
| **D4** | A segmentation-first diarizer as a third engine | Evaluate — must earn its keep on collapse-resistance alone, not overlap |
| **D5** | Overlapping speech is not representable | Decided — keep truncating; no engine here has overlap-aware ASR anyway |
| **D6** | Voiceprints never cross meetings | Implemented (standalone; F4 half still open) |

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

## The change that isn't a feature: SPM extraction

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

| Domain | Types that are already pure |
|---|---|
| Fusion and quality | `TranscriptFusion`, `TranscriptQualityFilter`, `TranscriptCorrectionGuardrail`, `ChunkBoundary` |
| Speakers | `SpeakerClusterRefiner`, `SpeakerIdentityMatcher`, `SpeakerTurnSmoothing` |
| Audio decisions | `SpeechLevel`, `PlaybackTuning` |
| Text and data | `MeetingVocabularyExtractor`, `SummaryJSON`, `MeetingFilter`, `MarkdownBlockParser` |
| Security | `SecurityCoverState` |
| Evaluation | All of `KurnTests/Support/Evaluation/` — WER, DER, RTTM, `TextNormalizer` |

Extracted into a `KurnCore` package, these run under `swift test` **on Linux, in
seconds, without a simulator**. A change to transcript fusion or DER scoring
becomes verifiable before the push, by CI or by an agent with no Xcode. There is
no product risk in the move: these types have no platform dependencies today —
the package only makes that boundary enforceable by the compiler instead of
maintained by convention.

One caution to carry into any coverage work that follows: a test plan gathers
coverage for every linked target, third-party dependencies included, which makes
the raw percentage meaningless. Filter to first-party targets before trusting any
coverage number.

## Suggested sequence

Unlike the rest of this document, the numbering here is real — each step makes
the next cheaper or more verifiable.

1. **Extract the pure types into a package.** First, because it speeds up
   verification of everything after it — including the pipeline changes F2
   introduces.
2. **F3 · Frictionless capture.** Lowest effort, immediate value, depends on
   nothing else here. The dispatcher already exists.
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
