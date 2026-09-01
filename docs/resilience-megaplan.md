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
  boundary below (H3 fail-closed protected storage and quarantine), in
  review**: `AudioFileStore` writers throw
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
- **H4 PR 9 (throwing chunk commits and bounded automatic recovery,
  items 1, 2, 4 of the plan), merged into `main`.**
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
   `663ab09`). Continue from updated `main` with H5 (typed degradation and
   output-integrity gates, the "PR 11"/"PR 12" boundaries below) — H4's plan
   items are now fully addressed except item 3 (the full explicit
   operation-state enum), left deliberately deferred; see the H4 status
   snapshot row and "PR 10" below for the document-generation exclusion.
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
| H4    | Done, PR 8/9/10 merged | `TranscriptionPipelineFingerprint`/`PipelineDigest` give checkpoint matching a full source-digest + preprocessing/VAD + exact provider/model + compaction-map + chunk-plan identity, and `TranscriptionCheckpoint.isStructurallyValid` validates span/bounds sanity before a resume or the recovery sweep trusts one (PR 8, merged). `ChunkedTranscriptionRunner`'s chunk-completion callback is `async throws` and awaited before the next chunk starts, so a checkpoint-save failure stops the run instead of continuing past an undurable chunk; `Recording.automaticResumeAttempts` bounds unattended resume attempts per recording, reset by any manual retry (PR 9, merged). `SummaryMapCheckpoint`/`SummaryMapRunner` extend the same gated-durable-progress contract to the map stage of staged summary and wiki generation, sharing one `Meeting.summaryMapCheckpointData` field since both artifacts condense byte-identical map notes for the same meeting content (PR 10, implemented). Still open: the full explicit operation-state enum with reason codes/`nextAttemptAt` (item 3, deliberately deferred), and durable map-stage resumability for `DocumentGenerationService`, which spans multiple meetings and has no single `Meeting` to checkpoint against (deliberately excluded from PR 10, not planned elsewhere). |
| H5    | Planned                | Typed stage degradation, persisted pipeline report, integrity gate, and previous-artifact preservation.                              |
| H6    | Core implemented       | H9 waiting UX, FluidAudio path-change limitation, and deferred streaming measurement.                                                |
| H7    | Planned                | Typed Keychain results, explicit credential save, verified/resumable model staging, atomic replacement, and health probes.           |
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
them (see `docs/CLAUDE.md`'s "Derived artifacts" section). Left out of scope
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
integrity gate (PRs 11–12 below).** Start it from updated `main` after this
PR merges. H4's plan is otherwise closed except item 3 (the full explicit
operation-state enum), left deliberately deferred per PR 9's own handoff.

### Phase B — Visible degradation and integrity

#### PR 11 — H5 typed stage outcomes and pipeline report

Add requested/effective engine, succeeded/degraded/skipped/failed outcome, stable
reason, and safe diagnostics to every pipeline stage. Cancellation stays
throwing. Persist the aggregate report beside the transcript.

#### PR 12 — H5 final integrity gate and atomic artifact replacement

Validate source readability, span bounds/order, speech/text consistency, speaker
attribution, and correction identity. Keep the previous transcript, summary, and
index until the replacement is valid and durable.

#### PR 13 — H5 stage-specific recovery actions

Expose completed-with-warnings and retry the degraded stage without repeating
unrelated work where the architecture allows it. Integrate with H9 rather than
creating a second error system.

### Phase C — Credentials and models

#### PR 14 — H7 typed Keychain and explicit credential save

Add a `KeychainAccessing` seam, preserve `OSStatus` privately, classify absent vs
locked/denied/transient, finish accessibility migration only after success, and
commit provider edits only on explicit Save after URL validation.

#### PR 15 — H7 verified model staging, resume, and replacement

Unify app-managed whisper.cpp and sherpa-onnx download mechanics: immutable
revision, exact size, SHA-256/manifest, protected staging, retry, cancellation,
resume data, network policy, validation, and atomic replacement. Preserve the
previous valid model on every failure.

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
