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

## Native harness — remaining work

NH00–NH10 and the follow-ups from the 2026-11-14 review against the Swift agent-harness spec are
merged; what they built is described in `CLAUDE.md` ("Agent harness"
and the sections after it), and the contract is `docs/contracts/native-harness-v1.md` with its
machine-checked catalog (`docs/contracts/native-harness-v1.json`, `Tools/check_native_harness_contracts.py`).
Of the contract's 97 items, 57 are verified, 28 are excluded by the local profile (desktop tools, RPC,
gateways, extensions), 10 are partial, 2 are conditional and none is pending. Persistence in SwiftData,
user-supplied keys in the Keychain, provider failures thrown as typed errors and questions without
images are deliberate departures, not gaps.

| Area | Open item | Contract |
| --- | --- | --- |
| Capabilities | Set the `OPENAI_API_KEY`/`ANTHROPIC_API_KEY`/`GEMINI_API_KEY` secrets, dispatch `Live provider smoke` and record its first measurements (first content, first reply text, a 1,000-entry session, concurrency warnings); the workflow, the capability snapshot and alias qualification are done | C04 |
| Reasoning | The chat sends one level (low, medium, high) for every provider: per-model level sets (OpenAI `minimal`/`none`, Gemini 3 `thinkingLevel`), a level remembered per provider, and visible-reasoning qualification on real providers (Responses summaries can need organization verification) | — |
| Usage and cost | Provider-reported cost where a vendor reports one (cache-aware pricing and per-request usage are done) | C17 follow-up |
| Compaction | Branch summaries; checkpoint anchoring for plain (identity-less) history | C10, C13 |
| Run ownership | One owner retained per session across runs; model/provider changes at request boundaries; a `waitingForUser` phase in `AgentRunProgress` while a document replacement waits for confirmation | C24 |
| Interchange | The pi JSONL v3 subset (only with fixtures); exact integers past 2^53 in opaque fields (accepted limitation) | C25, C26 |
| Suspension | Reconcile background/foreground on a device (the release checklist's chat item) | A68 |
| Qualification | Real-transport chunking, Dynamic Type/VoiceOver over a running conversation, migration/stress, Thread Sanitizer on the session/store boundaries, on-device request latency, memory and cancellation latency before any constant is tuned, and the physical-device checklist | A06, A51 |

A18 stays partial by adaptation: Kurn exposes no end/continue hooks, and the loop consults the
queues itself. A23 and A24 stay conditional: they apply only if result-replacement or unanimous-termination
policies are ever exposed. The local profile is complete when this table is empty apart from
accepted limitations and the device checks are recorded.

The remote model catalog (`catalog/model-catalog-v1.json`) is read from the default branch, so it takes
effect only once this work reaches `main`; until then the check gets a 404 and the bundled catalogs apply.

## Knowledge Engine — wiki refactor (K-track)

The per-meeting wiki (`WikiArticle`, `WikiService`, `WikiCoordinator`,
`MeetingWikiView`, Settings → Wiki, the agent's `read_wiki`) is a flat,
regenerate-on-change Markdown note per meeting, reachable only from a meeting's
overflow menu. This track refactors it into a **Knowledge Engine**: a canonical
layer of attributed, evidence-backed, bitemporal assertions and events compiled
from transcripts, with a global wiki, a timeline and a temporal graph as
projections of that one layer, and the agent chat able to query it. The source
is the external *Kurn Knowledge Engine* specification v1.3 (with its v1.1
normative extension, §20), handed over on 2026-11-14 and kept outside the
repository on purpose — the spec itself says not to add a permanent plan
document. This section is the plan; each item moves to `CLAUDE.md`/`README.md`
when it ships, as for every other track.

**Principles carried over from the spec, and how they map onto the filter.** A
meeting is a source, not the unit of knowledge; the unit is an assertion with an
attribution, a modality, evidence and a validity interval. Wiki and graph are
derived from the same canonical revision and never written by independent
pipelines (spec ADR-001). Nothing is committed without validated evidence. The
feature is off on a fresh install and needs its own consent, separate from
`wikiEnabled` (I1, spec ADR-008); canonical records, projections, indexes and
caches all live in the protected store (I2); extraction quality is measured
against a golden set before any claim or auto-merge (I3); the harness stays
read-only (spec ADR-007). The private-corporate boundary of §20.5 — default-deny
egress, policy as the intersection of workspace/source/context/operation,
derivatives inheriting the strictest policy of their evidence, no generic share
sheet — is a hard requirement, not a later hardening step.

**Public material stays synthetic.** Fixtures, screenshots, issues, commit
messages and these docs use fictional organizations and scenarios only (spec
§20); real names may live in a private store, never in the repository or CI.

The architectural decisions — the spec's ADRs and the places where the
checkout makes it bend — are recorded in `CLAUDE.md`, "Knowledge Engine
decisions", together with what K0 has already landed (the flag, the processing
policy, the golden fixtures).

### What happens to the existing wiki

The spec keeps the per-meeting article as the **episodic layer** — a source-level
condensation that can orient extraction, never evidence. So the refactor keeps
`WikiArticle` and its consent, and changes its surroundings:

- **Visible, not in the overflow.** `MeetingWikiView` is split into a content
  view and its sheet wrapper; the content renders inside the new Knowledge mode
  of `MeetingDetailView` (spec §11.2). View/Generate/Regenerate leave the
  overflow except as shortcuts.
- **One job model.** `WikiCoordinator`'s generate/backfill/bulk logic moves
  under the knowledge job queue (`KnowledgeJob`, same states, checkpoint and
  retry rules), so meeting wiki, extraction and projection share scheduling,
  cancellation, the resource scheduler and the circuit breaker instead of three
  ad hoc loops. The `wiki-vN` generator tag becomes the job's pipeline version.
- **Hints, not evidence.** The compiler may read the article and the latest
  summary as orientation; every assertion still cites transcript segments, and
  validation rejects a citation that only exists in generated text.
- **`read_wiki` stays** and gains siblings (below); old turns and scopes that
  name it keep decoding.

### Phases

Small PRs, each behind the disabled-by-default `knowledgeEnabled` flag, each
with its tests, migration where needed, and the docs move on ship (spec §16).
K0 and K1.1 landed through the integration branch `feature/knowledge-engine`; the rest
of K1 lands as PRs into `feature/knowledge-compiler`, which reaches `main` through one
PR that also drops it from the workflow's push list (CI runs on every PR whatever its
base, and on pushes to that branch for a coverage base).
The spec's three stop-for-review gates are kept: **before changing navigation
globally, before enabling any cloud processing, before migrating data.**

