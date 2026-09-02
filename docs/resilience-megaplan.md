# Reliability and Resilience Megaplan

This document is the execution-oriented companion to the reliability and
resilience track in `docs/roadmap.md`. The roadmap owns the product invariants,
risk register, and detailed H1–H10 contracts. This file owns sequencing, PR
boundaries, dependencies, acceptance gates, and the handoff state needed to
resume the track in another engineering session.

## Current handoff

Last updated: 2026-09-01.

- PR #151 established the initial reliability vocabulary and injectable seams.
- PR #152 completed the core H6 network-boundary contract and the first H1
  capture-safety slices.
- PR #153, `Make recording capture durable and recoverable`, merged the H1 core
  into `main` as commit `458a502`.
- The H1 implementation commit is `1c2eb66` (`Make recording finalization
  durable`); GitHub `build-and-test` and `kurncore-linux` passed before merge.
- The deleted source branch was `devin/resilience-h1-capture-lifecycle`; do not
  recreate it or stack new work on the stale local branch.
- PR #154 published this document and the roadmap execution-sequence updates.
- **[PR #155](https://github.com/carlosmazzei/Kurn/pull/155), `Add a versioned
  SwiftData schema baseline (H2 PR 2)`, merged into `main`** (2026-08-30, as
  commit `a14fab3`). `Kurn/Infrastructure/KurnSchema.swift` adds
  `KurnSchemaV1`/`KurnSchemaMigrationPlan`/`KurnModelGraph`;
  `ModelContainerBootstrap`, `KurnApp`, and `TestModelContainer` all read the
  model graph and versioned schema from there;
  `KurnTests/LegacyStoreAdoptionTests.swift` round-trips a same-run generated
  unversioned-store fixture through the new versioned path. First `iOS CI` run
  (commit `75c9188`) failed `build-and-test` with two `'Tag' is ambiguous for
  type lookup in this context` compile errors — Swift Testing's own `Tag` type
  collided with Kurn's `Tag` model in two bare type-annotation positions;
  fixed by qualifying both as `Kurn.Tag`. The follow-up run passed both
  `build-and-test` and `kurncore-linux`, with no unresolved review comments,
  before merge. See "PR 2 — H2 versioned-schema baseline" below for the
  deviation from "commit N-1/N-2 fixtures" (there is no earlier released
  schema version to fabricate, since this is the first one ever declared) and
  exactly what shipped.
- [PR #156](https://github.com/carlosmazzei/Kurn/pull/156), a docs-only
  follow-up recording PR #155 as merged, merged into `main` as commit
  `77f4d90`.
- **[PR #157](https://github.com/carlosmazzei/Kurn/pull/157), `Replace the
  recoverable production fatalError with a boot state machine (H2 PR 3)`,
  merged into `main`** (2026-08-30, as commit `12850ae`, on top of `77f4d90`).
  `ModelStoreBootCoordinator` (`Kurn/Infrastructure/
  ModelStoreBootCoordinator.swift`) replaces `KurnApp`'s production
  `fatalError` with the four states item 1 names;
  `ModelStoreOpenFailureClassifier` (`ModelStoreOpenFailure.swift`) classifies
  a thrown error into one of the four reasons; `ModelStoreRecoveryView`/
  `ModelStoreLaunchProgressView` (`Kurn/Views/ModelStoreBootViews.swift`) are
  the store-independent recovery/waiting shells; `TranscriptionScheduler`'s
  background-task registration now runs before the store is ever opened, per
  item 3. `iOS CI` (`build-and-test`, `kurncore-linux`) passed on the first
  push (commit `fcb9c7b`) — no fix round needed, unlike PR 2. See "PR 3 — H2
  recoverable bootstrap state machine" below for the known gaps (classifier
  NSError mappings unverified against a real device failure; PR 3's UI tests
  are a Debug-configuration launch, not a true Release-configuration device
  run) and what remains for PR 4.
- **[PR #158](https://github.com/carlosmazzei/Kurn/pull/158), `H2 PR 4:
  protected backup, restore, salvage, and recovery UI`, merged into
  `main`** (recorded in commit `e46ded2`). `ModelStoreBackupManager`
  (`Kurn/Infrastructure/ModelStoreBackupManager.swift`) backs up the live
  store before every open attempt (rate-limited to once per app
  version+build), retains 3 generations, and quarantines (never deletes)
  the live store before a restore or confirmed fresh start.
  `ModelStoreSalvage` (`ModelStoreSalvage.swift`) attempts a read-only open
  of a copy of the live store, exported as Markdown on success.
  `ModelStoreProtection.applyAndVerify` and `ModelStoreBootCoordinator`'s new
  `.protectionVerificationFailed` reason cover item 4 (protection
  verification during bootstrap). `ModelStoreRecoveryViewModel` and an
  expanded `ModelStoreRecoveryView` wire all four actions into the recovery
  shell. During PR #158's CI rounds a real use-after-free was found and fixed
  (fetched `Meeting`s outliving their `ModelContainer` on the recovery
  screen, commit `d3b4a25`). See
  "PR 4 — H2 protected backup, restore, salvage, and recovery UI" below for
  the known gaps (salvage is best-effort and cannot recover from a
  genuinely un-migratable schema mismatch or real corruption; "N-1/N-2
  fixtures" is satisfied the same way PR 2 satisfied it — no earlier
  released schema exists to fabricate).
- **[PR #159](https://github.com/carlosmazzei/Kurn/pull/159), H3 PR 1,
  merged into `main`** (as commit `097adaa`): `RecordingTrash` makes
  meeting/recording deletion trash-then-purge instead of delete-then-delete,
  with launch/foreground reconciliation for an interrupted delete.
- **[PR #160](https://github.com/carlosmazzei/Kurn/pull/160), H3 PR 2,
  merged into `main`** (as commit `317d665`):
  `JSONStorage.encodeAuthoritative`/`decodeAuthoritative` close the
  corrupted-transcript-renders-as-empty hazard for
  `Transcript.segments`/`Summary.sections`.
- **[PR #162](https://github.com/carlosmazzei/Kurn/pull/162), the "PR 5"
  boundary below (H3 fail-closed protected storage and quarantine), merged
  into `main`** (as commit `fd4b417`): `AudioFileStore` writers throw
  `AppError.protectedStorageUnavailable` instead of falling back outside
  verified protected storage, and `RecordingQuarantine` preserves
  unmatched/malformed/unreadable/too-short originals and ambiguous
  legacy-migration collisions with size/date/reason metadata plus
  recover/export/confirmed-delete in Storage Settings.
- The "PR 6" boundary (H3 durable mutation journal and protected trash,
  `RecordingOperationJournal`) and the "PR 7" boundary (H3 versioned
  authoritative envelope for the transcription checkpoint) both landed on
  `main` (commits `d7e3dee` and `e7a156a`), closing the full H3 track scope —
  see `docs/roadmap.md`'s H3 section for what shipped. This backfills the
  handoff bullet these two commits should have gotten at the time; they were
  not previously called out here by PR number.
- **[PR #165](https://github.com/carlosmazzei/Kurn/pull/165), H4 PR 8
  (pipeline fingerprint and checkpoint validation), merged into `main`**
  (2026-09-01, commit `08a0192`, after a CI-caught fix for a duration-rounding
  bug — see "PR 8 — H4 pipeline fingerprint and checkpoint validation" below).
  `TranscriptionPipelineFingerprint` (`Models/TranscriptionPipelineFingerprint.swift`)
  and `Infrastructure/PipelineDigest.swift` replace `TranscriptionCheckpoint`'s
  old engine/language/compaction/provider-only match with source
  size/duration/content-digest, effective preprocessing/VAD, exact ASR
  provider+model, a compaction-map digest, and a separately-checked exact
  chunk-plan digest (`ChunkedTranscriptionRunner.Progress.planDigest`).
  `TranscriptionCheckpoint.isStructurallyValid` covers item 2's span/bounds
  validation and gates both the transcribe-path resume check and
  `TranscriptionRecovery`'s launch/foreground sweep. See below for the
  deliberate one-time compatibility break (a pre-PR-8 in-flight checkpoint
  fails to decode under the new shape and is treated as `.corrupted`, same
  as bit-level corruption — never as a false match).
- **[PR #166](https://github.com/carlosmazzei/Kurn/pull/166), H4 PR 9
  (throwing chunk commits and bounded automatic recovery, items 1, 2, 4 of
  the plan), merged into `main`** (commit `4efe374`).
  `ChunkedTranscriptionRunner.run`'s `onChunkCompleted` — and
  `TranscriptionService.CheckpointHandler`/`checkpointSink` above it — are
  now `async throws` and awaited before the next chunk starts, so a
  checkpoint-save failure stops the run at the last durably-committed chunk.
  `TranscriptionViewModel`'s `onCheckpoint` no longer goes through the
  fire-and-forget `AsyncStream` it shared with phase/warning updates; the new
  `storeCheckpointDurably` (`ViewModels/TranscriptionViewModel+ResumeBudget.swift`,
  split out to stay under the file-length limit) saves inline and throws
  `AppError.persistenceFailed` on failure. `Recording.automaticResumeAttempts`
  bounds unattended resume attempts (`TranscriptionViewModel
  .maxAutomaticResumeAttemptsWithoutProgress`, 3) via
  `resumePendingTranscriptions`'s `admitAutomaticResume` gate; an exhausted
  row is marked `.failed` (checkpoint intact) instead of retried again, and
  every manual entry point resets the budget through the new
  `resetAutomaticResumeBudget`. See "PR 9 — H4 throwing chunk commits and
  bounded operation states" below for what's covered and what's deliberately
  deferred (item 3's full explicit operation-state enum).
- **[PR #167](https://github.com/carlosmazzei/Kurn/pull/167), H4 PR 10
  (durable, resumable map-stage checkpointing for staged summary/wiki
  generation, item 6 of the plan), merged into `main`** (2026-09-01, commit
  `663ab09`, after a `build-and-test` re-run confirmed an
  `AccessibilityAuditUITests.testMeetingDetailRecordings` failure was an
  unrelated simulator microphone-permission-alert timing flake, not a
  regression from this PR's diff). `SummaryMapCheckpoint` (`Models/SummaryMapCheckpoint.swift`)
  and `SummaryMapRunner` (`Services/SummaryMapRunner.swift`) give the
  map-reduce loop behind long summaries and wikis the same
  checkpoint-gates-forward-progress contract PR 9 gave transcription chunks.
  `Meeting.summaryMapCheckpointData` is one field shared by Summary and Wiki
  generation — both delegate their map stage to `SummaryService`'s
  `notesTemplate`, so they produce byte-identical notes for the same meeting
  content and can safely share (or briefly re-do a block of) one checkpoint.
  `DocumentGenerationService` is deliberately excluded: it spans multiple
  meetings, so there is no single `Meeting` to persist a checkpoint against.
  See "PR 10 — H4 expensive generated-artifact operation state" below.
- **[PR #168](https://github.com/carlosmazzei/Kurn/pull/168), H5 PR 11
  (typed stage outcomes and a durable pipeline report), merged into
  `main`** (commit `d9f5120`). See "What landed" under "PR 11" below for the
  full contract; this bullet only records the merge. This document previously
  said PR #168 was docs-only and PR 11 was still open — it grew into the PR
  11 implementation itself before merging, and this bullet corrects that.
- **[PR #169](https://github.com/carlosmazzei/Kurn/pull/169), H5 PR 12
  (final integrity gate for a run's fused/corrected output, so a
  structurally broken result can never replace an existing transcript),
  merged into `main`** (commit `e3c1c54`). CI (`build-and-test`,
  `kurncore-linux`) was green on the first push; see "PR 12" below for the
  full contract.
- **[PR #170](https://github.com/carlosmazzei/Kurn/pull/170), H5 PR 13
  (completed-with-warnings UI and correction retry), merged into `main`**
  (commit `b5d2233`). CI green on the first push; bundled its own docs status
  corrections (recording PR 12/#169 as merged) per the user's explicit
  request to avoid a trailing docs-only PR. **H5's plan is now fully
  addressed** — see "PR 13" below for what shipped and the H5 status snapshot
  row.
- **[PR #171](https://github.com/carlosmazzei/Kurn/pull/171), H7 PR 14
  (typed Keychain outcomes, an accessibility-migration fix, and
  explicit-Save for provider credentials), merged into `main`** (commit
  `de8b551`, plus a follow-up CI fix `ae5d63f` serializing
  `KeychainManagerTests` against a real-Keychain race the first push
  exposed). See "PR 14" below for the full contract.
- H7 PR 15 (an injectable `ModelDownloading` seam unifying the whisper.cpp
  and sherpa-onnx downloaders, exact-size plus opportunistic-SHA-256
  verification, atomic install with backup/rollback, resume data, and
  cancellation) is implemented on branch
  `claude/resilience-roadmap-plan-fn23ki`; see "PR 15" below for what
  shipped and its stated known gap. Docs status corrections for PR 14 are
  bundled in this same PR, per the same standing request.
- The Xcode-generated
  `Kurn.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` is
  currently unrelated to this track and must not be included without a separate
  dependency-pinning review.

## How to resume

1. Read this file and the `Reliability and resilience track` section of
   `docs/roadmap.md`.
2. H2 is done: PR #155/#156/#157/#158 (schema baseline, boot state machine,
   and backup/restore/salvage/recovery UI) are merged into `main`. H3
   (`docs/roadmap.md`'s "H3 · Atomic model/file mutations and non-destructive
   reconciliation") is fully done and merged into `main`: PR #159
   (trash-then-purge deletion), PR #160 (authoritative JSON encode/decode),
   PR #162 (fail-closed protected storage and quarantine, the "PR 5"
   boundary), the durable operation journal (`RecordingOperationJournal`, the
   "PR 6" boundary, commit `d7e3dee`), and the versioned checkpoint envelope
   (the "PR 7" boundary, commit `e7a156a`) are all on `main`, closing the
   planned H3 boundaries; see the status snapshot below.
   H4 (checkpoint identity and durable operation state) is **done**:
   [PR #165](https://github.com/carlosmazzei/Kurn/pull/165) (pipeline
   fingerprint and checkpoint validation, the "PR 8" boundary),
   [PR #166](https://github.com/carlosmazzei/Kurn/pull/166) (throwing chunk
   commits and bounded automatic recovery, the "PR 9" boundary), and
   [PR #167](https://github.com/carlosmazzei/Kurn/pull/167) (durable,
   resumable map-stage checkpointing shared between summary and wiki
   generation, the "PR 10" boundary) are all merged into `main` (commit
   `663ab09`) — H4's plan items are now fully addressed except item 3 (the
   full explicit operation-state enum), left deliberately deferred; see the
   H4 status snapshot row and "PR 10" below for the document-generation
   exclusion. **H5 is done**: "PR 11" (typed stage outcomes and the
   persisted pipeline report) merged as
   [PR #168](https://github.com/carlosmazzei/Kurn/pull/168) (commit
   `d9f5120`); "PR 12" (the final integrity gate and correction-identity
   check) merged as
   [PR #169](https://github.com/carlosmazzei/Kurn/pull/169) (commit
   `e3c1c54`); "PR 13" (completed-with-warnings UI and correction retry)
   merged as [PR #170](https://github.com/carlosmazzei/Kurn/pull/170)
   (commit `b5d2233`). **H7 is now in flight**: "PR 14" (typed Keychain
   outcomes, the accessibility-migration fix, and explicit-Save for
   provider credentials) merged as
   [PR #171](https://github.com/carlosmazzei/Kurn/pull/171) (commit
   `de8b551`); "PR 15" (verified model staging, resume, and replacement) is
   implemented next, on branch `claude/resilience-roadmap-plan-fn23ki`.
3. Keep the physical H1 matrix as a release gate; it does not block later work.
4. Create the next branch from updated `main` and implement only the next PR
   boundary below.
5. Every new durability/state transition must land with deterministic fault
   injection in the same PR.
6. Update both this document and the roadmap only after observed verification.

## Fixed decisions

- Scope is the complete H1–H10 track.
- Work is split into small PRs with one principal invariant or architectural
  boundary per PR.
- Priority order is H1, H2, H3, H4, then H5/H7/H8/H9. H10 is cross-cutting.
- Existing production data must be preserved. Store reset is acceptable only
  for local development or after an explicit user-confirmed fresh start.
- Each PR requires lint, relevant deterministic fault tests, simulator tests,
  and green GitHub CI.
- Physical-device scenarios block release, not ordinary PR merge, unless the PR
  changes behavior that cannot otherwise be reviewed safely.
- No new dependency is assumed available. New dependencies require explicit
  review and a vetted pinned version.
- `ready` or success is emitted only after authoritative state is durable.
- Cancellation, transient failure, permanent failure, degradation, and resource
  deferral remain distinct states.
- No recording, transcript, title, API key, provider body, or URL query belongs
  in reliability events, fixtures, or exported diagnostics.
- H6 active traffic stays foreground-only while iOS background sessions cannot
  enforce the same cross-origin redirect rejection.
- Streaming remains evidence-gated polish and is not a resilience blocker.

## Status snapshot

| Track | Status                 | Remaining contract                                                                                                                   |
| ----- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| H1    | Core merged in PR #153 | Physical protection, route, interruption, background, and low-storage release matrix remains.                                        |
| H2    | Done, merged (PR #155, #157, #158) | `KurnSchemaV1`/`KurnSchemaMigrationPlan`/`KurnModelGraph`, an injectable `ModelContainerBootstrap`, `ModelStoreBootCoordinator` (replacing the production `fatalError`), `ModelStoreBackupManager`/`ModelStoreSalvage`/`ModelStoreRecoveryViewModel` are all on `main`. A real use-after-free found during PR #158 — fetched `Meeting`s outliving their `ModelContainer`, which would have crashed users on the recovery screen — is fixed; see docs/roadmap.md's H2 handoffs. |
| H3    | Done, all PR boundaries merged | `RecordingTrash` ([PR #159](https://github.com/carlosmazzei/Kurn/pull/159)) makes meeting/recording deletion move-then-purge instead of delete-then-delete, with launch/foreground reconciliation for an interrupted delete. `JSONStorage.encodeAuthoritative`/`decodeAuthoritative` ([PR #160](https://github.com/carlosmazzei/Kurn/pull/160)) close the corrupted-transcript-renders-as-empty hazard for `Transcript.segments`/`Summary.sections`. Fail-closed protected storage and `RecordingQuarantine` for unmatched originals and migration collisions ([PR #162](https://github.com/carlosmazzei/Kurn/pull/162)) remove the unprotected `recordingsDirectoryURL` fallback and every automatic-deletion path in the recovery sweep. `RecordingOperationJournal` (the PR 6 boundary below) records durable delete/replace intent before any file moves, replays or rolls back unfinished operations from their own recorded state on launch/foreground (ahead of the heuristic trash sweep, which remains only for pre-journal leftovers), journals compaction's in-place swap, and makes "Delete All Data" report residual audio files instead of implying a clean wipe. The PR 7 boundary below extends the versioned envelope beyond transcript/summary to the transcription checkpoint: `Recording.transcriptionCheckpoint` writes `JSONStorage.encodeAuthoritative` envelopes (encode failure keeps the previous resumable point), reads distinguish `.corrupted` from `.empty` via `transcriptionCheckpointOutcome` (legacy bare payloads still decode; corrupted bytes are preserved, not blanked), and both the transcribe path and `TranscriptionRecovery`'s stale sweep treat a corrupted checkpoint as an explicit non-resumable state instead of "never checkpointed". Operation reports do not exist yet (H5); they adopt the envelope when introduced. |
| H4    | Done, PR 8/9/10 merged | `TranscriptionPipelineFingerprint`/`PipelineDigest` give checkpoint matching a full source-digest + preprocessing/VAD + exact provider/model + compaction-map + chunk-plan identity, and `TranscriptionCheckpoint.isStructurallyValid` validates span/bounds sanity before a resume or the recovery sweep trusts one (PR 8, merged). `ChunkedTranscriptionRunner`'s chunk-completion callback is `async throws` and awaited before the next chunk starts, so a checkpoint-save failure stops the run instead of continuing past an undurable chunk; `Recording.automaticResumeAttempts` bounds unattended resume attempts per recording, reset by any manual retry (PR 9, merged). `SummaryMapCheckpoint`/`SummaryMapRunner` extend the same gated-durable-progress contract to the map stage of staged summary and wiki generation, sharing one `Meeting.summaryMapCheckpointData` field since both artifacts condense byte-identical map notes for the same meeting content (PR 10, merged). Still open: the full explicit operation-state enum with reason codes/`nextAttemptAt` (item 3, deliberately deferred), and durable map-stage resumability for `DocumentGenerationService`, which spans multiple meetings and has no single `Meeting` to checkpoint against (deliberately excluded from PR 10, not planned elsewhere). |
| H5    | Done, merged (PR #168, #169, #170) | `PipelineReport`/`PipelineStageReport` (KurnCore) give every stage a requested/effective engine and a `succeeded`/`degraded`/`skipped`/`failed` outcome with a closed-vocabulary reason, and the aggregate is persisted in `Transcript.pipelineReportData` in the same save as the segments (PR 11, merged). `TranscriptIntegrityGate` (KurnCore) rejects a structurally broken fused/corrected result — empty output from non-empty input, out-of-bounds/out-of-order spans, blank text or speaker attribution — before `TranscriptionService.transcribe` ever returns it, and verifies a `TranscriptCorrecting` conformer preserved segment identity before trusting its output; either failure throws instead of reaching `TranscriptionViewModel.saveTranscript`, so an existing transcript is never replaced by bad data (PR 12, merged). `MeetingDetailView`'s Transcript tab shows a "completed with warnings" banner driven by the stored `PipelineReport`, and correction — the one stage cheap enough to retry without repeating audio/ASR/diarization — gets its own retry action; every other warning falls back to the existing full re-transcribe confirmation (PR 13, merged). |
| H6    | Core implemented       | H9 waiting UX, FluidAudio path-change limitation, and deferred streaming measurement.                                                |
| H7    | In progress (PR 14 merged, PR 15 implemented) | `KeychainAccessing` (`KeychainReadOutcome`/`KeychainWriteOutcome`/`KeychainFailureReason`) replaces the old API that collapsed every Security-framework failure into the same value as "not configured"; `migrateToBackgroundAccessible()` now only marks itself complete after a confirmed outcome instead of after a failed fetch; provider credential edits commit only on explicit Save, after URL validation, with a failed Keychain write surfaced instead of silently assumed (PR 14, merged as [#171](https://github.com/carlosmazzei/Kurn/pull/171)). `ModelDownloading` (an injectable actor replacing the old static `ModelFileDownloader`) now verifies a completed download's exact byte count against the server's declared `Content-Length` and, when the origin volunteers one (HuggingFace's `X-Linked-ETag`), its SHA-256, installs atomically via `FileManager.replaceItemAt` with backup-and-restore on any post-install re-verification failure, keeps resume data across a cancelled/interrupted transfer, and wires a Cancel action into every download progress row (PR 15, implemented). Remaining: pinning whisper.cpp's mutable `resolve/main` source to an immutable revision (no network path to HuggingFace to verify a real commit SHA in the environment PR 15 was authored in — see PR 15's stated known gap), plus storage-inventory verification and a post-install health probe (PR 16).           |
| H8    | Partial                | Resource cooldown/scheduler, cancellation truth, Activity races, shared Watch protocol, deduplication, and durable acknowledgements. |
| H9    | Started                | Action metadata, per-operation error queues, bounded encrypted events, redacted export, health UI, and accessibility.                |
| H10   | Started                | Complete fault matrix, split CI signals, retained artifacts, hardening lane, static checks, and device checklist.                    |

## Completed H1 boundary

PR #153 implements the following code contract:

- `RecordingCaptureState` persists `preparing`, `recording`, `finalizing`,
  `ready`, and `recoveryNeeded`, with stable recovery reasons.
- A UUID-backed `Recording` row is committed before `AudioRecorderService` opens
  the output file. New filenames bind meeting and recording identities.
- `RecordingLifecycleSaving` makes provisional and final SwiftData commits
  independently fault-injectable.
- Start rejects re-entry and foreign `ModelContext` ownership, observes
  cancellation around async engine setup, and cannot complete as a headless
  recording after explicit cancellation.
- Stop commits `finalizing`, closes the sink, then calls the shared
  `RecordingFileFinalizer`.
- The finalizer requires a non-empty readable file, measures sample duration and
  byte size, and applies/verifies `.completeUnlessOpen` before `ready`.
- Sink, stall, validation, and persistence failures preserve useful bytes as an
  explicit recovery artifact. A known failed start with no bytes removes its
  provisional row.
- Launch and foreground recovery reconcile interrupted lifecycle rows through
  the same finalizer. Legacy filename recovery remains compatibility-only.
- A user can retry/finalize a validated partial recording from meeting detail.
- Playback, transcription, export/share, compaction, and enhancement reject
  non-ready rows.
- All seven localizations include the new states and actions.

Observed local verification for the H1 code commit:

- SwiftLint: zero serious violations.
- iOS simulator: 738 passed, zero failed, six intentional skips when excluding
  the known environment-dependent local `WhisperCppModelTests` inventory suite.
- KurnCore: 83 passed.
- Focused suites cover provisional/final commit failure, cross-context insert,
  protection failure, missing/empty/unreadable files, interrupted states,
  explicit partial acceptance, sink faults, and legacy orphan recovery.
- Localization key parity and `git diff --check` passed.

The first full local run also caught a real cross-context SwiftData abort caused
by `RecordingLauncher` test state leaking a pending test `Meeting` into the app
UI. The capture boundary now rejects that mismatch before insert. Durable
launcher queue ownership and external-command deduplication remain H8.

## Execution phases and PR boundaries

### Phase A — P0 durability core

#### PR 1 — H1 provisional ownership and truthful finalization

Status: merged as PR #153 (`458a502`) after `build-and-test` and
`kurncore-linux` passed. The physical matrix remains a release gate.

#### PR 2 — H2 versioned-schema baseline

Status: merged as [PR #155](https://github.com/carlosmazzei/Kurn/pull/155)
(`a14fab3`) after `build-and-test` and `kurncore-linux` passed — see "Current
handoff" above.

Objective: establish an explicit schema/migration contract before another model
change lands.

Scope:

1. Centralize the complete SwiftData model graph currently embedded in
   `KurnApp` so production, screenshot containers, and `TestModelContainer`
   cannot diverge.
2. Declare the graph as the first `VersionedSchema` and add an explicit
   `SchemaMigrationPlan`.
3. Investigate and test adoption of the existing unversioned production store;
   do not assume SwiftData will migrate it automatically.
4. Commit synthetic fixtures for the oldest supported released layouts and
   round-trip relationships, transcript/summary JSON, checkpoints, and capture
   recovery state. **Delivered as `KurnTests/LegacyStoreAdoptionTests.swift`**,
   which generates the fixture at run time (a store built with a bare,
   unversioned schema, populated with one of every model plus relationships/
   checkpoint/capture-recovery state) rather than a committed binary: no app
   version before this PR ever declared a schema version, so there is no
   earlier released layout to fabricate, and hand-crafting a binary SwiftData
   store without Xcode was not judged reliable or independently verifiable in
   this environment. The test still exercises the real open/adopt path on
   CI's macOS runner.
5. Make schema/version selection injectable through `ModelContainerBootstrap`.
6. Do not add backup/salvage UI or remove the startup `fatalError` in this PR.

Primary files:

- `Kurn/KurnApp.swift`
- `Kurn/Infrastructure/ModelContainerBootstrap.swift`
- all SwiftData model types under `Kurn/Models/`
- `KurnTests/TestSupport.swift`
- `KurnTests/ModelContainerBootstrapTests.swift`
- new synthetic migration fixtures/tests

Acceptance:

- Current stores and every committed fixture open without silent reset.
- Production and test containers consume one centralized schema definition.
- A future non-additive model change requires an explicit migration stage and
  fixture.
- Debug and Release builds, migration tests, full simulator CI, and KurnCore pass.

#### PR 3 — H2 recoverable bootstrap state machine

Status: merged as [PR #157](https://github.com/carlosmazzei/Kurn/pull/157)
(`12850ae`) after `build-and-test` and `kurncore-linux` passed on the first
push — see "Current handoff" above. Item 6 from the roadmap's H2 plan ("make
store/file protection verification part of bootstrap") was deliberately not
in this PR's scope — it's PR 4's.

Objective: remove the recoverable production launch crash path.

Scope:

1. Add a boot coordinator with `waitingForProtectedData`, `opening`, `ready`, and
   `recoveryRequired`.
2. Classify protected-data unavailable, no-space, incompatible migration, and
   suspected corruption with stable reason codes.
3. Register background callbacks before store open and defer/reschedule safely
   when protected data is unavailable.
4. Render a minimal store-independent recovery shell.
5. Remove the recoverable production `fatalError`; keep any DEBUG-only synthetic
   failure explicitly allow-listed.

Acceptance:

- Locked background launch and injected open failures do not crash-loop.
- No empty replacement store masquerades as successful recovery.
- Release-configuration launch tests cover each classified failure.

#### PR 4 — H2 protected backup, restore, salvage, and recovery UI

Status: merged into `main` as
[PR #158](https://github.com/carlosmazzei/Kurn/pull/158) — see "Current
handoff" above.

Objective: preserve original store bytes while giving the user explicit recovery
choices.

Scope:

1. Back up the store plus WAL/SHM consistently before migration.
   **Delivered as `ModelStoreBackupManager.createBackupIfLiveStoreExists`**,
   called before every open attempt (not only when a migration is known to be
   needed — there is no cheap way to know that in advance without opening the
   store), rate-limited to once per app version+build so an ordinary launch
   doesn't re-copy the whole store every time.
2. Protect backups and retain bounded generations with app/schema metadata.
   **Delivered**: each generation is `RecordingProtection`-stamped, carries a
   `metadata.json` (schema version, app version/build, timestamp), and
   `pruneOldGenerations` keeps the newest 3.
3. Offer retry after unlock/free-space, diagnostics export, restore, salvage to
   a separate container, and confirmed fresh start. **Delivered**, with one
   scoping note on salvage: it tries the production schema/migration plan
   first, then a bare unversioned schema with no migration plan, both against
   an isolated read-only (`allowsSave: false`) copy — this recovers data when
   the live failure was transient/environmental or a migration-plan
   bookkeeping issue, but a genuinely corrupt SQLite file or a real
   un-migratable schema mismatch fails salvage exactly as it failed live.
   That is inherent to what "salvage" can mean without a corpus of real
   corrupt stores to test repair heuristics against, not a shortfall of this
   implementation specifically.
4. Verify protection on the store directory and sidecars during bootstrap.
   **Delivered** as `ModelStoreProtection.applyAndVerify`, wired into
   `ModelStoreBootCoordinator.attemptOpen()` after a successful `makeStore()`;
   a verification failure discards the just-opened container and routes to
   `.recoveryRequired(.protectionVerificationFailed)` rather than handing out
   an unverified store.

Acceptance:

- Backup/restore and salvage fault points preserve the original bytes. Backup
  only ever copies; restore and confirmed fresh start quarantine (move, never
  delete) the live store before replacing it — proven in
  `ModelStoreBackupManagerTests` against a real temporary directory.
- Fresh start is never automatic — only reachable from the recovery view's
  explicit, double-confirmed (`kurnDialog`) action.
- N-1/N-2 fixtures preserve relationships and recovery state. Satisfied the
  same way PR 2 satisfied it: this is still the app's first-ever versioned
  schema, so there is no earlier released layout to fabricate as an N-1/N-2
  fixture — `LegacyStoreAdoptionTests` (PR 2) remains the adoption proof, and
  `ModelStoreBackupManagerTests`/`ModelStoreSalvageTests` prove this PR's new
  mechanisms independently.

#### PR 5 — H3 fail-closed protected storage and quarantine

Status: merged as [PR #162](https://github.com/carlosmazzei/Kurn/pull/162)
(`fd4b417`) — see "Current handoff" above.

Objective: stop automatic loss or unprotected placement of original audio.

Scope:

1. Make recording-directory creation/verification throwing; remove the
   unverified fallback path for writers.
2. Move unmatched, malformed, unreadable, and collision-ambiguous originals to
   protected quarantine instead of deleting them.
3. Persist size/date/reason metadata and expose recover/export/confirmed-delete.
4. Keep derived copies separately disposable.

Acceptance:

- No original is automatically deleted because metadata is absent or malformed.
- No privacy-sensitive writer falls back outside verified protected storage.
- Collision and filesystem fault fixtures preserve all ambiguous copies.

#### PR 6 — H3 durable mutation journal and protected trash

Status: merged into `main` as commit `d7e3dee`.

Objective: coordinate SwiftData and filesystem changes without pretending they
share a transaction.

Scope:

1. Journal create/finalize/delete/replace intent and idempotent steps.
2. Delete by durable intent, protected trash move, model commit, then retryable
   purge.
3. Replay or roll back unfinished operations before heuristic reconciliation.
4. Migrate meeting/recording deletion and compaction/replacement boundaries.
5. Report residual files accurately for delete-all.

Acceptance:

- Every injected journal crash point converges after relaunch.
- Pre-commit failure restores originals; post-commit failure leaves only a
  retryable purge.
- Replaying any operation multiple times is safe.

#### PR 7 — H3 versioned authoritative JSON envelopes

Status: merged into `main` as commit `e7a156a`, extending the envelope to the
transcription checkpoint. Operation reports do not exist yet (H5); they adopt
the envelope when introduced.

Objective: distinguish corruption from legitimate empty content.

Scope:

1. Separate authoritative JSON from disposable/preferences JSON.
2. Add version, payload, checksum, and typed decode outcomes while preserving raw
   bytes.
3. Remove `Data()`/empty-array fallback at transcript, summary, checkpoint, and
   operation-report boundaries.
4. Read legacy payloads and write envelopes incrementally.

Acceptance:

- Truncated, wrong-version, and checksum-invalid payloads are explicit recovery
  states, never empty successful content.
- Encode failure blocks the authoritative commit.

#### PR 8 — H4 pipeline fingerprint and checkpoint validation

Objective: prevent incompatible transcription work from being spliced together.

Status: merged as [PR #165](https://github.com/carlosmazzei/Kurn/pull/165)
(commit `08a0192`) — this session has no macOS/Xcode toolchain, so per
"Verifying without a local macOS/Xcode toolchain" nothing here was claimed
to compile or pass locally before merge; the GitHub `iOS CI` result on the
PR was the source of truth. `build-and-test` failed once on the first push
(a real bug: `TranscriptionPipelineFingerprint`'s duration-jitter tolerance
was applied only in the initializer, so a value set after construction — as
the test itself does, and as synthesized `Codable` decode also does — stored
the raw unrounded duration); the fix moved the hundredths-rounding into
`==` instead of the initializer, and the next push was green.

Scope:

1. Fingerprint source ID/size/duration/digest, preprocessing, VAD, language,
   ASR/provider/exact model, algorithm versions, compaction map, and chunk ranges.
2. Compute source digest incrementally and cache it only with validated metadata.
3. Validate finite monotonic bounded spans and exact chunk-plan identity.
4. Restart safely rather than trusting incompletely identified cloud/legacy work.

Acceptance:

- Mutating any fingerprint component invalidates reuse without touching source
  audio.
- Corrupt checkpoint structure never reaches fusion.

**What shipped.** `TranscriptionPipelineFingerprint`
(`Kurn/Models/TranscriptionPipelineFingerprint.swift`) covers item 1: source
file size, duration (rounded to hundredths so two `AVURLAsset` loads of the
same file can't jitter into a spurious mismatch), a SHA-256 digest of the
*original* recording's bytes, the effective preprocessing engine, VAD engine,
language, transcription engine, the exact provider/model axis
(`checkpointProviderID`, unchanged from before this PR — the cloud provider id
for `.whisperAPI`, the weight-file variant for `.whisperCpp`), whether
VAD-compaction ran, and a SHA-256 digest of the compaction map itself (so two
runs that agree on "compaction ran" but produced a different map still
differ). `algorithmVersion` is a manual version constant to bump if a future
change to fusion's input shape or chunking semantics would make an old
checkpoint's spans unsafe even though every field above still matches — item 1's
"algorithm versions."
`Kurn/Infrastructure/PipelineDigest.swift` is the SHA-256 helper (`CryptoKit`,
so it lives in the app target rather than `KurnCore`, which has to stay
Linux-buildable): a streamed file digest via `FileHandle` (never holds a
multi-hour recording fully in memory), and order-sensitive digests over
`[TimeInterval]` (chunk-plan offsets) and `[TimelineSegment]` (the compaction
map).

**Item 2's "cache it only with validated metadata"** is satisfied narrowly:
the source digest is computed once per `transcribe()` call — not per chunk,
not per resume attempt within that call — and only when `fileSize > 0` and
`fileDuration` is finite and positive; an unreadable or malformed file gets
`sourceDigest = nil` instead of a digest of garbage or a partial read. This
session did not add a cross-launch persisted cache of the digest (e.g. on
`Recording`) — hashing a recording once per transcription attempt is cheap
relative to the chunk that follows it (single-digit milliseconds to low
seconds for a multi-hour recording at local disk speeds), so the "compute
incrementally" half of item 2 is met, but nothing here avoids recomputing it
across separate app launches that each resume the same interrupted run. If
that ever shows up as measurable overhead, the natural place to cache it is
next to `Recording.fileSize` (same "cheap to recompute, safe to leave stale
until refreshed" shape).

**The exact chunk plan is deliberately not inside the fingerprint struct.**
It can't be known until chunking has actually run — which happens inside
`WhisperTranscriber`/`WhisperCppTranscriber`, one layer below where the
fingerprint is built in `TranscriptionService.transcribeGated`. Instead,
`TranscriptionCheckpoint.chunkPlanDigest` (a `PipelineDigest.sha256Hex(of:
chunks.map(\.offset))`) is threaded through
`ChunkedTranscriptionRunner.Progress.planDigest`, and `ChunkedTranscriptionRunner.run`
requires `resume.planDigest == planDigest` before accepting a resume — item 3's
"exact chunk-plan identity." This is strictly tighter than the old
`resume.totalChunks == chunks.count` check: two plans with the same chunk
*count* can still be cut at different offsets (different VAD/compaction
output), and the old check would have wrongly accepted that resume
(`ChunkedTranscriptionRunnerTests.mismatchedResumePlanDigestStartsOverEvenWithSameChunkCount`
pins this).

**Item 3's span validation** is `TranscriptionCheckpoint.isStructurallyValid`:
`completedChunks` within `0...totalChunks`, and every span finite,
non-negative, end ≥ start, within the *original* recording's duration plus a
30-second slack, and not jumping backwards by more than that slack. The slack
is deliberate and documented in the type: spans live on the engine-input
timeline (shorter than the original when compaction removed silence), so this
bound is a gross-corruption catcher, not an exact re-derivation of the
compacted timeline. `transcribeGated`'s resume gate and
`TranscriptionRecovery.sweepStaleTranscriptions` both check this before
trusting a checkpoint; a structurally invalid checkpoint is treated the same
as `.corrupted` (manual retry), never silently repaired or partially trusted.

**Item 4, restart-safety, has two concrete mechanisms.** First,
`TranscriptionPipelineFingerprint.==` requires *both* sides to carry a
non-`nil` `sourceDigest` before comparing anything else — an unverifiable
source (unreadable file, non-finite duration) can never match, including
against another equally-unverifiable fingerprint, which is what stops two
different unverifiable runs from accidentally looking identical. Second, and
stated plainly as a one-time cost: `TranscriptionCheckpoint`'s Codable shape
changed (most fields moved under a new `fingerprint` property, plus the new
`chunkPlanDigest`), so a checkpoint written by any pre-PR-8 app version fails
to decode under the new type. `JSONStorage.decodeAuthoritative` already
has exactly the right fallback chain for this (H3 PR 2): try the envelope,
then try a legacy bare decode, and only call it `.corrupted` when both fail —
an old-shaped bare payload fails both, so it becomes `.corrupted`, not a
false "never checkpointed" or a spliced resume. The audio file is untouched;
a manual retry re-transcribes from scratch. This only affects a device with a
transcription genuinely in flight at the exact moment it updates across this
change.

**Tests.** `KurnTests/TranscriptionPipelineFingerprintTests.swift` (equality
requires every field including a non-nil, matching digest; mutating any one
field invalidates it; an unverified fingerprint never matches even itself;
Codable round-trip). `KurnTests/PipelineDigestTests.swift` (deterministic,
content- and order-sensitive, stable across read-buffer sizes, throws on a
missing file). `KurnTests/TranscriptionCheckpointTests.swift` gained
fingerprint-mismatch cases (source digest, preprocessing, VAD, compaction
digest) alongside the existing engine/language/compaction/provider ones, plus
`isStructurallyValid` cases (out-of-bounds `completedChunks`, non-finite/
negative/inverted span timestamps, a span far beyond the source duration).
`KurnTests/ChunkedTranscriptionRunnerTests.swift` gained the same-count/
different-offsets case above. A shared `TranscriptionCheckpoint.fixture(...)`
test helper (`KurnTests/TestSupport.swift`) keeps the now-larger checkpoint
construction terse across the three test files that build one directly
(`TranscriptionCheckpointTests`, `TranscriptionRecoveryTests`,
`LegacyStoreAdoptionTests`).

**Next code work after PR 8 merged: H4 PR 9 — throwing chunk commits and
bounded operation states.** Started from updated `main`, per below.

#### PR 9 — H4 throwing chunk commits and bounded operation states

Objective: make durable checkpoint state gate forward progress.

Status: implemented, merged into `main` as [PR #166](https://github.com/carlosmazzei/Kurn/pull/166).

Scope:

1. Make chunk completion `async throws`.
2. Do not start chunk N+1 until N is durably committed.
3. Persist queued/running/paused/deferred/retryScheduled/permanentFailure/
   completed with reason, attempt, nextAttemptAt, and last transition.
4. Bound retries by stage and fingerprint.

Acceptance:

- A checkpoint save failure stops the run.
- Process death loses at most the in-flight chunk.
- Foreground activation cannot create endless or repeated paid work.

**What shipped (items 1, 2, 4).** `ChunkedTranscriptionRunner.Progress`'s
consumer, `onChunkCompleted`, changed from `(@Sendable (Progress) -> Void)?`
to `(@Sendable (Progress) async throws -> Void)?` and the loop now does
`try await onChunkCompleted?(state)` instead of firing it and moving on —
item 1 and, directly, item 2: a thrown error propagates out of `run` and the
`for` loop never reaches chunk N+1. `TranscriptionService.CheckpointHandler`
and the `checkpointSink` closure built in `transcribeGated` carry the same
`async throws` shape up to `TranscriptionViewModel`. There,
`onCheckpoint` no longer does `continuation.yield(.checkpoint($0))` into the
`AsyncStream` it shared with phase/warning updates (removed —
`PipelineEvent` dropped its `.checkpoint` case entirely); it calls the new
`storeCheckpointDurably(_:for:completedChunksAtAttemptStart:)` directly,
which sets `recording.transcriptionCheckpoint` and calls
`modelContext.save()` inline, throwing `AppError.persistenceFailed` on a
save failure. Since the pipeline already awaits this before continuing, a
save failure is caught by `transcribe(_:language:config:)`'s existing
`catch let appError as AppError` block — same handling as every other
pipeline failure — marking the recording `.failed` with its checkpoint
intact, rather than the old behavior (log to `self.error`, keep going with
whatever was last in memory). Removing the `AsyncStream` path for
checkpoints also removes a subtlety instead of adding one: by the time
`transcriptionService.transcribe(...)` returns, every checkpoint save has
already completed inline, so there's no "enqueued but not yet applied"
checkpoint state left to race against `saveTranscript` clearing it on
success — the comment above the `AsyncStream` setup in
`TranscriptionViewModel.swift` was updated to say so.

**Bounded automatic recovery (item 4).** `Recording.automaticResumeAttempts`
(`Int`, defaulted to `0` — no migration needed, same pattern as `fileSize`)
counts consecutive *automatic* resume attempts that made no forward
progress. `TranscriptionViewModel.resumePendingTranscriptions` — the one
choke point both the foreground-activation and `BGProcessingTask` resume
paths call — gates every row through the new `admitAutomaticResume`: under
`TranscriptionViewModel.maxAutomaticResumeAttemptsWithoutProgress` (3), the
counter increments and is persisted *before* `startTranscription` runs (so a
crash mid-attempt still counts against it on the next launch) and the
resume proceeds; at the limit, the row is marked `.failed` instead —
checkpoint kept, so a manual retry still resumes from the last completed
chunk — which is the acceptance criterion "foreground activation cannot
create endless or repeated paid work" directly. `storeCheckpointDurably`
resets the counter to `0` the first time an attempt saves a chunk beyond
`completedChunksAtAttemptStart` — a baseline captured once, in
`transcribe(_:language:config:)`, before the attempt does anything, **not**
read fresh from whatever's currently stored. That distinction matters
because a checkpoint written before this PR — or one whose
`TranscriptionPipelineFingerprint` no longer matches after a settings change
— makes `transcribeGated` restart the chunk plan from zero; the freshly
restarted run's own first saved chunk (`completedChunks == 1`) must still
count as progress even though it's numerically lower than the abandoned
prior run's stored value. Comparing against a fixed attempt-start baseline
gets this right; comparing against "whatever `recording.transcriptionCheckpoint`
currently says" (an earlier version of this change) would not have.

The bound itself is a pure, unit-tested static function —
`TranscriptionViewModel.canAttemptAutomaticResume(afterPriorAttempts:)` —
the same shape `isResumableCancellation` already established, so the
threshold is testable without a `Recording`/`ModelContext`.
`TranscriptionViewModel.resetAutomaticResumeBudget(for:)` is called from
every manual entry point (`MeetingDetailActions.startTranscription`, and
`TranscriptionViewModel.retranscribeAll` per recording) so a deliberate user
action always gets a fresh budget regardless of how many unattended
attempts already failed — the plan's "eventually requires user action" half.

**Split into a new file to stay under SwiftLint's file-length limit.**
PR 8 already left `TranscriptionViewModel.swift` at 897 lines, one PR away
from the 900-line error threshold; this PR's additions would have pushed it
to 993. The new checkpoint/budget methods
(`storeCheckpointDurably`, `admitAutomaticResume`, `resetAutomaticResumeBudget`,
`resumePendingTranscriptions` — moved along with its `admitAutomaticResume`
call site — and the two `static` bound helpers) live in
`Kurn/ViewModels/TranscriptionViewModel+ResumeBudget.swift`, the same reason
`TranscriptionViewModel+CrossMeetingSpeakerMatch.swift` exists. `activeRecordings`
lost its `private` (now plain `internal`, with a comment saying why) so the
new file can reach it, the same treatment `modelContext` already had for the
`CrossMeetingSpeakerMatch` split.

**Tests.** `KurnTests/ChunkedTranscriptionRunnerTests.swift` gained
`checkpointSaveFailureStopsTheRunBeforeTheNextChunk`, proving a throwing
`onChunkCompleted` stops the loop at the chunk it failed on and never
reaches the next one. `KurnTests/TranscriptionResumeBudgetTests.swift` is
new: the pure bound's boundary (attempts under/at/over the max),
`resetAutomaticResumeBudget` zeroing the counter, an exhausted-budget
recording ending `.failed` with its checkpoint intact without a background
pipeline task ever starting (safe and deterministic because
`admitAutomaticResume` returns `false` before `startTranscription` is
called), and an under-budget recording's counter incrementing before
`resumePendingTranscriptions` returns. The last two tests use
`captureState: .ready`/`.recoveryNeeded` deliberately: an exhausted row
never reaches `startTranscription`'s `isReadyForConsumption` gate regardless
of capture state, while the under-budget row is built `.recoveryNeeded` so
`startTranscription` is a synchronous no-op — this isolates both tests to
the budget bookkeeping itself, without racing a real `TranscriptionService`
pipeline against a nonexistent audio file inside a unit test (`TranscriptionService`
is a concrete, non-injectable dependency of `TranscriptionViewModel`, so an
end-to-end test of the "under budget, pipeline actually runs" path isn't
feasible here without a larger refactor to inject it — left as a known gap
rather than attempted speculatively).

**Known gaps, stated plainly.**

- **Item 3 (the full explicit operation-state enum) is not implemented.**
  This PR's three acceptance criteria are met on top of the existing
  `TranscriptionStatus` enum plus the new `automaticResumeAttempts` counter,
  which is materially simpler than "queued/running/paused-by-user/
  deferred-by-system/retry-scheduled/permanent-failure/completed with reason
  codes, attempt count, and `nextAttemptAt`." Revisit only if a concrete need
  for the richer model shows up (e.g. a "retrying in 2 minutes" UI needing an
  actual scheduled time, not just a counter).
- **`storeCheckpointDurably`'s own save-failure path is not directly unit
  tested.** `TranscriptionViewModel.modelContext` is a concrete `ModelContext`,
  not behind an injectable seam the way `RecordingLifecycleSaving` makes H1's
  SwiftData commits fault-injectable — adding that seam here was judged
  out of scope for this PR. The throw-and-stop *mechanism* is covered
  generically at the `ChunkedTranscriptionRunner` level instead
  (`checkpointSaveFailureStopsTheRunBeforeTheNextChunk`).
- **Bound retries "by stage and fingerprint" (item 4) is implemented per
  recording, not per (stage, fingerprint) pair.** In practice a recording
  only ever has one in-flight fingerprint at a time, so this distinction
  doesn't currently matter, but it means the counter doesn't independently
  track "this specific configuration has failed N times" if the pipeline
  configuration changes between exhausted attempts — see the attempt-start
  baseline reasoning above for why a configuration change is still handled
  correctly for the *progress-reset* half of the logic, even without
  per-fingerprint bookkeeping.

#### PR 10 — H4 expensive generated-artifact operation state

Objective: apply durable multi-step semantics selectively to summary, wiki,
document, and correction jobs.

Status: implemented, merged into `main` as [PR #167](https://github.com/carlosmazzei/Kurn/pull/167) (commit `663ab09`).

Acceptance:

- Completed safe map stages may resume; otherwise restart is explicit.
- Partial prose or JSON is never displayed as final.

**What shipped.** "Partial prose or JSON is never displayed as final" was
already true before this PR: `TranscriptionViewModel.generateSummary` only
inserts a `Summary` row after `SummaryService.generate` returns successfully,
and `WikiCoordinator.replaceArticle` is only called after `WikiService.generate`
returns non-empty markdown — a failed or cancelled run leaves whatever
existed before untouched in both cases. The actual gap was resumability: the
staged map-reduce loop behind long summaries and wikis had none, so an
interrupted staged run always re-condensed every block — for a cloud
provider, re-paying for all of them — from scratch.

`SummaryMapCheckpoint` (`Models/SummaryMapCheckpoint.swift`) is the durable
progress record: a content digest (SHA-256 of the exact transcript text fed
to the map stage), provider id, exact model, the plan's block count, and the
notes condensed so far. `matches(...)` is the resume identity check and
`isStructurallyValid` the same "can never describe more blocks than the plan
has" sanity check `TranscriptionCheckpoint` already has for chunk counts.
`SummaryMapRunner` (`Services/SummaryMapRunner.swift`) is the loop itself,
built the same way `ChunkedTranscriptionRunner` was: kept independent of
`LLMProvider` (the condense call is injected) so the resume/skip logic is
unit-testable without a network mock. It seeds from `resume.completedNotes`
only when `resume.isStructurallyValid && resume.matches(...)` the exact plan
about to run, then condenses only the remaining blocks; after each new block
it builds an updated checkpoint and `try await`s `onStageCompleted` before
starting the next one — the same "not durable until this returns" contract
`ChunkedTranscriptionRunner.run`'s `onChunkCompleted` established in PR 9,
so a checkpoint-save failure stops the run at the last committed block
instead of risking the next block's cost on top of unsaved progress.

**One checkpoint field on `Meeting`, shared by Summary and Wiki.**
`Meeting.summaryMapCheckpointData` (`Models/Meeting.swift`, JSON `Data`, the
same pattern as `Recording.transcriptionCheckpointData`) is read/written
through `summaryMapCheckpoint`/`summaryMapCheckpointOutcome` computed
properties using `JSONStorage.encodeAuthoritative`/`decodeAuthoritative` —
the same versioned-envelope, corrupted-vs-empty distinction H3 PR 7
established for `Recording.transcriptionCheckpoint`. It is not per-artifact
because it doesn't need to be: `WikiService.generate` delegates to
`SummaryService.generate` using that service's own `notesTemplate` for the
map stage regardless of which caller triggered it, so for a given meeting's
content the map stage produces byte-identical notes whether a Summary run or
a Wiki run is condensing it. A Summary run and a Wiki run racing on the same
meeting can therefore share, or briefly overwrite, each other's progress
with no correctness risk — the worst case is redoing one already-completed
block, never spliced or incorrect notes, because both run on the same
`@MainActor` context that already serializes `modelContext.save()` calls.
`SummaryService.generate`/`mapReduce` gained `resume: SummaryMapCheckpoint?`
and `onMapStageCompleted` parameters threaded straight through to
`SummaryMapRunner.run`; `WikiService.generate` gained the same two
parameters and passes them straight through to `SummaryService.generate`
unchanged.

`TranscriptionViewModel.generateSummary` (moved to the new
`ViewModels/TranscriptionViewModel+Summary.swift`, see below) and
`WikiCoordinator.generate` both read `meeting.summaryMapCheckpoint` (only if
`isStructurallyValid`) as the resume seed before calling into
`SummaryService`/`WikiService`, pass a `storeSummaryMapCheckpointDurably`
closure as `onMapStageCompleted`, and clear `meeting.summaryMapCheckpoint =
nil` once the whole run — map and reduce — succeeds. Both
`storeSummaryMapCheckpointDurably` implementations take the meeting's `id`
rather than the `Meeting` itself and re-fetch it via
`FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })`:
`Meeting` is a SwiftData `@Model` and therefore not `Sendable`, and this
closure is the `@Sendable (SummaryMapCheckpoint) async throws -> Void`
`onMapStageCompleted` parameter — capturing the model object directly would
fail Swift 6 strict concurrency checking, the same reason
`TranscriptionViewModel+ResumeBudget.swift` and
`RecordingRecovery.swift` key their own cross-closure lookups on `UUID`
rather than the model instance.

**Deliberately excluded: `DocumentGenerationService`.** A `GeneratedDocument`
can be synthesized from multiple meetings' transcripts (by tag, by folder, or
an explicit multi-meeting selection) map-reduced into one run, so there is no
single `Meeting` to persist a checkpoint against — the same reason
`GeneratedDocument` already snapshots its sources instead of relating to
them (see `CLAUDE.md`'s "Derived artifacts" section). Left out of scope
for this PR rather than inventing a second, document-scoped checkpoint
location speculatively.

**Split into a new file to stay under SwiftLint's file-length limit.**
This PR's additions would have pushed `TranscriptionViewModel.swift` past
907 lines, over the 900-line error threshold PR 9 already left it one PR
away from. The entire `// MARK: - Summary` section (`startSummary`,
`cancelSummary`, `generateSummary`, and the new
`storeSummaryMapCheckpointDurably`) moved to
`ViewModels/TranscriptionViewModel+Summary.swift`, the same extraction
pattern as `TranscriptionViewModel+ResumeBudget.swift` and
`TranscriptionViewModel+CrossMeetingSpeakerMatch.swift`. `isSummarizing`,
`isCancellingSummary`, `summaryProgress`, `summaryTask`, and `summaryService`
each dropped their `private`/`private(set)` access modifier (with a comment
saying why) so the new extension file can reach them.

