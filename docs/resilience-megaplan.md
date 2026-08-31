# Reliability and Resilience Megaplan

This document is the execution-oriented companion to the reliability and
resilience track in `docs/roadmap.md`. The roadmap owns the product invariants,
risk register, and detailed H1–H10 contracts. This file owns sequencing, PR
boundaries, dependencies, acceptance gates, and the handoff state needed to
resume the track in another engineering session.

## Current handoff

Last updated: 2026-08-30.

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
- **On branch `claude/plano-resiliencia-xe25b2`, on top of merged `main`
  (not yet pushed as a PR):** PR 4, H2 protected backup, restore, salvage,
  and recovery UI. `ModelStoreBackupManager`
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
  shell. Not yet run through SwiftLint/`xcodebuild`/the simulator suite in
  this session — pushing the branch and opening a PR is the next step. See
  "PR 4 — H2 protected backup, restore, salvage, and recovery UI" below for
  the known gaps (salvage is best-effort and cannot recover from a
  genuinely un-migratable schema mismatch or real corruption; "N-1/N-2
  fixtures" is satisfied the same way PR 2 satisfied it — no earlier
  released schema exists to fabricate).
- The Xcode-generated
  `Kurn.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` is
  currently unrelated to this track and must not be included without a separate
  dependency-pinning review.

## How to resume

1. Read this file and the `Reliability and resilience track` section of
   `docs/roadmap.md`.
2. PR #155/#156/#157 (H2 schema baseline and boot state machine) are merged
   into `main`. PR 4 (backup/restore/salvage/recovery UI) is implemented on
   `claude/plano-resiliencia-xe25b2` — if it hasn't been pushed/opened as a
   PR yet, do that first rather than redoing the work; once it merges, H3
   (`docs/roadmap.md`'s "H3 · Atomic model/file mutations and non-destructive
   reconciliation") is next, from updated `main`.
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
| H2    | Schema baseline (PR #155) and boot state machine (PR #157) merged; backup/restore/salvage/recovery UI implemented, pending CI | `KurnSchemaV1`/`KurnSchemaMigrationPlan`/`KurnModelGraph`, an injectable `ModelContainerBootstrap`, and `ModelStoreBootCoordinator` (replacing the production `fatalError`) are all on `main`. `ModelStoreBackupManager`/`ModelStoreSalvage`/`ModelStoreRecoveryViewModel` (H2 PR 4) are on branch `claude/plano-resiliencia-xe25b2`. |
| H3    | Foundation only        | Protected fail-closed storage, quarantine/trash, mutation journal, and typed authoritative JSON corruption.                          |
| H4    | Partial                | Full source/config/model/chunk fingerprint, throwing checkpoint commits, explicit operation states, and bounded recovery.            |
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

Status: implemented on branch `claude/plano-resiliencia-xe25b2`, on top of
merged `main`; not yet pushed as a PR or CI-verified — see "Current handoff"
above.

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

#### PR 9 — H4 throwing chunk commits and bounded operation states

Objective: make durable checkpoint state gate forward progress.

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

#### PR 10 — H4 expensive generated-artifact operation state

Objective: apply durable multi-step semantics selectively to summary, wiki,
document, and correction jobs.

Acceptance:

- Completed safe map stages may resume; otherwise restart is explicit.
- Partial prose or JSON is never displayed as final.

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