| Phase | PRs (one line each) | Gate before the next phase |
| --- | --- | --- |
| **K0 · Groundwork** (K0.1–K0.3 done) | K0.4 baseline: variant A (current hybrid search) and variant B (plain incremental LLM wiki: Markdown pages + index + log, ingest/query/lint) scored on the golden fixtures, with a scorer for the fixture format (assertion precision/recall, refusals honoured, quotes resolvable). K0.5 navigation review selected the Meetings / Knowledge / Ask / Documents root, enabled with knowledgeEnabled; list controls live in the upper menu, a prominent red recorder floats beside the bottom destination capsule, and the DEBUG synthetic launch captures that same layout. Five-mode meeting detail also captured at compact and accessibility sizes | CI green; consent, provenance and schema reviewed; **review gate on navigation** |
| **K1 · Canonical layer** (K1.1–K1.7 backend done) | K1.6 ships the shared ResourceScheduler queue for articles and canonical extraction, with per-recording checkpoints, lease-bound atomic commit, explicit rebuild generations, live source/policy authorization, recording deferral and local-only BG opportunities. Canonical cloud compilation runs only under the provider's automatic grant in the shared cloud-consent ledger; policy/settings/backfill UI remains K2.7. K1.7 adds bounded lexical review candidates and scoped, audited redirect merge/undo APIs. The unavailable external numeric weights are replaced by an explicitly provisional configurable profile (name 0.60, alias 0.15, tokens 0.25); all matching remains review-only, including people. Holdout calibration/automatic linking remains gated on K0.4; the review UI remains K2.6 | Idempotent re-runs; zero invalid citations accepted; no call without consent and policy; **review gate on data migration** |
| **K2 · First user value** | K2.1 backend done: deterministic structured global wiki pages, explicit source authorization and fresh evidence checks, scoped merge-aware views, atomic protected-store publication/outbox and stale-cache refusal. Optional local narrative input is validated against page assertion IDs; invalid output preserves valid pages. Provider execution/automatic admission and reading UI remain with the later K2 composition. K2.2 backend done: local read-only lint for broken typed links, current orphan entities, stale/missing projections, review-only identity candidates and measured segment coverage. Versioned maintenance reports preserve incomplete/unknown states, authorize sources and policy afresh, omit excluded IDs/content and never repair data automatically. Maintenance/review UI remains K2.6–K2.7. K2.3 implemented behind knowledgeEnabled: a fifth meeting-detail mode, inline episodic notes, source-scoped contributions with original attribution/modality/negation, and unique entity/claim/passage header counts. Reads are offline; invalidation/refetch prevents old names/counts after source/access changes or route reuse. Inline note generation is explicitly local-only. Compact and accessibility-size UI previews are attached in CI; the global navigation prototype/gate remains K0.5. K2.4 scoped reader implemented: Knowledge Home, entity Overview/Sources, evidence detail → cited source transcript and explicit recording-relative audio. Fresh source/context authorization gates metadata, quotes, transcript and playback; route/store/feature/scene changes invalidate content and stop audio. Meeting entry stays source-local. The reviewed four-tab root adds Knowledge Home with an explicit, bounded 1–16 meeting picker, the existing library Ask conversation and saved Documents. Library/filters/sort/multi-selection stay in the upper menu; tab changes retain meeting controls. Wider-layout and physical-device validation remain open. K2.5 local search implemented for the current page/alias/assertion corpus: explicitly scoped, disposable typed documents share BM25/RRF with transcript retrieval; literal/name matching and accent folding work offline without assets. Optional dense ranking uses installed on-device assets only, embedding policy and fresh admission/publication checks, with full-corpus lexical fallback. Search results open ID-only reader/evidence routes, cancel stale queries and clear on source/policy changes. Event documents follow the validated temporal reader in K3; no schema migration or persistent embedding cache is introduced. K2.6 scoped Review inbox implemented for current canonical data: explicit identity candidates → keep separate/reopen or confirmed merge, with source-preserving merge history/undo; every decision rechecks scope, revision, live policy and origins. Exact opposing-claim hints and stated month precision link to freshly validated passages; invalid/stale evidence is hidden behind an inspection warning. Hints remain inspect-only; temporal/event conflict resolution follows K3. No automatic linking or claim/date rewriting is enabled. K2.7 local Settings → Knowledge implemented: independent on-device processing, enable, opt-in automatic compilation for future transcripts, durable scope/exclusions, canonical-only pause, explicit bounded backfill preview/confirmation with local provider-fee estimate, optional explicit recompilation generations, page rebuilding without a model and measured segment coverage. Unknown/corrupt preferences fail closed; scope changes revoke readers and pending publications. Existing pending approved work can resume independently of the future-transcription toggle. Cloud/provider consent remains gated; corporate-policy editing is not introduced. K2.8 deletion implemented: tombstones committed with meeting/transcribed-recording deletion and a durable corpus tombstone behind Settings → Delete Knowledge; one-transaction purge of exclusive canonical rows, provenance, reviews and page caches with a revision bump, resumed at launch/activation/save after a failure or process death; `LibraryEraser` already erases every row. Recording deletion purges the whole meeting's knowledge for recompilation. Physical-device validation of a kill mid-purge remains a release check | Meeting → topic → evidence navigable; reads work offline; deletion verified to leave nothing exclusive behind |
| **K3 · Time** | K3.1 done: KurnCore `KnowledgeTemporalReducer.state(of:validAt:knownAt:claims:)` with half-open valid and transaction time, precision-aware possible/definite, valid-time-only ordering of single-valued predicates, unordered values and contradictions surfaced as conflicts, and order-independent output; exact on the `pt-provisioning-timeline` fixture (status progression, late-arriving blocker). Not yet wired to the store or any reader; an explicit `validTo` on a later status does not yet end an earlier one. Spec §6 / §16.1 step 7 fixtures still to add with K3.2. K3.2 done: KurnCore `KnowledgeLifecycle` decision/action/risk machines projected from known status claims (and `supersedes` for decisions), ordered by stated time with lifecycle-resolved overlaps, invalid/ambiguous/out-of-vocabulary anomalies and set-aside tentative/negated/undated claims; exact on the provisioning and platform-review fixtures; not yet wired to the store, so `KnowledgeEvent` rows are not yet written from them. The spec §6 / §16.1 step 7 fixtures (the specification is not in the repository) remain to be added. K3.3 done: a scoped Timeline in the Knowledge reader (KurnCore `KnowledgeTimeline`) placing each claim by its stated month at its own precision, with the meeting it came from and the date it was recorded beside it, an unknown-date section in recorded order, kind/tentative/negated filters, lifecycle anomalies on the claims they name and ID-only evidence links; offline, no new storage. Context lanes on iPad remain open (the read carries no per-claim context yet), as do as-of (known-at) navigation and wider-layout/device checks. K3.4 done: "Compare dates" on an entity page (KurnCore `KnowledgeStateComparison`), the reducer's state at the end of two picked days lined up as changed/started/ended/unchanged with certainty shifts, optionally as known on each date, from the reader's authorized pages; offline, no new storage. Comparing two transaction times on the same valid day has no dedicated UI yet. K3.5 done: "Revised later" on an entity page (KurnCore `KnowledgeLateArrival`), the state as known just before and at each later transaction time compared only over the valid interval it changed, split where the change differs, counted late only when it changes days before its recording day; offline, no new storage. A timeline marker for late claims and written `KnowledgeEvent` rows remain open | Bitemporal snapshots exact on fixtures, including the spec §6 example and §16.1 step 7 |
| **K4 · Graph** | K4.1 done: KurnCore `KnowledgeGraphIndex` over the reader's authorized pages, bounded BFS (default depth 1, 40 nodes, 80 edges, clamped to depth 2), predicate/tentative/negated filters, truncation flag + frontier, `supersedes` cycles reported (Tarjan); the app's `KnowledgeGraphQueryService` caches the index and recent answers keyed by revision, meetings, policy revision and the pages themselves. No UI yet. K4.2 done: KurnCore `KnowledgeGraphLayout`, a force-directed layout deterministic by node ID and seed (SplitMix64, ID-ordered, fixed steps), with fixed positions kept; the query service caches one layout per answer and keeps shown nodes where they were as the neighbourhood grows. K4.3 (relationships mode) done: Graph Explorer opened from an entity page, drawn on `Canvas` with a hit-testing overlay of node buttons, list alternative (default under VoiceOver), recentring, depth/tentative/negated/inferred filters with inferred edges off by default, exploration kept across graph ↔ page navigation, accessibility audit in `MeetingKnowledgeUITests`. K4.3 On a day (evolution) and Compare modes done: KurnCore `KnowledgeGraphTimeline` (K3.1 reducer per edge source), edges that did not hold hidden, plus/square/ring marks with words, days kept in the exploration. K4.3 Contexts (lanes) mode done: the read carries each meeting's context, one lane per context in kind order (unknown last), nodes in their main lane keeping their x, every row and node label naming its context. K4.3 done | Graph ↔ wiki keeps selection; spec performance targets met on a physical device; accessibility audit added |
| **K5 · Ask over knowledge** | K5.1a done: `search_knowledge`, `get_entity`, `get_timeline`, `get_evidence`, offered only when the default-deny policy authorizes `answerSynthesis` for the run's provider with the person's consent (for a cloud provider, its on-request grant in the shared cloud-consent ledger), re-authorized after every read. K5.1b done: `resolve_entity`, `get_graph`, `compare_state`, `list_open_actions`, `list_contexts`, `get_context` over the same read. K5.1c done: `get_coverage`, the K2.2 per-recording examined-segment counts and states grouped by meeting, content-free and authorized before and after its own read. Remaining K5.1 tools `get_wiki_page` (waits for generated narratives), `trace_influence` (semantics undefined) — read-only, host-authorized, compact text, citations resolved by the host. K5.2 done: a `knowledge_policy` system-prompt section, only when the knowledge tools are offered, sends the model to knowledge first and to `get_coverage` plus the transcript tools for gaps. K5.3 done: `ChatSourceScope` has a knowledge part that gates the knowledge tools per meeting; Ask from an entity page opens a conversation scoped to its source meetings. K5.4 benchmark variants C–F against A/B | Measured gain over the baseline on the holdout; historical answers correct; no excluded source leaks through results, snippets, counts or errors |
| **K6 · Hardening and release** | K6.1 egress audit (zero unauthorized egress in tests, including caches, embeddings and counts). K6.2 authorized internal export bundle, off by default. K6.3 performance on 100/1k-meeting fixtures (spec §14 targets are goals, not measurements). K6.4 localization, release checklist items, the knowledge components and their egress boundary added to `SECURITY_MODEL.md`, docs moved into `CLAUDE.md`/`README.md` | CI green, privacy audit, physical-device checks, coverage floors held |

