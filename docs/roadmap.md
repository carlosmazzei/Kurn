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
| **K2 · First user value** | K2.1 backend done: deterministic structured global wiki pages, explicit source authorization and fresh evidence checks, scoped merge-aware views, atomic protected-store publication/outbox and stale-cache refusal. Optional local narrative input is validated against page assertion IDs; invalid output preserves valid pages. "Rebuild pages" generates cited narratives with the Knowledge provider (cloud only under its automatic grant, `.pageNarrative` policy) for the 24 largest pages; the entity page shows them under "Notes", separate from claims. K2.2 backend done: local read-only lint for broken typed links, current orphan entities, stale/missing projections, review-only identity candidates and measured segment coverage. Versioned maintenance reports preserve incomplete/unknown states, authorize sources and policy afresh, omit excluded IDs/content and never repair data automatically. Maintenance/review UI remains K2.6–K2.7. K2.3 implemented behind knowledgeEnabled: a fifth meeting-detail mode, inline episodic notes, source-scoped contributions with original attribution/modality/negation, and unique entity/claim/passage header counts. Reads are offline; invalidation/refetch prevents old names/counts after source/access changes or route reuse. Inline note generation is explicitly local-only. Compact and accessibility-size UI previews are attached in CI; the global navigation prototype/gate remains K0.5. K2.4 scoped reader implemented: Knowledge Home, entity Overview/Sources, evidence detail → cited source transcript and explicit recording-relative audio. Fresh source/context authorization gates metadata, quotes, transcript and playback; route/store/feature/scene changes invalidate content and stop audio. Meeting entry stays source-local. The reviewed four-tab root adds Knowledge Home with an explicit, bounded 1–16 meeting picker, the existing library Ask conversation and saved Documents. Library/filters/sort/multi-selection stay in the upper menu; tab changes retain meeting controls. Wider-layout and physical-device validation remain open. K2.5 local search implemented for the current page/alias/assertion corpus: explicitly scoped, disposable typed documents share BM25/RRF with transcript retrieval; literal/name matching and accent folding work offline without assets. Optional dense ranking uses installed on-device assets only, embedding policy and fresh admission/publication checks, with full-corpus lexical fallback. Search results open ID-only reader/evidence routes, cancel stale queries and clear on source/policy changes. Event documents follow the validated temporal reader in K3; no schema migration or persistent embedding cache is introduced. K2.6 scoped Review inbox implemented for current canonical data: explicit identity candidates → keep separate/reopen or confirmed merge, with source-preserving merge history/undo; every decision rechecks scope, revision, live policy and origins. Exact opposing-claim hints and stated month precision link to freshly validated passages; invalid/stale evidence is hidden behind an inspection warning. Hints remain inspect-only; temporal/event conflict resolution follows K3. No automatic linking or claim/date rewriting is enabled. K2.7 local Settings → Knowledge implemented: independent on-device processing, enable, opt-in automatic compilation for future transcripts, durable scope/exclusions, canonical-only pause, explicit bounded backfill preview/confirmation with local provider-fee estimate, optional explicit recompilation generations, page rebuilding without a model and measured segment coverage. Unknown/corrupt preferences fail closed; scope changes revoke readers and pending publications. Existing pending approved work can resume independently of the future-transcription toggle. Cloud/provider consent remains gated; corporate-policy editing is not introduced. K2.8 deletion implemented: tombstones committed with meeting/transcribed-recording deletion and a durable corpus tombstone behind Settings → Delete Knowledge; one-transaction purge of exclusive canonical rows, provenance, reviews and page caches with a revision bump, resumed at launch/activation/save after a failure or process death; `LibraryEraser` already erases every row. Recording deletion purges the whole meeting's knowledge for recompilation. Physical-device validation of a kill mid-purge remains a release check | Meeting → topic → evidence navigable; reads work offline; deletion verified to leave nothing exclusive behind |
| **K3 · Time** | K3.1 done: KurnCore `KnowledgeTemporalReducer.state(of:validAt:knownAt:claims:)` with half-open valid and transaction time, precision-aware possible/definite, valid-time-only ordering of single-valued predicates, unordered values and contradictions surfaced as conflicts, and order-independent output; exact on the `pt-provisioning-timeline` fixture (status progression, late-arriving blocker). Not yet wired to the store or any reader; an explicit `validTo` on a later status does not yet end an earlier one. Spec §6 / §16.1 step 7 fixtures still to add with K3.2. K3.2 done: KurnCore `KnowledgeLifecycle` decision/action/risk machines projected from known status claims (and `supersedes` for decisions), ordered by stated time with lifecycle-resolved overlaps, invalid/ambiguous/out-of-vocabulary anomalies and set-aside tentative/negated/undated claims; exact on the provisioning and platform-review fixtures; not yet wired to the store, so `KnowledgeEvent` rows are not yet written from them. The spec §6 / §16.1 step 7 fixtures (the specification is not in the repository) remain to be added. K3.3 done: a scoped Timeline in the Knowledge reader (KurnCore `KnowledgeTimeline`) placing each claim by its stated month at its own precision, with the meeting it came from and the date it was recorded beside it, an unknown-date section in recorded order, kind/tentative/negated filters, lifecycle anomalies on the claims they name and ID-only evidence links; offline, no new storage. Context lanes on iPad remain open (the read carries no per-claim context yet), as do as-of (known-at) navigation and wider-layout/device checks. K3.4 done: "Compare dates" on an entity page (KurnCore `KnowledgeStateComparison`), the reducer's state at the end of two picked days lined up as changed/started/ended/unchanged with certainty shifts, optionally as known on each date, from the reader's authorized pages; offline, no new storage. Comparing two transaction times on the same valid day has no dedicated UI yet. K3.5 done: "Revised later" on an entity page (KurnCore `KnowledgeLateArrival`), the state as known just before and at each later transaction time compared only over the valid interval it changed, split where the change differs, counted late only when it changes days before its recording day; offline, no new storage. A timeline marker for late claims and written `KnowledgeEvent` rows remain open | Bitemporal snapshots exact on fixtures, including the spec §6 example and §16.1 step 7 |
| **K4 · Graph** | K4.1 done: KurnCore `KnowledgeGraphIndex` over the reader's authorized pages, bounded BFS (default depth 1, 40 nodes, 80 edges, clamped to depth 2), predicate/tentative/negated filters, truncation flag + frontier, `supersedes` cycles reported (Tarjan); the app's `KnowledgeGraphQueryService` caches the index and recent answers keyed by revision, meetings, policy revision and the pages themselves. No UI yet. K4.2 done: KurnCore `KnowledgeGraphLayout`, a force-directed layout deterministic by node ID and seed (SplitMix64, ID-ordered, fixed steps), with fixed positions kept; the query service caches one layout per answer and keeps shown nodes where they were as the neighbourhood grows. K4.3 (relationships mode) done: Graph Explorer opened from an entity page, drawn on `Canvas` with a hit-testing overlay of node buttons, list alternative (default under VoiceOver), recentring, depth/tentative/negated/inferred filters with inferred edges off by default, exploration kept across graph ↔ page navigation, accessibility audit in `MeetingKnowledgeUITests`. K4.3 On a day (evolution) and Compare modes done: KurnCore `KnowledgeGraphTimeline` (K3.1 reducer per edge source), edges that did not hold hidden, plus/square/ring marks with words, days kept in the exploration. K4.3 Contexts (lanes) mode done: the read carries each meeting's context, one lane per context in kind order (unknown last), nodes in their main lane keeping their x, every row and node label naming its context. K4.3 done | Graph ↔ wiki keeps selection; spec performance targets met on a physical device; accessibility audit added |
| **K5 · Ask over knowledge** | K5.1a done: `search_knowledge`, `get_entity`, `get_timeline`, `get_evidence`, offered only when the default-deny policy authorizes `answerSynthesis` for the run's provider with the person's consent (for a cloud provider, its on-request grant in the shared cloud-consent ledger), re-authorized after every read. K5.1b done: `resolve_entity`, `get_graph`, `compare_state`, `list_open_actions`, `list_contexts`, `get_context` over the same read. K5.1c done: `get_coverage`, the K2.2 per-recording examined-segment counts and states grouped by meeting, content-free and authorized before and after its own read. Remaining K5.1 tools `get_wiki_page` done (returns the page narrative and its cited assertions, labelled as not evidence), `trace_influence` done (KurnCore `KnowledgeInfluenceTrace`: claims about or naming the entity in stated order, what each replaces, meeting, speakers, evidence) — read-only, host-authorized, compact text, citations resolved by the host. K5.2 done: a `knowledge_policy` system-prompt section, only when the knowledge tools are offered, sends the model to knowledge first and to `get_coverage` plus the transcript tools for gaps. K5.3 done: `ChatSourceScope` has a knowledge part that gates the knowledge tools per meeting; Ask from an entity page opens a conversation scoped to its source meetings. K5.4 benchmark variants C–F against A/B, run on a device against the synthetic question set | Measured gain over the baseline on the holdout; historical answers correct; no excluded source leaks through results, snippets, counts or errors |
| **K6 · Hardening and release** | K6.1 static audit done: the `knowledge-network` static-policy rule keeps Knowledge code off the network and sync stores (its only egress is the policy- and consent-admitted provider call), with the boundary in `SECURITY_MODEL.md`; KurnCore `KnowledgeEgressSweepTests` check every operation × classification × consent × provider × policy shape against the egress invariants (consent withdrawal, default-deny narrowing, feature off). App-level runtime egress is covered by tests: cached projections re-check the live ACL and policy before reads (`KnowledgeWikiProjectionTests`), embeddings need policy plus fresh admission (`KnowledgeSearchTests`), counts and other Ask tool output only reach a provider the gate admits and are re-authorized after every read (`ChatKnowledgeToolsTests`), and page narratives skip a cloud provider without its automatic grant (`KnowledgeSettingsIntegrationTests`). K6.2 done: the Knowledge browser exports the selected meetings' entities, claims and evidence as one `kurn.knowledge-export` JSON file (KurnCore `KnowledgeExportBundle`, schema 1, deterministic), off by default (Knowledge settings) and saved through `fileExporter`, never a share sheet; `.export` is authorized before and after the read. K6.3 performance on 100/1k-meeting fixtures (spec §14 targets are goals, not measurements). K6.4 localization, release checklist items, the knowledge components and their egress boundary added to `SECURITY_MODEL.md`, docs moved into `CLAUDE.md`/`README.md` | CI green, privacy audit, physical-device checks, coverage floors held |

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
5. **D4's per-file measurement**, on its own clock — it is a dispatch, not code.
6. **Reassess F7–F10.** F7 after the on-device availability number exists.

The follow-ups above are picked up opportunistically, ahead of any feature that
widens the surface they concern.