**Tests.** `KurnTests/SummaryMapCheckpointTests.swift` covers `matches`'s
exact-identity requirement and `isStructurallyValid`'s bounds check, plus a
`Codable` round trip. `KurnTests/SummaryMapRunnerTests.swift` mirrors
`ChunkedTranscriptionRunnerTests`: resuming skips already-condensed blocks;
a mismatched content digest, provider, or structurally invalid resume all
restart from zero; a fully-completed resume condenses nothing; and
`checkpointSaveFailureStopsTheRunBeforeTheNextBlock` proves a throwing
`onStageCompleted` stops the loop at the block it failed on. `KurnTests/
ModelTests.swift` gained a "Meeting.summaryMapCheckpoint" section verifying
the versioned-envelope write, the corrupted-vs-empty distinction on garbled
data, and that a newer run's checkpoint fully overwrites an older one.

**Known gaps, stated plainly.**

- **No end-to-end test exercises `TranscriptionViewModel.generateSummary` or
  `WikiCoordinator.generate` resuming an interrupted staged run against a
  real (mocked) `LLMProvider`.** `SummaryMapRunnerTests` proves the loop
  itself is correct in isolation, the same gap PR 9 stated for
  `storeCheckpointDurably`'s own save-failure path — the throw-and-stop
  mechanism is covered generically rather than through the concrete
  view-model/coordinator call sites, since neither `SummaryService` nor
  `WikiService` is behind an injectable seam today.