The first phase a user sees is **K2**; the graph waits behind the timeline on
purpose (spec ADR-006). The spec's numeric targets — decision precision ≥ 90%,
recall ≥ 80%, auto-merge precision ≥ 98%, 100% resolvable citations, zero
cross-scope leaks, the p95 latencies — are proposals to calibrate, not results;
auto-merge does not ship until its target is met on the holdout.

### Open questions (none blocks K0)

Retention of corrected transcript revisions and its storage cost; the
five-mode segmented control at compact width and large Dynamic Type (fallback:
an Insights mode holding Summary | Wiki | Contributions); whether Documents
keeps its own root destination; which remote provider, if any, a corporate
policy authorizes; whether a `@ModelActor` writer on the shared container
contends with the main context under a long backfill; the maximum store growth
acceptable on device.

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

The correction stage's topic critique (`TranscriptTopicAnalyzer`) now covers
the part of this that inference can: a critic pass names domain terms the ASR
garbled every time, grounded in the transcript. It cannot know a name that
nothing in the meeting implies, and it acts only after ASR — so a
user-maintained list remains the way to reach both, and to feed the decoder.

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

### D4 · Retire sherpa-onnx, and decide on Nemotron 3

`.sherpaOnnx` shipped as an opt-in, segmentation-first diarizer whose only
justification was surviving the failure `FluidAudioDiarizer` is known for —
VBx collapsing a meeting into too few speakers. Read per file
(`docs/pipeline-evaluation.md`, "D4 per file"), it never does: on the one
recording where Pyannote collapses (VoxConverse `0000`, 81 s confused) it
confuses more (112 s), and it trails Pyannote on 7 of 8 files. The decision
left is removal: the engine, its download and consent flag
(`sherpaOnnxModelsConsented`), the Storage row and the matrix axis.

