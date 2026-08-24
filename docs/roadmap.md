# Roadmap

Fifteen candidate capabilities, each judged against what Kurn is rather than
against what is fashionable: six to adopt, five to evaluate, four deliberately
out of scope, plus one engineering change that is not a feature at all.

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
  identity that survives re-transcription.
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
- **Derived artifacts** — per-meeting wiki articles and cross-meeting generated
  documents.
- **Transcript correction** — opt-in LLM pass with a change-magnitude guardrail
  and vocabulary auto-extracted from the meeting itself.

## Adopt

Ordered by payoff, not by effort. None of the six creates tension with the five
invariants.

### F1 · Apple Foundation Models as a local provider

| | |
|---|---|
| **Couples to** | `Providers/LLMProvider.swift`, `ProviderFactory`, `AIProviderKind` |
| **Invariant** | Closes I1, which the app currently violates in practice |
| **Effort** | Medium-high |

This is the largest gap between what Kurn promises and what it does. Today
`SummaryService`, `MeetingChatService`, `AutoTaggingService`,
`LLMTranscriptCorrector`, `WikiService` and `DocumentGenerationService` all
resolve through `ProviderFactory` to a cloud vendor with an API key. Two
consequences follow: a user who never adds a key gets transcription and nothing
else, and a user who does add one ships the entire transcript of a private
meeting to a third party. The app's central promise is that recordings stay on
the device; everything built on top of the transcript currently doesn't.

The deployment target is iOS 26.0, so `FoundationModels` is available with no
`#available` guard — the same reason the app uses Liquid Glass chrome directly.

**Honest constraints.** These are the reasons this is medium-high rather than
low effort, and skipping them produces a feature that appears to work and then
fails on real meetings:

- **Availability is a runtime fact, not a compile-time one.**
  `SystemLanguageModel.default.availability` depends on Apple Intelligence
  hardware and on the feature being enabled. It must degrade the way a missing
  API key degrades today — a provider that reports itself unusable — rather than
  trapping or silently returning nothing.
- **The context window is small.** A 90-minute meeting does not fit.
  `SummaryService` already map-reduces above `maxSinglePassChars`, but that
  threshold has to become per-provider; for this one it is orders of magnitude
  smaller, meaning many more reduce rounds and a materially slower summary.
- **Not every surface fits.** `answerAcrossLibrary` already operates over
  retrieved passages and works. `answerAboutMeeting` deliberately sends the whole
  transcript because that is more accurate than retrieving fragments — that path
  does not fit and should keep using a cloud provider when one is configured.

**Order of attack.** Start with `AutoTaggingService`: a short excerpt in, a few
labels out, comfortably inside the window, and already opt-in. Then chat over
retrieved passages. Full summarization last, together with the per-provider
map-reduce threshold.

A secondary benefit worth collecting: guided generation (`@Generable`) returns a
typed struct. For this provider the tolerant cleanup in `SummaryJSON.parse` —
markdown fences, outermost `{…}` extraction — becomes unnecessary, and
`AppError.summaryTruncated` stops being a reachable failure mode.

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

The cost is real: OAuth with PKCE, token refresh, a local callback. **Condition:**
sequence this after F1 and reassess. If a local provider already satisfies "works
with no key at all", much of the motivation evaporates.

### F8 · Side-by-side summary variations

Running one transcript through two templates and keeping both. `Meeting.summary`
is a single cascading relationship today, so this is a SwiftData shape change.

The value is narrower than it first appears: wiki articles and generated
documents already exist as separate derived artifacts, covering much of the
"compare different outputs" need. Low priority.

### F9 · Reading mode

Filler-word removal and paragraph reflow for readability. This **cannot be a
pipeline stage**: `TextNormalizer` is explicitly comparison-only, and the stored
transcript keeps its punctuation and casing by design.

So: a render-time transform over `Transcript.segments`, plus an option in
`MeetingExport`. Cheap, pure and testable — a good first candidate for
extraction into the package described below.

### F10 · On-device translation

Apple's `Translation` framework runs entirely on-device with language packs
downloaded on demand. Kurn already transcribes many languages; reading an
English meeting in Portuguese is a real case and the fit with I1 is exact.

The pack download is a heavy dependency, so it goes through I5 — reuse the
`ModelDownloadConsent` pattern rather than fetching independently.

### F11 · Spotlight indexing

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
3. **F1 · Apple Foundation Models, starting with auto-tagging.** Highest payoff.
   The internal order matters: tagging fits the context window, full
   summarization does not.
4. **F2 · Meeting glossary.** After step 1, so the WER effect can be measured
   without waiting on simulator CI.
5. **F4 · Calendar context.** Feeds F2 real names and unlocks cross-meeting
   speaker identity, so it wants F2 in place to pay off.
6. **F5 · Reminders and F6 · Import.** Independent of each other and of the
   rest; slot them in as room appears.
7. **Reassess F7, F9, F10 and F11.** F7 especially: if F1 delivered "works with
   no key", the case for OAuth shrinks considerably.