- **The narrow concurrent Summary+Wiki race on one meeting is reasoned about,
  not tested.** Both writers run on the same `@MainActor`, so there is no
  interleaving that produces a torn or spliced write, but no test forces the
  two generations to actually overlap and inspects the resulting checkpoint.
- **`DocumentGenerationService` has no durable map-stage resumability.** See
  above — deliberately out of scope, not forgotten.

**Next code work: H5 — typed stage outcomes, pipeline report, and the final
integrity gate (PRs 11–12 below).** PR 10 merged as commit `663ab09`, so H5
starts from updated `main`. H4's plan is otherwise closed except item 3 (the full explicit
operation-state enum), left deliberately deferred per PR 9's own handoff.

### Phase B — Visible degradation and integrity

#### PR 11 — H5 typed stage outcomes and pipeline report

Status: merged into `main` as
[PR #168](https://github.com/carlosmazzei/Kurn/pull/168) (commit `d9f5120`);
CI was the verification of record, since the Apple toolchain is unavailable in
the agent environment.

Add requested/effective engine, succeeded/degraded/skipped/failed outcome, stable
reason, and safe diagnostics to every pipeline stage. Cancellation stays
throwing. Persist the aggregate report beside the transcript.

What landed:

- `Packages/KurnCore/Sources/KurnCore/Pipeline/PipelineReport.swift` —
  `PipelineStage`, `PipelineStageOutcome`, `PipelineStageReason`,
  `PipelineStageReport`, `PipelineReport` and `PipelineReportBuilder`. Pure,
  `Codable`, `Sendable`. There is deliberately **no** free-text or
  `underlyingError` field: the report is persisted and is a diagnostics-export
  candidate, so a provider message, file name or URL must not be able to reach
  it — a stage needing more detail adds a `PipelineStageReason` case instead.
  `skipped` and `degraded` stay distinct (a stage nobody asked for is not a
  warning; a requested stage that stepped down is), and `overall` takes the
  worst outcome.
- `TranscriptionService` builds one report per run:
  `TranscriptionServiceInputPreparation.swift` reports preprocessing (including
  the fall back to the original audio, which the returned URL alone does not
  reveal), language detection (a detector returning the caller's hint is its
  only "could not detect" signal, so that is recorded as the hint being used,
  never as successful detection) and VAD; `transcribeGated` reports compaction
  (declining to compact is `skipped`, a thrown failure is `degraded`) and
  transcription, returning them as values because it can run concurrently with
  diarization; diarization maps the three ways its result can differ from the
  request (selection stepped down without model consent, engine fallback to a
  synthetic whole-clip turn, empty output) to distinct reasons.
- `FluidAudioDiarizer.DiarizationOutcome` carries a `degradation` reason, so a
  single synthetic turn is no longer indistinguishable from a genuine
  one-speaker meeting.
- `TranscriptCorrecting` returns `TranscriptCorrectionResult` (segments +
  outcome + reason) instead of a bare array, because "no usable provider",
  "nothing eligible" and "ran clean" were previously the same value. Every
  correction batch coming back empty is `failed`; some of them is `degraded`.
  Cancellation is unchanged and still stops the run by throwing further up the
  pipeline — it is never turned into an outcome in the report.
- `Transcript.pipelineReportData` persists the encoded report in the same save
  as the segments, so a durable transcript can never exist without the record
  of how it was produced. It is optional: `nil` means *unknown* (a transcript
  predating this field, or bytes that no longer decode), never *clean*.
- Tests: `PipelineReportTests` (KurnCore) pin the Codable round trip, ordering
  and replacement semantics, `skipped` not being a warning, the worst-outcome
  aggregate, fallback engine preservation, and that the encoded form contains
  only closed-vocabulary values — the check that fails if a free-text field is
  ever added. `ModelTests` pin the stored round trip and the
  unknown-is-not-clean rule.

Still open for PR 13 rather than here: surfacing completed-with-warnings in the
UI. The report is durable now; nothing reads it yet.

#### PR 12 — H5 final integrity gate and atomic artifact replacement

Validate source readability, span bounds/order, speech/text consistency, speaker
attribution, and correction identity. Keep the previous transcript, summary, and
index until the replacement is valid and durable.

Status: merged into `main` as
[PR #169](https://github.com/carlosmazzei/Kurn/pull/169) (commit `e3c1c54`);
CI (`build-and-test`, `kurncore-linux`) was green on the first push — the
verification of record, per "Verifying without a local macOS/Xcode
toolchain" in `CLAUDE.md`.

**What shipped.** Two gaps existed before this PR. First,
`TranscriptionService.transcribe`'s pipeline — the ASR engine, `TranscriptFusion`,
an optional LLM `TranscriptCorrecting` conformer — is pure and cannot throw, so
a structurally broken result (fusion losing every span, a corrupted timestamp,
a blank segment) had nothing stopping it from reaching
`TranscriptionViewModel.saveTranscript`, which deletes any existing
`Transcript` unconditionally once JSON encoding succeeds
(`TranscriptionViewModel.swift:477-517`) — encoding a structurally-broken
result succeeds just as easily as encoding a good one, so that guard caught
nothing semantic. Second, `TranscriptCorrecting`'s contract ("never throw,
return exactly `segments.count` segments, in the same order, with every field
except `.text` unchanged") was documented on the protocol
(`PipelineStages.swift`) but never checked at the one call site
(`TranscriptionServiceCorrection.correctIfRequested`) — a future or
misbehaving conformer could have silently dropped, reordered, or duplicated
segments with no defense.

`TranscriptIntegrityGate` (`Packages/KurnCore/Sources/KurnCore/Pipeline/
TranscriptIntegrityGate.swift`) is a pure, Linux-buildable type closing both,
mirroring `TranscriptionCheckpoint.isStructurallyValid`'s existing tolerance
(30s slack) rather than inventing a new one:

- `validate(segments:sourceDuration:hadTranscribedInput:)` checks: the source
  duration itself is finite and non-negative (`sourceUnreadable`); an empty
  `segments` array is only a failure when the engine produced spans that fusion
  then lost (`emptyOutputFromNonEmptyInput`) — a genuinely silent recording
  producing no segments is not; every span's timestamps are finite,
  non-negative, non-inverted, and within source duration + slack
  (`segmentOutOfBounds`); spans don't jump backwards by more than the slack
  (`segmentsOutOfOrder`); and every segment carries non-blank text
  (`emptySegmentText`) and a non-blank speaker label (`unattributedSpeaker`).
- `correctionPreservedIdentity(original:corrected:)` verifies a corrector's
  output segment-for-segment: same count, same id at each position, and every
  field except `.text` byte-identical.

`TranscriptionService.transcribe` calls `validate` right after correction,
before building `Output` (`TranscriptionService.swift`, step 7): a failure
throws `AppError.transcriptIntegrityFailed(String)` (the closed-vocabulary
`TranscriptIntegrityFailure` raw value, never free text) instead of returning.
Because `saveTranscript` only runs after `transcribe` returns successfully,
throwing here is what "keep the previous transcript until the replacement is
valid and durable" means concretely — no new plumbing was needed, since the
existing `AppError` catch path in `TranscriptionViewModel.transcribe` already
marks the recording `.failed` with its checkpoint intact (the same handling
every other pipeline failure gets) without ever touching
`recording.transcript`. `TranscriptionServiceCorrection.correctIfRequested`
calls `correctionPreservedIdentity` right after the corrector returns: a
violation discards the corrector's segments in favor of the pre-correction
ones and records the new `PipelineStageReason.correctionContractViolated`
reason (`PipelineReport.swift`) with a `.degraded` outcome — the same
fails-open shape an unusable provider already gets, so a misbehaving
conformer degrades the run instead of corrupting or failing it. In the actual
codebase both conformers (`NoOpTranscriptCorrector`, which returns its input
array unchanged, and `LLMTranscriptCorrector.apply`, which mutates only
`.text` on a copy of the original array by id lookup) already satisfy the
contract exactly, so this is a defensive backstop with no behavior change on
the happy path today.

**Summary and index already satisfied their half of this PR's scope before it
started.** `TranscriptionViewModel+Summary.swift`'s `generateSummary` always
inserts a new `Summary` row and never deletes an existing one — deletion is a
separate, explicit user action (`MeetingDetailActions.deleteSummary`) — so
"keep the previous summary" was already true. `SemanticIndexCoordinator.index`
computes new chunks (embedding, which can fail) before touching any old ones,
and only calls `replaceChunks(of:with:)` — one SwiftData transaction deleting
the old rows and inserting the new ones — after the new content is ready, so
"keep the previous index until the replacement is valid and durable" was
already true there too. Neither needed a change for this PR.

**Tests.** `Packages/KurnCore/Tests/KurnCoreTests/TranscriptIntegrityGateTests.swift`
covers both functions in isolation: valid segments pass; empty output is
accepted only when the engine had no input and rejected otherwise; a
non-finite/negative source duration, an inverted or wildly out-of-bounds span,
and a gross backward jump are each rejected while a slack-sized overrun or
mild reordering is accepted (mirroring
`TranscriptionCheckpoint.isStructurallyValid`'s own tolerance cases); blank
text and blank speaker labels are each rejected; and
`correctionPreservedIdentity` accepts a text-only change or an identical
array, and rejects a mismatched count, reordering, a different id at the same
position, and a changed timestamp, speaker label, or confidence.

**Known gaps, stated plainly.**

- **No end-to-end test exercises `TranscriptionService.transcribe` actually
  throwing `AppError.transcriptIntegrityFailed` and
  `TranscriptionViewModel.saveTranscript` never being reached.** The gate
  itself is proven in isolation (`TranscriptIntegrityGateTests`); the same gap
  PR 9 and PR 10 stated for their own throw-and-stop call sites — neither
  `TranscriptionService` nor `TranscriptionViewModel` is behind an injectable
  seam that would let a unit test force a real pipeline run to produce
  structurally invalid output.
- **"Atomic artifact replacement" for the transcript itself still rests on
  `saveTranscript`'s single `modelContext.save()` call**, not a durable
  intent/commit journal like `RecordingOperationJournal`'s. That was a
  deliberate choice, not an oversight: `SemanticIndexCoordinator.replaceChunks`
  already establishes "validate off-main, then delete+insert+save in one
  transaction" as sufficient precedent for this kind of swap in this codebase,
  and this PR's actual gap — as stated in the roadmap's own PR 12 description —
  was validity, not durability. A crash between validation and `save()` is the
  same "at most the in-flight write is lost, nothing is left half-swapped"
  guarantee SwiftData's own save transaction already gives every other model
  mutation in the app, not a new risk this PR introduces.
- **`unattributedSpeaker`/`emptySegmentText` are defensive, not currently
  reachable.** `TranscriptFusion.segments` never emits a segment with blank
  text (its `flush()` guards on `!currentText.isEmpty`) or an empty speaker
  label (it defaults to `"Speaker 1"` when `turns` is empty), and
  `TranscriptCorrectionGuardrail.accepts` already rejects a correction that
  empties a non-empty segment. These two checks exist for the same reason the
  correction-identity check does: to fail closed if a future engine or
  conformer breaks that invariant, not because a known path currently
  produces it.

#### PR 13 — H5 stage-specific recovery actions

Expose completed-with-warnings and retry the degraded stage without repeating
unrelated work where the architecture allows it. Integrate with H9 rather than
creating a second error system.

Status: implemented on branch `claude/resilience-roadmap-plan-fn23ki`; CI is
the verification of record, per "Verifying without a local macOS/Xcode
toolchain" in `CLAUDE.md`.

**What shipped.** `Transcript.pipelineReportData` (H5 PR 11) has been durable
since it landed, but nothing read it until this PR — a transcript could
complete with a degraded or failed stage and the UI would show it exactly the
same as a clean run. `MeetingDetailView`'s Transcript tab now renders a
`pipelineWarningsBanner(for:)` per recording whenever
`recording.transcript?.pipelineReport?.hasWarnings` is true: one line naming
every warning's stage (`PipelineStage.displayName`, new — the localization
seam for a stage named outside a code comment for the first time) joined by
comma, e.g. "Completed with warnings in: Speaker Separation, AI Correction."
This is deliberately a single sentence over `report.warnings`, not one row
per stage — `PipelineStageReason`'s eleven cases would have needed their own
localized phrase each to explain *why*, at real translation cost across seven
languages for detail a screenshot of the banner's retry action already
implies; naming the stage is enough to be actionable.

**Stage-specific retry, honestly scoped to where it's actually cheap.**
Every other stage in `TranscriptionService.transcribe` needs the original
audio, an upstream stage's output, or both — preprocessing fixed VAD's input,
VAD fixed the transcriber's input, diarization needs the audio file directly,
fusion needs both ASR spans and diarizer turns. None of those can be re-run
in isolation without either re-deriving or re-caching everything upstream of
them, which is exactly the kind of new durable intermediate state H4 already
weighed and left out of scope. **Correction is the one exception**: `TranscriptCorrecting.correct(segments:language:...)` takes only the already-fused segments and the meeting's language — nothing about the source audio,
ASR, or diarization. `TranscriptionViewModel.retryCorrection(_:language:config:)`
(`ViewModels/TranscriptionViewModel+CorrectionRetry.swift`, new — the same
file-length-driven extraction pattern as its `+ResumeBudget`/`+Summary`/
`+CrossMeetingSpeakerMatch` siblings) calls
`TranscriptionService.correctIfRequested` directly over the stored
transcript's current segments, guarded by a new `correctionRetryIDs: Set<UUID>`
so the same recording can't have two retries racing. Every other warning in
the banner falls back to the existing full re-transcribe action
(`pendingRetranscribe`'s confirmation dialog, unchanged) — repeating the rest
of the pipeline is unavoidable there, which the roadmap's own "where the
architecture allows it" already anticipated rather than promising universally.

**The retry path gets the same fail-closed guarantee PR 12 gave the main
pipeline, derived rather than re-verified against the source file.**
`correctIfRequested` already enforces `TranscriptIntegrityGate
.correctionPreservedIdentity` before trusting its own result (PR 12), so
whatever it returns here is either the original segments unchanged or the
original segments with only `.text` fields replaced — every timestamp is
therefore already known to be valid, because it's the same timestamp that
was already in the stored transcript. `retryCorrection` still calls
`TranscriptIntegrityGate.validate` before persisting, using
`original.map(\.endTime).max()` as the duration bound rather than re-reading
the recording's audio file: since identity preservation means the result's
timestamps can only be exactly the ones already in `original`, that bound is
sufficient without adding a second source-of-truth for "what counts as the
recording's duration" or paying to re-open the file for a retry that never
touches it. A gate failure surfaces `AppError.transcriptIntegrityFailed` and
leaves the stored transcript untouched, the same as the main pipeline. On
success, only the `.correction` entry of the transcript's `PipelineReport` is
replaced (`PipelineReportBuilder` seeded from the existing report, then one
new record call) — every other stage's history from the original run is
preserved, since nothing else ran.

**A stale-write guard, not a lock.** Before writing back,
`retryCorrection` re-checks `recording.transcript?.segments == original`
(captured at the start of the retry): if the recording was fully
re-transcribed while the correction retry was in flight, the retry's result
is silently discarded rather than overwriting the newer transcript with a
correction of stale content. `[TranscriptSegment]`'s existing `Hashable`
conformance (H1) is what makes this a plain equality check rather than new
machinery.

**Explicitly not attempted: integrating with H9.** The roadmap text says
"integrate with H9 rather than creating a second error system," but H9
(`docs/roadmap.md`'s "Started" row: `AppError.logCode` and the content-free
`ReliabilityEvent` vocabulary exist; action metadata, per-operation queues,
and a health/recovery UI do not yet) has no operation-report or recovery-action
model to integrate with today. This PR's banner reuses the *existing*
`AppError`/warning-banner presentation `diarizationWarningBanner` already
established, rather than inventing a second, parallel warning system of its
own — which is the concrete, buildable half of "don't create a second error
system" available before H9 itself exists. Revisit when H9's action-metadata
model lands.

**Known gaps, stated plainly.**

- **No end-to-end test exercises `retryCorrection` against a real (mocked)
  `LLMProvider`, or the banner's conditional rendering.** Same gap PR 9, PR
  10, and PR 12 each stated for their own view-model/UI glue: neither
  `TranscriptionService` nor `TranscriptionViewModel` is behind an injectable
  seam that would let a unit test exercise this without a live SwiftUI
  hierarchy and a mocked provider. `TranscriptIntegrityGate` and
  `PipelineStage.displayName` are otherwise covered by existing/adjacent
  `KurnCoreTests` and manual review; a `displayName` computed property has no
  existing test precedent in this codebase either (checked before deciding
  not to add one here).
- **The banner shows one combined sentence, not a per-stage reason.** A
  reader can see *which* stages warned but not *why* without opening
  Diagnostics — a deliberate scope cut against `PipelineStageReason`'s
  eleven-case translation cost, not an oversight. Revisit if user feedback
  says the stage name alone isn't actionable enough.
- **Retrying correction when the current settings no longer request it
  (e.g. the user turned AI Correction off since the failed run) re-runs
  `NoOpTranscriptCorrector` and reports `.skipped`/`.notRequested` rather than
  fixing anything.** This mirrors `retranscribeAll`/`retranscribe`, which
  already always use the *current* settings rather than the ones the failed
  run used — consistent with the rest of the app, not a new inconsistency.

### Phase C — Credentials and models

#### PR 14 — H7 typed Keychain and explicit credential save

Add a `KeychainAccessing` seam, preserve `OSStatus` privately, classify absent vs
locked/denied/transient, finish accessibility migration only after success, and
commit provider edits only on explicit Save after URL validation.

Status: implemented on branch `claude/resilience-roadmap-plan-fn23ki`; CI is
the verification of record, per "Verifying without a local macOS/Xcode
toolchain" in `CLAUDE.md`.

**What shipped.** `KeychainManager` (`Kurn/Infrastructure/KeychainManager.swift`)
used to collapse every Security-framework failure into the same value as "not
configured": `get` returned `nil` for a locked device exactly as it did for a
key that was never stored, and `set`/`delete` discarded their `OSStatus`
outright. That ambiguity is what let `migrateToBackgroundAccessible()` mark
itself permanently complete after a *failed* fetch — a locked device at first
launch (or any transient Security-framework error) looked identical to
"nothing to migrate," so the migration silently never ran for that device
again.

- **`KeychainAccessing`** (new protocol, mirroring `CloudSettingsSync.swift`'s
  `CloudKeyValueStore` seam over `NSUbiquitousKeyValueStore`) declares
  `get(_:) -> KeychainReadOutcome`, `set(_:for:) -> KeychainWriteOutcome`,
  `delete(_:) -> KeychainWriteOutcome`. `KeychainReadOutcome` is
  `.found(String)` / `.absent` / `.failed(KeychainFailureReason)`;
  `KeychainWriteOutcome` is `.success` / `.failed(KeychainFailureReason)`.
  `KeychainFailureReason` (`.locked` / `.denied` / `.transient`) is the only
  thing that ever leaves the type — `KeychainManager.classify(_:)` maps the
  raw `OSStatus` (`errSecInteractionNotAllowed` → `.locked`;
  `errSecAuthFailed`/`errSecNotAvailable` → `.denied`; everything else →
  `.transient`) and the `OSStatus` itself never escapes this one function, per
  the plan's "preserve `OSStatus` privately."
- **The many read-only call sites** (`ProviderFactory.summaryProvider`/
  `whisperProvider`, `ProviderModelsService.models`, `FoundationModelsProvider
  .isUsable`, `ProviderRow`'s configured/not-configured dot) don't need the
  classification — they only ever asked "do we have a key." A
  `KeychainAccessing` extension gives them `value(for:) -> String?` and
  `hasValue(for:) -> Bool`, both collapsing any failure to the same shape as
  absent, same as the old API's behavior — so none of them changed logic,
  only the method name at the call site (`get` → `value(for:)`).
- **`migrateToBackgroundAccessible()` rewritten** to only set the
  `"ai.kurn.keychain.migratedAfterFirstUnlock"` `UserDefaults` flag after a
  *confirmed* outcome: `errSecItemNotFound` (nothing to migrate — trivially
  complete) or every fetched item's re-save reporting `.success`. Any other
  fetch status, or any one item's re-save failing, leaves the flag unset so
  the next launch retries — exactly the "finish accessibility migration only
  after success" item, and the concrete fix for the ambiguity the header
  comment above describes.
- **Explicit-Save for provider credentials.** `ProviderEditor`
  (`Kurn/Views/SettingsProviderViews.swift`) used to write to the Keychain on
  every keystroke (`.onChange(of: key)`, independent of the toolbar Save
  button and of `canSave`'s URL validation) and delete immediately from a
  separate "Remove key" button. Both are gone: the key field is buffered in
  `@State` like every other field, `commitAndSave()` only reaches the
  Keychain when `key != originalKey` (so editing just the name/URL never
  touches a key the user didn't change), and only after the toolbar Save
  button — already disabled by `canSave` until `LLMHTTP.isValidBaseURL`
  passes — is tapped. `AddProviderView`'s flow already buffered the key and
  deferred the write to its own Save button; `ProvidersSettingsView`'s
  `onAdd` handler now also captures the write's outcome. A failed write in
  either flow surfaces the new `AppError.keychainAccessFailed(String)`
  (associated value is the closed-vocabulary `KeychainFailureReason` raw
  value, never a raw `OSStatus` or free text) via the existing `.errorAlert`
  pattern, and in `ProviderEditor` specifically leaves the sheet open (no
  `onSave`/`dismiss`) so the user can retry without losing their other
  edits — the same "keep the previous state until the replacement is
  durable" shape H5 PR 12 established for transcripts, applied here to a
  Settings form instead of a transcript.
- **`ProviderEditor.onAppear`'s own read** now switches on the full
  `KeychainReadOutcome` rather than collapsing to `?? ""`: a `.failed` read
  leaves the field blank (the same as before) but also surfaces
  `AppError.keychainAccessFailed` immediately, rather than silently
  presenting "no key configured" when the real state is "couldn't check
  right now." `commitAndSave`'s `key != originalKey` guard means this can't
  cause data loss — an unread key is never overwritten by a Save the user
  didn't intend to touch it, since `originalKey` is also left blank
  alongside `key` in that branch.

**Tests.** `KurnTests/KeychainManagerTests.swift` (new): a `FakeKeychainAccessing`
proves the `KeychainAccessing` seam is genuinely usable as a mockable
abstraction — including that a forced `.failed` outcome is never silently
collapsed to `.absent` at the raw `get(_:)` level, only by the convenience
extension that documents doing so on purpose; `KeychainManager.classify(_:)`
is pinned against literal `OSStatus` values
(`errSecInteractionNotAllowed`/`errSecAuthFailed`/`errSecNotAvailable`/an
arbitrary other value); and the concrete `KeychainManager` is round-tripped
against the real Keychain (set → get → overwrite → get → delete → get, empty
value deletes, deleting an absent account is still `.success`) using a
dedicated test-only account so this suite doesn't need `.serialized` against
`ProviderFactoryTests`. `ProviderFactoryTests.swift`'s `withClearedKey`/
`withKey` helpers were updated for the new `get` signature (renamed to
`.value(for:)` at the two call sites that only needed the old `String?`
shape) with no behavior change.

**Known gaps, stated plainly.**

- **No locked-device migration test.** The simulator cannot simulate a
  locked Keychain any more than H1 could simulate iOS Data Protection —
  `migrateToBackgroundAccessible()`'s locked/denied/transient branches are
  verified by reading the code and by the `classify(_:)` unit tests, not by
  an end-to-end test that actually locks the device mid-migration. Same
  category of gap H1 named for its own physical-protection matrix.
- **No end-to-end UI test exercises `ProviderEditor.commitAndSave`'s
  Keychain-failure path or `saveError`'s alert presentation.** Same
  known-gap pattern H5 PR 12/13 each stated for their own view/view-model
  glue: `ProviderEditor` calls `KeychainManager.shared` directly rather than
  through an injected `KeychainAccessing`, so a UI test can't force a
  Keychain failure deterministically without a larger dependency-injection
  change to the Settings views, which was judged out of scope here. The
  `KeychainAccessing` seam itself (item 1's actual ask) is proven usable via
  `FakeKeychainAccessing` in isolation instead.
- **Items 3–7 of H7's plan (model download consolidation, pinned revisions,
  atomic staging/replacement, storage-inventory verification, owned
  download tasks) are PR 15/16's scope, not touched here.**

#### PR 15 — H7 verified model staging, resume, and replacement

Unify app-managed whisper.cpp and sherpa-onnx download mechanics: immutable
revision, exact size, SHA-256/manifest, protected staging, retry, cancellation,
resume data, network policy, validation, and atomic replacement. Preserve the
previous valid model on every failure.

Status: implemented on branch `claude/resilience-roadmap-plan-fn23ki`; CI is
the verification of record, per "Verifying without a local macOS/Xcode
toolchain" in `CLAUDE.md`.

**What shipped.** `WhisperCppModelDownloader` and `SherpaOnnxModelDownloader`
used to call a bare enum of static functions (`ModelFileDownloader.fetch`)
that trusted a downloaded file the moment it cleared a loose "roughly half
the expected size" floor, and installed it by deleting whatever was there
first and then moving the new file in — a crash or a `replaceItemAt` failure
between those two steps left no model installed at all, not a corrupt one.

- **`ModelDownloading`** (`Kurn/Services/ModelFileDownloader.swift`, new
  protocol) is the injectable seam, mirroring the shape
  `KeychainAccessing` (PR 14) and `CloudKeyValueStore` give their own system
  dependencies. `ModelFileDownloader` is now an `actor` conforming to it
  (`.shared` for production; `init(protocolClasses:)` lets a test construct
  its own instance wired to `MockURLProtocol`) rather than a bare enum,
  because it needs to hold resume data between one interrupted attempt and
  the next for the same destination — mutable state that has to be
  protected from concurrent access. Both downloaders take a `downloader:
  any ModelDownloading = ModelFileDownloader.shared` parameter now, so
  production call sites are unchanged and tests can substitute a fake.
- **Verification is exact, not a loose floor.** `verify(_:minimumPlausibleBytes:)`
  checks the downloaded byte count against the server's own declared
  `Content-Length` exactly (falling back to the previous loose plausibility
  floor only when the server doesn't report a length at all) and, when the
  origin volunteers one, the file's SHA-256 against it.
  `linkedHashHex(from:)` reads HuggingFace's `X-Linked-ETag` header — set on
  an LFS-backed file's response to the raw hex Git LFS object ID, which for
  every binary model file this app fetches is a SHA-256 — and requires
  exactly 64 hex characters before trusting it as one, so a plain `ETag`
  (typically a quoted Git blob SHA-1, or an opaque cache key) is never
  mistaken for a checksum to verify against.
- **Atomic install, with a real rollback.** `install(_:at:expectedHashHex:)`
  uses `FileManager.replaceItemAt(_:withItemAt:backupItemName:)` to swap a
  verified download in atomically when something already exists at the
  destination, keeping the replaced file as a backup. If a hash was checked
  during download, the *installed* file is re-hashed too — a cheap re-check
  reusing the same digest, guarding against the move itself corrupting an
  already-verified transfer — and a mismatch restores the backup rather than
  just deleting it. A failure at transfer, verification, or install now
  always leaves the previous valid model exactly as it was, never absent and
  never silently corrupt, closing the item 3/5 "atomic staging directory" /
  "preserve the previous valid model on every failure" asks.
- **Resume data.** `Downloader` (the `URLSessionDownloadDelegate` bridge to
  async/await) captures resume data both from `URLSessionDownloadTask
  .cancel(byProducingResumeData:)` (user-initiated cancellation) and from
  `NSURLSessionDownloadTaskResumeData` in a `didCompleteWithError` failure's
  `userInfo` (a dropped connection). `ModelFileDownloader` keeps the most
  recent resume data per destination in memory and passes it to the next
  `fetch` call for that destination, so retrying — by re-triggering the same
  consent flow — continues the transfer instead of restarting from byte
  zero. In-memory only, so a relaunch (not just a backgrounding) loses it;
  see known gaps.
- **Cancellation.** `ModelDownloadController` now stores its download
  `Task` (`activeDownloadTask`) instead of firing an unstored one, adds a
  `cancelDownload()` that cancels it, and swallows `CancellationError`
  silently (the user asked for this, not a failure to surface). `Downloader
  .download`'s `onCancel` handler calls `task.cancel(byProducingResumeData:)`
  rather than `session.invalidateAndCancel()` — the latter was tried first
  and reverted, because it could race and tear the session down before the
  resume-data completion closure fired. `ModelDownloadProgressRow` gained an
  optional `onCancel` closure (`nil` renders no button, the row's previous
  shape) and all three call sites (`RecordingSettingsView`,
  `TranscriptionSettingsView` ×2) now pass `downloads.cancelDownload`,
  reusing the existing `common.cancel` localization key already present in
  all seven locales — closing item 7's "owned task and cancel/pause action."
- **Orphan cleanup.** A completed-but-not-yet-installed download is staged
  under a `kurn_model_` prefix in the temporary directory (mirroring
  `kurn_clean_`/`kurn_vad_`/etc.); `TempFileCleaner.prefixes` now includes
  it, so a crash between download and install is swept the same way every
  other pipeline temp file already is.

**What deliberately did not ship, and why: immutable revision pinning.**
Item 4 asks to "pin immutable model revisions ... before install." This PR
does **not** hardcode a pinned commit SHA or release digest for
`WhisperCppModel.downloadURL`, which still resolves against HuggingFace's
mutable `resolve/main` branch. Doing that responsibly requires fetching the
real, current commit SHA from HuggingFace to pin against, and this PR was
authored in an environment with no network path to `huggingface.co` (or
`api.github.com`) — confirmed by testing directly: both `curl` and
`WebFetch` against `huggingface.co` returned `EGRESS_BLOCKED`/403 through
the environment's proxy. A wrong hardcoded commit SHA, or one that stops
existing, would be worse than the status quo: every future download would
fail outright instead of merely being under-verified against a live
transfer. `sherpa-onnx`'s two models were *already* pinned before this PR
(the segmentation model's URL names an exact commit SHA,
`9403a6902bb58e3d5ae8c7e77c3422de279db2e0`, and the embedding model's URL
names an exact GitHub release tag) — that part of item 4 was pre-existing,
not new work here. What this PR adds instead, for both downloaders, is
verification against whatever integrity signal the origin volunteers *for
that transfer*, over HTTPS — exact size always, opportunistic SHA-256 when
offered — which the plan's own wording allows for ("verify a published
exact size plus SHA-256, **or a stronger signed manifest**"). A follow-up
authored with real network access to HuggingFace should still pin
whisper.cpp's revision; nothing here blocks that.

**Tests.** `KurnTests/ModelFileDownloaderTests.swift` (new) drives the real
`fetch` → `verify` → `install` sequence against `MockURLProtocol` (no real
network involved): a matching declared `Content-Length` installs, a
mismatched one is rejected and leaves nothing behind; a matching
`X-Linked-ETag` SHA-256 installs, a mismatched one is rejected, and a plain
short `ETag` is correctly never treated as a hash to check; an existing
file is replaced atomically with no leftover backup sibling; a verification
failure against an *existing* installed file leaves that original file
exactly as it was; and an already-plausible file on disk short-circuits
`fetch` with no network call at all (asserted via
`MockURLProtocol.capturedRequests.isEmpty`).

**Known gaps, stated plainly.**

- **Immutable revision pinning for whisper.cpp is not done** — see "What
  deliberately did not ship" above. This is the plan's item 4, half-closed
  (exact-size + opportunistic-hash verification shipped; the pinned-commit
  half needs real network access this environment does not have).
- **Resume data does not survive a relaunch**, only a backgrounding —
  it's held in `ModelFileDownloader`'s in-memory dictionary, never
  persisted. A force-quit or crash mid-transfer restarts from byte zero on
  the next attempt rather than resuming, unlike `TranscriptionCheckpoint`'s
  on-disk persistence for the transcription pipeline itself. Apple's own
  documentation is clear that resume data is best-effort across long gaps
  regardless, so this is a narrower gap than it might first appear, but it
  is real.
- **No automatic retry-with-backoff loop**, unlike `LLMHTTP.sendValidated`'s
  exponential backoff for provider calls. A failed or cancelled download
  only continues on the *next* explicit `fetch` call (i.e. the user
  re-opening the same consent flow); nothing here retries on its own after
  a transient failure.
- **No post-install health probe** (item 5's "then loading a small health
  probe") and **no storage-inventory verification of digest/version/
  protection/backup exclusion** (item 6) — both are PR 16's scope, not
  touched here. A model that installs cleanly is trusted to be usable; PR 16
  is what tells "verified installation" apart from "consented and present."
- **No cancellation-timing test.** `MockURLProtocol` has no "hang forever"
  stub type, so the resume-data-on-cancel path is exercised by code review
  and the `Downloader`/`ModelFileDownloader` design (see "What shipped"),
  not by an automated test that cancels mid-transfer.

FluidAudio remains a capability-limited adapter with preflight only until its
library exposes session/path-change control.

#### PR 16 — H7 model inventory and health probes

Separate consent, download state, verified installation, and runtime usability.
Verify digest/version/protection/backup exclusion and run a small post-install
health probe. Offer redownload for corruption.

### Phase D — Ownership, resources, and integrations

#### PR 17 — H8 resource cooldown and global admission scheduler

Replace sticky memory pressure with observed-at/cooldown/recheck state and add a
global actor-based permit/weight scheduler for preprocessing, ASR, diarization,
enhancement, and model loading.

#### PR 18 — H8 cancellation truth and bridge audit

Audit every `@unchecked Sendable`, `nonisolated(unsafe)`, continuation, and
callback bridge. Add exactly-once assertions/stress tests. Use real engine abort
hooks where available; otherwise report deferred cancellation instead of a false
timeout.

#### PR 19 — H8 ActivityKit authoritative lifecycle

Serialize start/update/end on one actor, retain/cancel the start task, bind every
mutation to recording/run ID, and ensure start-immediate-end cannot create a late
orphan.

#### PR 20 — H8 shared Watch protocol and idempotent external commands

Compile one protocol source into both targets. Add command IDs, timeout,
deduplication, ordered reconciliation, and acknowledgements for received,
state-changed, and durably-finalized. Intents report accepted, not actual capture,
until the recorder confirms it.

### Phase E — Actionable recovery and diagnostics

#### PR 21 — H9 structured errors and per-operation queues

Extend presentation metadata around `AppError` with category, severity,
retryability, safe explanation, private context, and recovery action IDs. Queue
blocking errors per operation and retain warnings in operation reports.
Cancellation is silent.

#### PR 22 — H9 bounded encrypted events and redacted export

Standardize content-free operation events, remove public raw error descriptions
from resilience paths, keep a protected bounded local buffer, and provide a
redaction preview plus short reference ID. Nothing uploads automatically.

#### PR 23 — H9 health and recovery center

Aggregate pending recovery, quarantine, degraded transcripts, failed/deferred
jobs, model verification, and recent safe codes. Reuse existing recovery actions
and cover VoiceOver, Dynamic Type, offline, low-storage, permission, degraded,
quarantine, and store-recovery states.

### Phase F — Continuous verification

H10 is implemented inside every prior PR: a new transition without its scripted
failure and post-relaunch assertion is incomplete.

#### PR 24 — H10 split CI signals, retained artifacts, and static policy

Split pure/unit, simulator integration, and UI/accessibility signals. Upload
`.xcresult`, failed screenshots, simulator/system logs, SwiftLint JSON, and
synthetic diagnostics on failure. Add allow-listed checks for production
`fatalError`, durability-boundary `try?`, raw public errors, custom destinations,
and unowned long-lived tasks.

#### PR 25 — H10 scheduled/release hardening and scorecard

Add repeated cancellation/concurrency tests, migration fixtures, Release launch,
supported sanitizers, repeated UI subset, and measured flake rate. Keep the
manual physical checklist versioned and make it a release gate. Record baseline
counts without inventing a numeric reliability SLO.

## Dependency graph

```text
PR 1 H1 (PR #153)
  └─ PRs 2–4 H2
       └─ PRs 5–7 H3
            ├─ PRs 8–10 H4
            │    ├─ PRs 11–13 H5
            │    │    └─ PRs 21–23 H9
            │    └─ PRs 17–20 H8
            └─ PRs 14–16 H7

H10 tests/fakes: inside each PR
PRs 24–25 H10 CI/release: after states and suites stabilize
H6 residuals: evidence/capability-driven only
```

After H3, H4 and H7 may proceed independently. After H4, H5 and the first H8
resource work may proceed independently. H9 should consume stable operation and
pipeline reports rather than invent temporary state models.

## Verification contract for every PR

- Add a deterministic failing test for the targeted fault before the fix where
  feasible.
- Run focused Swift Testing suites during iteration.
- Run `swift test` in `Packages/KurnCore` for changed pure logic.
- Run `swiftlint lint --config .swiftlint.yml` with zero serious violations.
- Run the Kurn scheme on the iPhone 17 simulator.
- Confirm GitHub `build-and-test` and `kurncore-linux` are green for the final
  commit; inspect logs for compiler/test issue markers.
- Use only synthetic fixtures and verify exported artifacts contain no private
  content.
- Update the H10 fault matrix and roadmap evidence after the result is observed.

## Release-only physical matrix

- Data Protection before and after first unlock.
- Screen lock during capture and finalization.
- Phone call and Siri interruption.
- Bluetooth input disconnect/reconnect and route format changes.
- Long background capture and expiration.
- Nearly-full storage and capacity-query failure.
- Memory and thermal pressure.
- Watch disconnect/reconnect and duplicate/lost commands.
- Model compilation/load and cancellation on physical hardware.

## Explicitly deferred or out of scope

- New product features and unrelated diarization improvements.
- Background cloud upload while origin-lock cannot be guaranteed.
- Streaming before measured latency/memory evidence and atomic final-output
  semantics.
- Automatic diagnostic transmission or a third-party analytics SDK.
- A numeric reliability SLO before an instrumented baseline exists.
- Weakening branch protection, CI policy, package-security controls, or privacy
  guarantees to make a PR green.