Nemotron 3 (`.fluidAudio` + `.nemotron3`), added since, is what does recover
that file (0 s confused; raw DER 1.39% against Pyannote's 10.61% over the four
VoxConverse files, same run). On AMI (2026-11-03) the picture splits: raw DER is
worse (28.26% against 18.08%) because it misses twice the speech, but it
confuses less than half as much, so the transcript a user reads is better
attributed (cpWER ~25% against ~33%), and it fixes Pyannote's worst meeting
(`EN2002a`). **Decision left:** whether that is worth its costs as the default —
it is ~2× slower, caps at eight speakers, and returns no voiceprints, so
choosing it gives up voice-based speaker identity (CLAUDE.md, "Speaker
identity"). A Settings choice, with Pyannote staying the default until the
voiceprint gap is closed, is the conservative reading.

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

## UI simplification and accessibility (U-track)

Goal: fewer decisions per screen, with no regression in the HIG, WCAG 2.2 AA or
the Accessibility Nutrition Labels. The baseline below was measured on the
tip of `claude/sweet-hamilton-g6ae6c` (merge of PR #444, 2026-11-20; iOS 26 deployment target)
and rechecked on `feature/knowledge-compiler` (PR #452, 2026-11-21: K5.1 `get_wiki_page` and
`trace_influence`, K6.1 egress audit, K6.2 export, page narratives). That branch added
no fixed fonts, `lineLimit(1)`, fixed heights or unwrapped animations, so every count
below is the same on both; what it added is listed under "New surface". The external
specification this track follows targets iOS 27 / Xcode 27 and cites WWDC26
material; those APIs and the session-220 patterns are **not verified here**.
Each U-phase that depends on one starts by checking Apple's documentation, and
the iOS 26 floor in `CLAUDE.md` stays until a deployment-target change is
decided separately. `UIDesignRequiresCompatibility` is not set anywhere, so
there is nothing to remove for the iOS 27 SDK.

### Baseline (what the code does today)

| Area | Measured | Reading |
| --- | --- | --- |
| Liquid Glass layering | one `.glassEffect` (`RecordingMiniBar`, a control) | Matches the control/content split; no content surface uses glass |
| Contrast | `Theme.textTertiary` is white at 30% in dark: **2.45:1** on `#0A0A0F`/black and 2.71:1 on `#1C1C1E`; used in **71** places | Fails 4.5:1 for text; `textSecondary` (50%) passes at 5.2–5.3:1 |
| Contrast | white on `Theme.accent` 3.55:1, on `Theme.info` 3.65:1 | Documented exception (bold ≥ 14 pt); keep it bold and never shrink it |
| System display settings | 0 reads of Reduce Transparency, Increase Contrast, Differentiate Without Color, Button Shapes, Smart Invert | Only native controls adapt; custom cards, chips and the mini bar do not |
| Dynamic Type | 17 `.font(.system(size:))` in 10 files; 19 `.lineLimit(1)` in 14 files; 9 fixed `.frame(height:)` in 4 files; 5 `GeometryReader`; 0 `minimumScaleFactor`, 0 `scrollDisabled(true)`; `ViewThatFits` in 1 file, `AnyLayout` in none | Several fixed sizes are legitimate (recorder timer, 6 pt bullets); the chips, rows and `MeetingDetailTabs` heights are not |
| Motion | `accessibilityReduceMotion` in 7 files, `kurnAnimation` in 10; 5 `withAnimation` and 4 `.animation(` calls outside it | Unaudited call sites |
| VoiceOver | 90 `accessibilityLabel` in 37 files; 5 `isHeader`; 1 adjustable action; 0 rotors, 0 `AccessibilityNotification`, 0 `AccessibilityFocusState`, 0 `accessibilityInputLabels` | Icon-only controls are labelled (lint enforces it); structure, focus and error announcements are not |
| Voice Control | Three menu rows use the `ellipsis` glyph as a "generating" label; the detail toolbar's menu is labelled "More options" | The glyph is not a name; the menu label is ambiguous beside the chat menu's `ellipsis.circle` |
| Automated audits | `performAccessibilityAudit(for: [.sufficientElementDescription, .trait])` only; `continueAfterFailure = false` | `.contrast`, `.dynamicType`, `.hitRegion`, `.textClipped` never run; the first failure hides the rest |
| Complexity | Meetings list: 10 controls with Knowledge on; detail overflow menu: up to 10 conditional rows; detail modes: 5; Settings hub: 15 rows; `TranscriptionSettingsView`: 13 controls | The simplification targets |

**New surface from `feature/knowledge-compiler`** (all in the Knowledge reader and Settings):

| Surface | What it is | What the track must cover |
| --- | --- | --- |
| Entity page "Notes" | Generated narrative paragraphs under a `KnowledgeSectionLabel` (already a header), one `DisclosureGroup` per paragraph ("Based on N claims"), a footnote saying the text is generated | Audit at AX5; the disclosure label must read the paragraph it belongs to (U4.1); keep the generated-text note in `textSecondary`, never `textTertiary` (U2.1) |
| Reader toolbar | Up to four `.primaryAction` icons (Review, Export when allowed, Refresh) beside the source picker | The same crowding as the meetings list: icon-only share glyph, `accessibilityInputLabels`, hit region; decide which stay in the bar (U1.7) |
| Export (JSON) | `fileExporter` save sheet, a failure alert, an opt-in toggle in Settings → Knowledge that re-authenticates | Add to the common-task list; the alert and the save sheet are system components (Inherit); Settings → Knowledge now has 6 toggles/pickers, which U1.4's merge must not grow |
| Ask | 12 knowledge tools (`get_wiki_page`, `trace_influence` new); `ChatStepPresentation` has no entries for any of them | Check what the step timeline says for a knowledge tool call (generic wording, localized, no raw tool name) and add the words in all seven locales (U1.6) |
| Strings | 6 new keys in all 7 locales | Already enforced by CI; no action |

### U0 · Measure before changing (1 sprint)

1. Widen the audit to `[.contrast, .dynamicType, .hitRegion, .sufficientElementDescription, .textClipped, .trait]`
   on the screens `AccessibilityAuditUITests` and `MeetingKnowledgeUITests`
   already seed, with `continueAfterFailure = true` in the audit tests only
   (flows keep `false`). **Run it outside the required check.** The existing
   audit and flow suites are in the required `ui-accessibility-tests` shards,
   so widening them would turn the first measurement into a blocked PR. Put
   the widened audit in its own test class (`AccessibilityBaselineUITests`),
   skip it in `swift.yml` with a `-skip-testing` line and run it from its own
   job in `reliability-hardening.yml` (on demand and weekly). Add the same
   `-skip-testing:KurnUITests/AccessibilityBaselineUITests` line to the
   `ui-flake-rate` job, which runs all of `KurnUITests` except the screenshot
   suite: known accessibility failures must not count as flakes.
   It joins the required shards in U5, once its findings are fixed. The
   `.xcresult` is already archived on failure by `collect-failure-diagnostics`
   (14 days); nothing to add. First run is a measurement: record the findings
   here, do not fix inside this step.
2. Add a launch argument (DEBUG, `UITestLaunchOptions`) that sets a content size
   category, so one seeded run audits at default and at `accessibilityExtraExtraExtraLarge`
   (AX5). This closes the "no automated check at large text" gap.
3. Bring `RecorderView` and `FolderFormView` into the audit (existing gap), and
   the entity page with a seeded narrative and the reader toolbar with export on
   (`MeetingKnowledgeUITests` already seeds a synthetic canonical store).
4. Write the **common-task list** (record and stop; find a meeting; read a
   summary; ask a question; export a meeting; export Knowledge; read a generated
   note and open its claims; change provider; delete) as
   `docs/release-physical-checklist.md` rows. Nutrition Labels may only be
   declared for features completed end to end on a device with VoiceOver and
   Screen Curtain, then Voice Control alone.
Exit: a dated findings table per screen; no code behaviour changes.

### U0b · Consistency and usability audit (1 sprint, before U1)

U1 reduces controls; this step decides whether the screens are also coherent and
learnable. The findings below come from reading the code and counting patterns
on `feature/knowledge-compiler`, **not from using the app**: each one is a
hypothesis to confirm on a device before it becomes a change.

**Findings so far**

| # | Finding | Evidence | Direction |
| --- | --- | --- | --- |
| F1 | One idea, three names: the meeting's condensed article is "Wiki" (menu "View wiki", sheet "Meeting Wiki", Settings → Wiki), the cross-meeting facts are "Knowledge" (tab, Settings, reader), and the generated paragraphs on an entity page are "Notes" (reads as the person's own notes) | `detail.wiki.*`, `tab.knowledge`, `knowledge.browser.narrative` | Keep "Wiki" for generated pages and "Knowledge" for the facts under them; retire "Notes" (rule 4 below) |
| F2 | Ask and Chat are the same conversation under two names: root place "Ask", meeting tab "Chat", entity button "Ask about this"; two glyphs for it (`bubble.left.and.bubble.right` in `AppRootDestination` and `DocumentDetailView`, `bubble.left.and.text.bubble.right` in the list toolbar and `MeetingDetailMode`) | `AppRootDestination.swift`, `MeetingDetailMode.swift`, `MeetingsListToolbar.swift` | One name ("Ask") and one glyph, defined once |
| F3 | `book.pages` means Knowledge (place, tab, Settings, reader rows) and also "Generate wiki" in the detail menu | `MeetingDetailToolbar.swift`, `AppRootDestination.swift` | One glyph per concept; give the wiki action its own or drop it with the F1 rename |
| F4 | The place a thing lives depends on a setting: with Knowledge loaded the wiki moves from the overflow menu to the Knowledge tab; the list toolbar has two layouts | `CLAUDE.md` "Meeting detail Knowledge mode"; `browsingToolbar` | One home per action regardless of flags (U1.1 for the list; same rule for the detail menu) |
| F5 | Three presentation models in one bottom bar: Knowledge and Ask open as sheets, Documents is pushed, Library is a sheet or a sidebar | `MeetingsListView`, `KnowledgeLibraryDestination`, `DocumentsListView` | Decide one model per destination type; the mini-bar plumbing (`hostsRecordingMiniBarInSheet`) is a cost of mixing them |
| F6 | 58 `.sheet` in 32 files but only 12 `presentationDetents`; `Theme` says utility pickers open at `.medium` | `grep` over `Views/` | List every sheet with its detents and its Cancel/Done; fix the full-height ones that hold a short choice |
| F7 | `.buttonStyle(.borderless)` is used 16 times (13 in Settings Health/Storage) and is not in `Theme`'s "Button language" table | `grep` | Probably legitimate (several buttons inside one Form row); add it to the table with that reason instead of migrating |
| F8 | Delete is spread over 14 trash glyphs, 21 destructive roles and 8 swipe actions | `grep` | Check each goes through `kurnDialog` and says what is deleted; add undo where the data model allows it (the cognitive-accessibility rule) |
| F9 | 11 `ContentUnavailableView` empty states in 9 files, consistent with the convention | `grep` | Confirm each offers the next action, not only a description |

**Conformity check of every button, menu and screen (static, 2026-11-21)**

Scripted greps and reads over `Kurn/Views` and `Kurn/ViewModels` against
`Theme.swift`'s "Button language" and "Modal weight", the HIG tap-target and
layering rules and the accessibility rules in `CLAUDE.md`. It finds what the
source shows; it does not replace the device pass (U5), and it does not check
contrast of composited surfaces, the single-primary-action rule per screen, or
VoiceOver order.

| # | Result | Where | Fix (phase) |
| --- | --- | --- | --- |
| G1 | **Destructive action with no confirmation, three places.** Swipe-delete of an attached PDF; "Clear wiki" (costs paid LLM calls to regenerate); "Clear index" (local, rebuildable). The summary delete does confirm (`pendingDeleteSummary`) | `MeetingDetailAttachments.swift:38`, `WikiSettingsView.swift:97`, `SemanticSearchSettingsView.swift:61` | `kurnDialog` naming what is lost and what regenerating costs, or, only after the retention design in rule 6, undo (U1) |
| G2 | **Tap targets under 44 pt with no `contentShape`:** pause, stop and the other transcription controls in recording rows (30 pt, 5 places) and the 34 pt play button; photo-capture controls (36–40 pt); a 36 pt control in `DesignComponents`; 32–40 pt swatches in the folder form and template editor | `RecordingSegmentRow.swift:42,105–167`, `PhotoCaptureView.swift:153,215,290`, `DesignComponents.swift:212`, `FolderFormView.swift:53,101`, `TemplateEditorView.swift:22` | Keep the glyph, extend the hit area to 44 × 44 with `contentShape` and padding; the audit's `.hitRegion` should then pass (U3.4) |
| G3 | **System colours instead of tokens for status:** `.green`, `.red`, `.orange`, `.yellow` in Storage, Health, the language picker and photo capture, although `Theme.success` and `Theme.warning` exist. Those two tokens are only 1.9:1 and 2.1:1 on white (8.9:1 and 8.3:1 on `#1C1C1E`), so as light-mode icons they fall under the 3:1 non-text minimum; the status glyphs also carry a symbol, so colour is not the only cue | `StorageSettingsView.swift:278,290,302`, `HealthRecoveryView+Sections.swift:154,184`, `StorageSettingsSections.swift:101`, `LanguagePickerRow.swift:24`, `PhotoCaptureView.swift:289` | Route through `Theme` and give success/warning light-mode variants that reach 3:1 for glyphs and 4.5:1 for text (U2) |
| G4 | **Sheet size:** about 59 presentations, and only 12 files set `presentationDetents`. Short forms with none: filter bar, tag editor, tag merge, folder form, folder picker, knowledge meeting selection, chat source sheet. Settings or call sites may set them elsewhere, so confirm each on a device | `FilterBarView`, `TagEditorView`, `TagMergeView`, `FolderFormView`, `FolderPickerView`, `KnowledgeMeetingSelectionView`, `ChatSourceSheet` | `.medium`/`[.medium, .large]` per "Modal weight" (U1, rule 8) |
| G5 | **Sheet chrome to confirm:** `TranscriptionSettingsView`, `MeetingChatView` and `MeetingWikiView` are presented as sheets but their own files hold no `NavigationStack`; the host may supply it | those files | Confirm each has a title and an explicit Cancel/Done on a device (U0b.1) |
| G6 | **Button styles in use:** `.plain` 85, `.borderless` 16, `.glassProminent` 12, `.bordered` 9, `.glass` 4. `.borderless` is outside the table; whether each screen has exactly one prominent action was not checked | `grep` | Add `.borderless` to the table with its reason; check one prominent action per screen in the pattern table (U0b.1) |
| G7 | **Menus:** 29. Only the meetings list toolbar was read for labels. The detail overflow menu is "More options" (ambiguous for Voice Control) and uses the `ellipsis` glyph as a loading label three times | `MeetingDetailToolbar.swift` | Name by content, `ProgressView` for loading, `accessibilityInputLabels` (U1.2, U4.4) |
| G8 | **Passes:** no unlocalized literal titles in `Label`, `Button`, `Toggle`, `Section`, `NavigationLink` or `navigationTitle` (the 14 bare `Text("\(n)")` are numbers); Liquid Glass appears only on the recording mini bar (a control); 11 empty states use `ContentUnavailableView`; section labels carry `isHeader`; the lint rules for labels and traits are errors in CI | `grep` | Keep; the static policy should stop a regression |

**Recommendation register** (what to do, in order; each maps to a phase above)
1. U0 and U0b: widen the audit, audit at AX5, add the missing screens, and run the
   walkthrough with the table above as the starting list.
2. G1 first: it is the only finding that can lose user data or money.
3. U2: fix `textTertiary` (2.45:1), route status colours through `Theme` with
   light-mode variants (G3), add the display-setting tokens.
4. U3: hit areas (G2), then the fixed fonts, `lineLimit(1)`, fixed heights.
5. U1: one list toolbar (Select stays a button, Sort into Filter), menu and
   Settings reductions, sheet detents (G4), the vocabulary (Wiki, Knowledge, Ask;
   no "Notes") and one icon per concept.
6. U4: structure, announcements, Voice Control labels, motion.
7. U5: device certification before any Nutrition Label is declared.
8. Static policy: reject a duplicate catalog glyph, a bare `withAnimation` in
   `Views/`, a destructive role with no confirmation, and a raw system status
   colour in `Views/` (each as its own rule, with a baseline that only shrinks).

**Work**
1. **Pattern table per screen** (meetings list, meeting detail and its five modes,
   recorder, Ask, Documents, Knowledge reader, Settings screens): primary
   action, secondary action, destructive action, presentation (push / sheet /
   dialog), dismissal, empty state, error state, Inherit / Adapt / Own. Any cell
   that differs from `Theme.swift`'s "Button language" and "Modal weight" is a
   finding.
2. **Glossary and icon catalog.** One table of user-facing terms (Meeting,
   Recording, Transcript, Summary, Wiki/Notes, Knowledge, Ask, Document,
   Library) with the chosen word in seven languages, and one place that defines
   each concept's glyph (extend `AppRootDestination`'s pattern) so the tab,
   toolbar and destination cannot drift. A static-policy check rejects the same
   `systemImage` literal for two catalog concepts.
3. **Task baseline.** For each common task, count taps and screens as built, then
   set a target. Estimates from the code, to be measured: start recording 1 tap
   from the list; sort by duration 2 taps today and 3 after U1.1 folds Sort into
   the Filter sheet (a cost U1.1 must accept or avoid, for example by keeping the
   sort choice as the first row of that sheet); ask a question 1 tap to open;
   read a meeting's wiki 2 taps with Knowledge off and 1 with it on (F4);
   export a meeting at least 4.
4. **Expert review instead of user sessions.** There are no participants, so the
   evidence is a structured review: a cognitive walkthrough of each common task
   (at each step: will the person know what to do, see the control, link it to
   their goal, and see progress), scored against Nielsen's ten heuristics and the
   HIG principles with a 0–4 severity scale, by two reviewers (the maintainer and
   Claude, independently, then reconciled). Then a one-week dogfood: the
   maintainer does the seven tasks daily on a device, with screen recording
   for the first run, and logs hesitations. The app has no analytics by design
   (local-first), so nothing is measured remotely; TestFlight feedback is the only
   outside signal. A review finds likely problems, it does not prove the
   fixes help: treat every U1 change as a hypothesis and keep it small enough to
   revert.
Exit: findings table confirmed or dropped on a device, a signed-off glossary and
icon catalog, a task baseline, and U1's order set by the review's severity scores.

### Design proposal (best practices, no user data)

Built from widely documented patterns in apps known for being simple (Apple
Voice Memos, Notes and Files; Things; Bear; and meeting tools such as Otter and
Granola, which lead with the outcome rather than the recording). This is
reasoning from how those apps are generally understood, not a measurement of
them or of Kurn's users; none of it is verified against their current versions.
Each rule names the Kurn evidence it answers.

1. **One obvious thing per screen.** The meetings list is for finding and
   starting; the one prominent control is Record (already true). The detail
   screen exists to read the outcome. *Answers F4, F5.*
2. **Outcome first.** Meeting detail always opens on Recordings
   (`@State tab = .recordings`). Open on Summary when one exists, else on
   Transcript, else on Recordings with its progress. People return to a meeting
   to read what was decided, not to replay audio. Keep the last chosen tab per
   meeting. *Answers the mode-count problem without removing a mode.*
3. **A small app until the person opts in.** With Knowledge off (the default)
   the app is Meetings, Ask and Documents: three places and Record. Knowledge
   appears as a fourth place only when switched on, and never changes where
   anything else lives (U1.1). Settings shows Knowledge as one row with its
   toggle, not its controls, until it is on. *Answers F4.*
4. **Plain words, one per idea; "Wiki" stays.** "Notes" reads as something the
   person wrote, and the generated article is not that, so it is not used.
   "Wiki" is the product's own term (an LLM-maintained wiki: generated,
   cross-linked pages over what was said) and stays. The rule is one meaning
   per word, to be confirmed in the expert review and in all seven languages:
   **Wiki** for every generated page (a meeting's page and an entity's page);
   **Knowledge** for the place that holds the evidence-backed facts those pages
   are built from, and for those facts; **Ask** for every conversation (the Chat
   tab becomes Ask). The entity page's generated paragraphs, today headed
   "Notes" (`knowledge.browser.narrative`), are headed **Wiki** and keep
   their "generated from the claims below" note. First use explains it in one
   line ("A wiki the AI writes from this meeting") instead of assuming the
   reader knows the term. Avoid internal terms (compile, canonical,
   projection, harness) in any visible string. *Answers F1, F2.*
5. **Show state, do not ask about it.** Each list row says what is happening to
   the meeting (recording, transcribing, summarizing, done, needs attention) in
   words and a symbol, and tells what the person can do next. Progress and
   failure copy follow "what happened, what it means, what to do"; errors that
   have a fix already offer it (`ErrorRecovery`). *Builds on U1.6.*
6. **Confirm what is lost now; undo only once something is retained.** Today's
   trash is not a "Recently deleted" folder: `RecordingOperationJournal` moves
   files aside only so a failed save can restore them, and purges them as soon
   as the save commits. So there is nothing to restore later. Until that
   changes, every destructive action names what is lost (and what regenerating
   costs) in a `kurnDialog` (G1). A visible "Recently deleted" is a separate
   design, not a UI tweak: a retention window for the audio, photos and
   attachments, a snapshot of the rows needed to restore a meeting (recordings,
   transcript, summaries, speakers, tags), restore in the library, space shown
   in Storage, purge on expiry, and an exception path for "Delete all data",
   `LibraryEraser` and the Knowledge deletion tombstone, which must still erase
   everything. It also keeps meeting content on the device longer, which the
   privacy model must accept first. Track it as its own roadmap item before
   promising it. *Answers F8.*
7. **Defaults that work, advanced behind a door.** Presets for Transcription
   (U1.5) and, in the same spirit, one-line summaries under each Settings row
   ("Apple Speech, on this device") so the hub reads as the current setup, not
   as a list of topics. *Answers the Settings count.*
8. **Predictable modality.** Sheets for short tasks that return to where the
   person was (pick, edit, confirm), pushes for going deeper (a meeting, a
   document, an entity), a full-height sheet only for a long task (Ask). Every
   sheet has an explicit Cancel/Done and the right detent. Knowledge reader and
   Documents are "deeper" and should push; Ask is a task and stays a sheet.
   *Answers F5, F6.*
9. **Consistent glyph, label and place for an action everywhere** (the catalog in
   U0b.2): Share is always `square.and.arrow.up`, an overflow menu is always
   named for its content, destructive actions are always red and last.
10. **Respect the system.** No custom chrome, native `Form`, `ContentUnavailableView`,
   toolbars and sheets, so Dynamic Type, Voice Control and the Liquid Glass
   settings keep working with no extra code (the Inherit tier).

What this deliberately does not propose: onboarding tours, tooltips, gamification
or in-app analytics. The first run should need none of them if rules 3 and 5
hold; if the review disagrees, add one empty-state call to action rather than a
tour.

### U1 · Simplify the structure (2 sprints)

Each item is a product decision first; the control/content layering and the
existing identifiers (`nav.settings`, `meetingCard`, `settings.link.*`) must
survive. Items that revisit a `CLAUDE.md` decision are marked **review**.

1. **Meetings list toolbar: one layout with Knowledge on or off (review).**
   Today `browsingToolbar` switches between two layouts (top: Select, Sort,
   Settings or Library, Filter, Sort, Select, Settings; bottom: Library,
   Filter, Ask, Documents or the four places). Replace both with one:
   - **Top:** Library, Filter (Sort moves into its sheet), Select, then a fixed
     spacer and Settings. Select stays a button; a long press is not
     discoverable and is harder with VoiceOver and Voice Control.
   - **Bottom:** Ask, Documents, and Knowledge only while it is on, then the
     flexible spacer and Record. The "Meetings" place exists only to mark the
     current screen among four, so it appears with Knowledge, never alone.
   The top bar is then identical in both states and has four controls instead
   of five, so the Knowledge-on bar is no longer the crowded one. This reverses
   part of the K0.5 "each control open in the bar" choice, so it needs that
   review and the U0b walkthrough (task: "sort by duration"). Identifiers
   (`meetings.library`, `meetings.filters`, `nav.settings`,
   `root.destination.*`) stay, so flows change their path, not their handles.
   **Icon size and spacing stay the system's.** No frame, font or
   `imageScale` on the toolbar icons and no custom spacing: the glass group
   sizes them, they scale with Dynamic Type and keep the 44 × 44 pt hit area.
   The bar gets lighter by having fewer items, not by shrinking them.
2. **Meeting detail overflow menu.** Group the up to 10 rows into three
   `Section`s: *Create* (title, wiki, tags), *Manage* (edit, add PDF, share) and
   *Reprocess* (re-transcribe); replace the `ellipsis` "generating" glyph with a
   `ProgressView` label; rename the menu to name its content ("Meeting actions")
   and give it an `accessibilityInputLabels`.
3. **Detail modes.** Keep Recordings / Transcript / Summary / Chat; decide
   whether Knowledge (off by default) stays a fifth segment or moves into the
   Summary tab's footer. Measure with the segmented control at AX3, where five
   segments cannot fit one row.
4. **Settings hub 15 → 9 rows.** Privacy & Cloud first (it is the consent
   surface). Merge Wiki into Knowledge (already planned: "Settings → Wiki
   becomes Settings → Knowledge"), Search into Library, and Usage, Health and
   Diagnostics into one *Health & diagnostics* screen. Keep the old
   `settings.link.*` identifiers on the destinations so the flow UI tests only
   change their path, not their handles.
5. **Transcription settings: presets plus Advanced.** Offer *Recommended*,
   *Most accurate* and *Fully offline* above the 13 controls, which move under a
   collapsed Advanced `DisclosureGroup`. A preset writes the same `AppSettings`
   properties; no new persisted engine IDs.
6. **One words-pass.** Short sentences, error messages that say how to fix the
   problem (`AppError` descriptions first), one name per concept (wiki /
   Knowledge / documents), and the Ask step timeline's wording for the knowledge tools. Use the `design:ux-copy` skill; all seven locales,
   enforced by the existing localization check.
7. **Knowledge reader toolbar.** Source picker, Review, Export (when allowed)
   and Refresh sit in one `.primaryAction` group. Keep Review and the source
   picker visible; move Refresh and Export into one titled menu ("Knowledge
   actions", never "More") or give each a distinct `accessibilityInputLabels`
   set. Export keeps `fileExporter` and its re-authentication; no generic share
   sheet (the private-corporate boundary in `CLAUDE.md`).
8. **Knowledge settings.** After the K-track merge (Wiki into Knowledge) the
   screen must not exceed one screen of controls at default size: group
   extraction, controls and export under collapsed sections, and keep the
   safe-reset and consent copy visible.
Exit: the common-task list needs equal or fewer taps than before, measured by
the UI flows; nothing removed that the flows or the roadmap rely on.

### U2 · Contrast and display settings (1 sprint)

1. **Fix `Theme.textTertiary`** for text: dark ≥ 4.5:1 on both backgrounds
   (about white at 62%), light stays `tertiaryLabel` only for non-text
   decoration. Split a `Theme.decorationTertiary` for the places where 2.5:1 is
   acceptable (disabled chevrons, dividers), and migrate the 71 uses by hand:
   anything a user must read moves to `textSecondary`.
2. **Central environment tokens.** Add `Theme` modifiers reading
   `accessibilityReduceTransparency` (opaque `Theme.surface`),
   `colorSchemeContrast == .increased` (stronger stroke, `textPrimary`),
   `accessibilityDifferentiateWithoutColor` (symbol or text beside any
   colour-only state: tag and folder colours already carry names via
   `ColorAccessibility`; check status dots and the graph's states) and
   `accessibilityShowButtonShapes` (outline for `.plain` chips such as
   `KnowledgeChipButton`). `KnowledgeCard`, `kurnCard`, `RecordingMiniBar` and the
   chat composer card are the only custom surfaces that need them.
3. **`.accessibilityIgnoresInvertColors(true)`** on meeting photos, the photo
   viewer and any avatar.
4. A screenshot matrix test for the six system states × the screens that scroll
   under a toolbar (list, transcript, chat), kept as `ui-review-previews`.
   The 30-frame matrix of the specification is the manual release version of it.
Exit: `.contrast` audit clean on every audited screen in both appearances.

### U2b · Visual system and first impression (2 sprints)

Goal: an app that reads as one product, explains itself in the first minute and
looks professional without custom chrome. **Evidence limits:** the findings are
token-level and come from the source; no app screenshot is checked in, so
hierarchy, alignment and density have not been judged visually. The CI artifact
`ui-review-previews` (seeded screens, retained 14 days) is the input for the
screenshot review in step 6.

| # | Finding | Evidence | Direction |
| --- | --- | --- | --- |
| V1 | **One red does four jobs:** brand, record, destructive action and "selected/active" (current place in the bottom bar, active filter, many tints). Red reads as danger, so a calm selection looks like a warning | `Theme.accent` (#FF3B30, system red) in 128 places across 58 files; `destinationButton` tints the current place with it | Separate roles: red only for record, destructive and errors; a distinct interactive tint for selection and links |
| V2 | **Three competing accents:** the asset catalog's `AccentColor` is an indigo (about #4C6EF5), `Theme.info` is #0A84FF and `Theme.accent` is red; the global tint and the hand-applied tints disagree | `AccentColor.colorset`, `Theme.swift` | One interactive accent defined once (asset and token the same), `info` removed or aliased |
| V3 | **No spacing, radius or motion tokens:** stack spacings of 2, 3, 4, 5, 6, 8, 10, 12, 14, 16, 20 pt; corner radii of 4, 8, 10, 12, 14, 16, 18, 24, 26 pt (`kurnCard` defaults to 18, `knowledgeCard` to 16); animation durations from 0.06 s to 1.25 s | `grep` over `Views/` | `Theme.Spacing` (4, 8, 12, 16, 20, 24), `Theme.Radius` (small, card, sheet), `Theme.Motion` (quick, standard); migrate by screen |
| V4 | **Several surface treatments:** cards on `Theme.surface` (9), chips and wells on `Theme.fill` (25), `kurnCard` (9) and `knowledgeCard` | `grep` | Three levels only (background, card, inset) and one card modifier |
| V5 | **A custom dark palette beside system materials:** `#0A0A0F` background and white-alpha text tokens in dark, system grouped backgrounds in light; the recorder forces `.dark` | `Theme.swift`, `RecorderView.swift:121` | Decide whether the blue-tinted near-black is a brand choice; if not, move dark mode to the system backgrounds so Liquid Glass and Increase Contrast behave as designed |
| V6 | **No first-run experience:** no onboarding or first-use code; the first value (a recording turning into a summary) sits behind a microphone prompt, a model-download consent and a provider choice | `grep` for onboarding/first-run finds only screenshot seeds and the review prompt | One guided empty state, no tour (step 4) |
| V7 | **Little tactile feedback:** three feedback sites (recorder highlight, mini-bar state, photo shutter) | `grep` | Feedback on record start/stop, copy, delete confirmed, success (step 5) |

**Work**
1. **Decide the colour roles first** (V1, V2, V5): a one-page palette with
   interactive accent, brand mark, record/destructive red, status green and amber
   (with the light-mode contrast fixes from G3), neutral surfaces. Prototype the
   bottom bar and the filter button with the calm accent and compare screenshots
   before migrating the 128 call sites.
2. **Add `Theme.Spacing`, `Theme.Radius`, `Theme.Motion`** and migrate by screen
   as U3 touches each one (no big-bang rewrite); a static-policy rule rejects a
   new literal corner radius or spacing outside the token file once a screen is
   migrated (baseline that only shrinks).
3. **Collapse the surfaces** to background, card and inset with one card
   modifier shared by `kurnCard` and `knowledgeCard`.
4. **First-run empty state.** On the empty meetings list: what the app does in
   one sentence that is true under the default settings and does not hide the
   cloud options ("Record a meeting. By default everything stays on this
   device; if you choose a cloud provider, only what that feature needs is sent
   to it."; summaries use the configured provider, so the copy cannot promise
   on-device processing unconditionally), one prominent Record button, and a
   one-line note on what happens next. The wording is checked against
   `PrivacyCloudSettingsView` so the two never disagree. Ask for the microphone only when Record is tapped, with a sentence
   before the system prompt saying why. Offer the diarization model download
   once, after the first recording, in the banner that already exists, with its
   size. No tour, no tooltips, no sign-in.
5. **Feedback and loading.** Use `sensoryFeedback` for record start and stop,
   copy and a confirmed delete; keep the 47 progress indicators but make long
   waits say what is happening and what the person can do meanwhile (the
   pipeline phases already exist).
6. **Screenshot review** with the CI `ui-review-previews` (or fresh device
   captures) of: empty list, list with meetings, recorder, mini bar, meeting
   detail (each tab), Ask, Knowledge, Settings, at default and AX3, dark and
   light. Per screen: one clear focal point; at most two type weights in a
   row; aligned left edges; consistent margins (20 pt); no control that looks
   tappable but is not or the opposite; no text under 11 pt equivalent; status
   shown with words, not only colour. Score with the U0b severity scale.
7. **Brand consistency.** Icon, accent, launch screen, store screenshots and
   in-app colours from the same palette (step 1); the `scripts/screenshots`
   frames already render per-language captions, so update their palette last.
Exit: a palette and token file, the first-run empty state, and a reviewed set of
screenshots with no severity-3 or -4 visual finding.

### U3 · Elastic layout to AX5 (2 sprints)

Work through the baseline counts, not the whole list of anti-patterns:
1. Replace the 8 non-exempt fixed sizes with `Theme` fonts or `@ScaledMetric`
   (`PhotoCaptureView`, `DesignComponents`, `TemplateEditorView`, `FolderFormView`,
   `MeetingDetailTabs`, `MeetingChatView`, `TranscriptView`). Each remaining
   `.system(size:)` keeps its inline reason.
2. Remove `.lineLimit(1)` on content (list rows, chips, `ChatSessionListView`,
   `DocumentsListView`, `MeetingsListComponents`); chips wrap or move to a
   vertical layout.
3. Make `MeetingDetailTabs` heights (42/54 pt) `minHeight` scaled with
   `@ScaledMetric`; `TagChipsView`, tab picker and `FilterBarView` use
   `ViewThatFits` with a vertical fallback. The recorder and mini bar keep their
   capped `dynamicTypeSize(...accessibility2)` and gain a Large Content Viewer
   (`accessibilityShowsLargeContentViewer`) for their icon-only transport
   controls.
4. Hit targets: every icon-only control ≥ 44×44 pt (`SegmentPlaybackScrubber`
   at 24 pt is the known one) via `contentShape`, not a bigger glyph.
5. `GeometryReader` stays for the scrubber, graph canvas and chat sizing; none
   decides a text layout.
Exit: `.dynamicType`, `.textClipped` and `.hitRegion` audits clean at AX5.

### U4 · VoiceOver, Voice Control and motion (2 sprints)

1. **Structure.** Generated notes: the disclosure for each paragraph reads
   "Based on N claims" for that paragraph, so give it the paragraph's first words
   as context (`accessibilityLabel` plus `accessibilityHint`), and announce that the
   text is generated before it is read. `isHeader` on every section title (`KnowledgeSectionLabel`,
   settings headers, summary section titles); `.accessibilityElement(children: .combine)`
   on meeting rows and knowledge cards; `accessibilityCustomContent` for list
   metadata (duration, language, status) so the label stays short; rotors for
   transcript speakers/timestamps and for summary sections.
2. **Focus and announcements.** Post `AccessibilityNotification.Announcement`
   for transcription finished, summary ready, copy done and validation errors;
   use `@AccessibilityFocusState` to land focus on the error or the first new
   result. Throttle progress announcements (not per-percent).
3. **Controls.** The scrubber and any custom slider use `accessibilityRepresentation`
   or `accessibilityAdjustableAction`; the graph canvas keeps its 44 pt overlay
   buttons and gains a list-first default under VoiceOver (already done).
   Verify the session-220 patterns against Apple's published guidance before
   adopting any of them.
4. **Voice Control.** `accessibilityInputLabels` on the record button, the
   toolbar controls, "Meeting actions" and the chat menu; no two visible
   buttons share the label "More".
5. **Motion.** Route the 5 `withAnimation` and 4 `.animation(` call sites
   through `kurnAnimation`; the minimized recorder's morph and the sheet-to-bar
   handoff get a fade-only variant; add a static check to
   `Tools/check_static_policy.py` that rejects a bare `withAnimation` in `Views/`.
6. **Charts and media.** The graph and the audio level meter expose a
   `accessibilityChartDescriptor`-style summary only if the visual carries
   information the list view does not (it does not today: record why).
   Read-aloud already offers audio; transcripts are the captions alternative.
Exit: all common tasks complete with VoiceOver and Screen Curtain on a device.

### U5 · Device certification and governance (1 sprint)

1. **Decide the scope first.** `fastlane/accessibility.json` declares per device
   family (IPHONE, IPAD, APPLE_WATCH; Voice Control does not exist for the
   Watch) and today declares VoiceOver, Larger Text, Reduced Motion and
   Differentiate Without Color as supported on all three, and Dark Interface,
   Sufficient Contrast, Voice Control, Captions and Audio Descriptions as not.
   U5 lists which labels it re-evaluates (at least every one declared `true`,
   because the baseline above does not yet support them, plus Sufficient Contrast
   and Dark Interface after U2, and Voice Control after U4) and for which
   families. A label stays declared for a family only with evidence for that
   family.
2. Run the common-task list per family in scope: on a physical iPhone and iPad
   with VoiceOver + Screen Curtain, Voice Control only, AX5, Dark, Reduce
   Transparency, Increase Contrast, Reduce Motion, and Liquid Glass at both ends
   of its slider if the OS has one; on the Apple Watch the recorder remote with
   VoiceOver, the largest text size, Reduce Motion (the recording indicator and
   any transition stay still) and Differentiate Without Color (Recording and
   Paused are read as words, not colour), because the manifest also declares those
   two for the Watch; any label the Watch pass cannot evidence is set to `false`
   (`KurnWatchUITests` does not run in CI).
   One matrix row per family × label: build, device, result, evidence link.
3. Move the widened audit (`AccessibilityBaselineUITests`) into the required
   `ui-accessibility-tests` shards once its findings are fixed. The failure
   artifact is already uploaded.
4. **Who checks the evidence, and where.** CI's `AccessibilityLabels.load`
   (run in `lint-and-validate`) is structural only: keys per family, booleans,
   an HTTPS URL. `Tools/validate_store_metadata.py` does not read evidence
   either. Add `Tools/check_accessibility_evidence.py` to `static-policy`:
   every `true` in `accessibility.json` needs a matching family × label row
   in `docs/release-physical-checklist.md` with a **passing** result, a date
   and a link, recorded against the build being published (the tagged
   `MARKETING_VERSION` and build number); a failed, blocked or older-build row
   fails the check. Before
   the protected, manual `accessibility-labels.yml` publishes, the release owner
   signs the matrix; the script makes that sign-off checkable, it does not
   replace it.
5. Publish the accessibility page and add EAA-relevant limits to it.
6. Every release re-evaluates the labels when navigation, authentication,
   playback or the design tokens change.

### Order and risks

U0 → U0b → U2 and U1 in parallel (U1 touches structure, U2 tokens) → U2b (visual system and first run; decide colours before U3 migrates screens) → U3 → U4 → U5.
Risks: U1.1 and U1.4 change what users have learned, so they ship behind the
U0b walkthrough, not with the accessibility fixes; U2.1 changes 71 call sites,
so migrate by screen with the screenshot matrix; the simulator cannot run
VoiceOver, so no U-phase is "done" on audits alone.

## Follow-ups on shipped work

Gaps each shipped track recorded about itself. None blocks feature work; each
is listed so it is not rediscovered.

### Topic-aware correction

- Measured on 2026-11-05 (`docs/pipeline-evaluation.md`), on Nemotron Unified:
  no measurable improvement over the corrector it replaced — English still
  +0.54pp worse than no correction (old +0.63pp), Portuguese −0.38pp (old
  −0.68pp). Nemotron reports no confidence, so every segment is sent. Next:
  for engines without confidence, send only segments the critic flagged, and
  re-run the same pair; optionally also reject corrections that delete more
  than a few words, since `CorrectionFaithfulness` only blocks additions.
- Measure the LLM's own run-to-run spread (two identical `correction: only`
  dispatches) before reading a sub-1pp difference between correctors.
- Aggregate substitution/insertion/deletion counts are not printed by the
  harness, only per item; print them so a regression's kind is measurable.
- `CorrectionFaithfulness` uses spelling closeness as its only proxy for
  "sounds like"; a homophone spelled very differently ("sequel" → "SQL") is
  accepted only through the grounded vocabulary. A per-language phonetic key
  would widen what it can verify.
- The critic sees a ≤ 8,000-character sample, not the whole meeting; a term
  that occurs only outside the sampled windows is found only by the batch
  that contains it.

### On-device LLM (`FoundationModelsProvider`)

- **Measure the on-device budgets.** `ContextBudget.onDevice` and
  `FoundationModelsProvider`'s output-token ceiling are conservative first-cut estimates against Apple's
  documented ~4096-token session window, commented as such in the code — not
  measured against real on-device runs the way the transcription pipeline is.
- **Exercise the untested paths.** `LLMTranscriptCorrector` and `WikiService`
  can select the on-device provider through the
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
- **Model integrity.** Models installed before verification existed read
  `.unverified` until re-downloaded. Download resume data survives
  backgrounding but not a relaunch, and there is no automatic
  retry-with-backoff.
- **Operation state.** A full operation-state enum (queued / running / paused /
  deferred / retryScheduled / permanentFailure with reason codes and
  `nextAttemptAt`) was deferred — the bounded `automaticResumeAttempts` counter
  over `TranscriptionStatus` suffices until a concrete UI need appears (e.g.
  "retrying in 2 minutes").
- **Network.** A dedicated "waiting / rate-limited" UI; FluidAudio's
  mid-transfer network path changes are unobservable (the library exposes no
  session to preflight against); background cloud upload stays off while
  origin-lock cannot be guaranteed there.
- **Error UX.** Retry from the error dialog is wired only where a caller
  passes `onRetry`, and no case maps to `recoverQuarantinedAudio` or
  `exportDiagnostics` yet; a short reference ID shared by an error
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

The larger UI track is "UI simplification and accessibility (U-track)" above; the
items here that it does not cover:

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
2. **Build once, test many** (done). `build-for-testing` compiles the app and
   test bundles once and uploads the products and `.xctestrun`; `unit-tests`
   and both `ui-tests` shards run `test-without-building`. A UI shard used to
   spend about 15 minutes compiling beside its booted simulator.
3. **Fewer launches per suite.** Each test relaunches the app (~10–15 s on a
   CI runner); checks that share a screen belong in one test, as
   `testMeetingDetailTabs` already does for the audit. Separate tests only
   where a failure would otherwise hide the next check.
4. **Rebalance the shards from measured times.** `main` now also runs
   `BulkSelectionFlowUITests`; read the per-suite durations from the
   `.xcresult` and move suites so neither shard waits on the other.
5. **Replace the remaining text handles.** Menu-picker options, segmented
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

1. **K0–K2 · Knowledge Engine, up to the first user-visible phase.** The
   wiki refactor above; K0 needs no data migration and K1 stops for review
   before one. F2 can run in parallel — they share no code.
2. **F2 · Meeting glossary.** Its WER effect is measurable, and the pure half
   is verifiable on Linux.
3. **F4 · Calendar context.** Feeds F2 real names and supplies the candidate
   names cross-meeting voice matching lacks.
4. **F5 · Reminders and F6 · Import.** Independent of each other and of the
   rest; slot them in as room appears. F6 widens the capture surface, so it
   lands with the same fault-injection discipline as capture itself.
5. **U0–U5 · UI simplification and accessibility.** U0 measures first and
   needs no feature work, so it can start at any point; U1 waits for its review.
6. **D4's per-file measurement**, on its own clock — it is a dispatch, not code.
7. **Reassess F7–F10.** F7 after the on-device availability number exists.

The follow-ups above are picked up opportunistically, ahead of any feature that
widens the surface they concern.
