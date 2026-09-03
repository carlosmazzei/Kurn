# Reliability and Resilience Megaplan

This document is the execution-oriented companion to the reliability and
resilience track in `docs/roadmap.md`. The roadmap owns the product invariants,
risk register, and detailed H1–H10 contracts. This file owns sequencing, PR
boundaries, dependencies, acceptance gates, and the handoff state needed to
resume the track in another engineering session.

## Current handoff

Last updated: 2026-09-03.

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
- **[PR #172](https://github.com/carlosmazzei/Kurn/pull/172), H7 PR 15
  (an injectable `ModelDownloading` seam unifying the whisper.cpp and
  sherpa-onnx downloaders, exact-size plus opportunistic-SHA-256
  verification, atomic install with backup/rollback, resume data, and
  cancellation), merged into `main`** (commit `d66c10f`, squash-merged from
  three pushes — the second and third were CI fixes: importing `KurnCore`
  for `AppError` in the new test file, then isolating that test file's
  network double from `MockURLProtocol`'s process-global state, which a
  first push had raced against `ProviderHTTPTests` and friends). See
  "PR 15" below for the full contract and its stated known gap.
- **[PR #173](https://github.com/carlosmazzei/Kurn/pull/173), H7 PR 16
  (a third persisted fact — verified installation — distinct from consent
  and from bytes-on-disk; post-install health probes for whisper.cpp and
  sherpa-onnx; and a storage-inventory pass), merged into `main`** (commit
  `060276b`, via merge commit `b75462c`). CI green on the first push. See
  "PR 16" below for the full contract. **H7's plan is now fully addressed**
  except pinning whisper.cpp's revision, which needs network access neither
  PR 15 nor PR 16's authoring environment had — see the note at the end of
  "PR 16" below.
- **[PR #174](https://github.com/carlosmazzei/Kurn/pull/174), H8 PR 17
  (an observed-at/cooldown/recheck replacement for the sticky
  memory-pressure latch, plus a global actor-based weight scheduler
  admitting preprocessing/ASR/diarization/enhancement/model-loading),
  merged into `main`** (commit `283d330`, plus two follow-up CI fixes —
  `3891573` importing `KurnCore` for `TranscriptionEngine` in the new test
  file, then `5ba261d` raising `appleSpeech`'s weight so the weight table
  actually satisfied the invariant its own regression test checked). See
  "PR 17" below for the full contract.
- **[PR #175](https://github.com/carlosmazzei/Kurn/pull/175), H8 PR 18
  (a full audit of every `@unchecked Sendable`/`nonisolated(unsafe)`
  /continuation bridge, fixing two "false timeouts," a leaked continuation,
  and an unsynchronized mutable property), merged into `main`** (commit
  `3b31bf7`, plus two follow-up CI fixes — `94f3f79` restoring
  `nonisolated(unsafe)` on `LockScreenRecordingController.activity` after a
  removal attempt failed with a Swift 6 "sending" error, then `18755f8`
  adding an explicit `self.` for an actor-isolated property captured in a
  `Logger` interpolation). See "PR 18" below for the full contract.
- **[PR #176](https://github.com/carlosmazzei/Kurn/pull/176), H8 PR 19
  (an ActivityKit start/end race fix using a `runID` generation counter,
  closing the hole where an untracked `start()` task could create a Live
  Activity nothing would ever end if it happened to run after a
  same-instant `end()`'s task), merged into `main`** (commit `5dd71c8`).
  CI green on the first push. See "PR 19" below for the full contract.
- **[PR #177](https://github.com/carlosmazzei/Kurn/pull/177), H8 PR 20
  (a single shared `WatchCommand`/`WatchSessionKey` source compiled into
  both the `Kurn` and `KurnWatch` targets; command IDs, dedup, a timeout,
  and a three-phase `WatchAckPhase` reply for Watch commands; reconnect
  reconciliation so a stale "recording" context can't outlive the process
  that set it; the same "accepted, not actual outcome" semantics applied to
  `StartRecordingIntent`; and one real fix each for items 1 and 8 found
  along the way), merged into `main`** (commit `7d15192`, plus one
  follow-up CI fix — `45d96d0`, for a Swift 6 `deinit` isolation error on
  `MeetingChatViewModel.task`, the same "`nonisolated(unsafe)`, confirmed
  by CI" shape PR 18 established for
  `LockScreenRecordingController.activity`). CI green after that fix. See
  "PR 20" below for the full contract. **H8's plan is now fully
  addressed.**
- **[PR #178](https://github.com/carlosmazzei/Kurn/pull/178), H9 PR 21
  (presentation metadata on `AppError` — category, severity, retryability,
  a recovery-action ID, private diagnostic context — plus a per-recording
  error queue for `TranscriptionViewModel`, the one shared app-wide
  instance whose single `error` property could previously let one
  recording's transcription failure clobber or misattribute another's),
  merged into `main`** (commit `674687c`). CI green on the first push. See
  "PR 21" below for the full contract.
- **[PR #179](https://github.com/carlosmazzei/Kurn/pull/179), H9 PR 22
  (a bounded, protected local buffer for `ReliabilityEvent`s; widening
  their adoption to `TranscriptionViewModel.transcribe`, the app's single
  most important resilience path; removing the four exact sites where an
  `AppError`'s raw `errorDescription` was logged at `.public`; and a
  redaction-preview/export screen), merged into `main`** (commit
  `0765891`, merge commit `ea6eae8`). CI green on the first push. See
  "PR 22" below for the full contract. Docs status corrections for H9
  PR 21 were bundled in this same PR, per the standing request.
- **[PR #180](https://github.com/carlosmazzei/Kurn/pull/180), H9 PR 23
  (a single "Health & Recovery" screen aggregating six conditions already
  tracked individually elsewhere — pending capture recovery, quarantined
  audio, degraded transcripts, failed/deferred transcription jobs, corrupt
  on-device models, and recent reliability failure codes — so a user does
  not need to know which of six different screens to check; every action
  dispatches to the exact same recovery function its existing per-item UI
  already calls), merged into `main`** (commit `9511f32`). CI green on the
  first push. See "PR 23" below for the full contract. Docs status
  corrections for H9 PR 22 were bundled in this same PR, per the standing
  request. **This closed out H9's plan except items 2 and 4**
  (contextual recovery-action UI buttons and optimistic-UI rollback),
  which were explicitly deferred as known gaps in PR 21's own write-up and
  remain out of scope here.
- **[PR #181](https://github.com/carlosmazzei/Kurn/pull/181), H10 PR 24
  (splitting the single `build-and-test` CI job into independently-
  reporting lint/static-policy/simulator-integration/UI-accessibility
  signals, retaining `.xcresult` and simulator/system-log artifacts on
  failure, and a new allow-listed static-policy check for a production
  `fatalError`, a silently-dropped `ModelContext` save, an ad hoc
  `URLSession`, and a raw error description logged at `.public`), merged
  into `main`** (commit `6189f1a`). All five real jobs (`lint-and-
  validate`, `static-policy`, `unit-tests`, `ui-accessibility-tests`,
  `kurncore-linux`) passed on the first push — confirmed by reading the
  actual job logs, not just the pass/fail summary: `unit-tests` ran 934
  tests in 113 suites (`KurnTests`) plus 13 in 3 suites
  (`KurnSwiftDataTests`), `ui-accessibility-tests` ran 12
  (`AccessibilityAuditUITests` + `ModelStoreRecoveryUITests`,
  `ScreenshotUITests` correctly excluded). See "PR 24" below for the full
  contract. Docs status corrections for H9 PR 23 were bundled in this same
  PR, per the standing request. **This begins H10**, the last phase in the
  megaplan.
- **[PR #182](https://github.com/carlosmazzei/Kurn/pull/182), H10 PR 25
  (the scheduled/release hardening lane — Thread Sanitizer and a
  Release-configuration test run against the app's concurrency-sensitive
  suites, five repeated attempts at the UI/accessibility suite to measure
  flake rate, a versioned checkbox release checklist, and Codecov coverage
  reporting for `unit-tests`/`ui-accessibility-tests`/`kurncore-linux`,
  added at the user's explicit request alongside this PR's own scope),
  merged into `main`** (commit `dd4526a`). All five real `iOS CI` jobs
  passed on the first push, and the three new coverage-export steps were
  confirmed working by reading the job logs directly: `unit-tests` and
  `ui-accessibility-tests`'s `xcrun xccov` exports and `kurncore-linux`'s
  `llvm-cov export` each produced a real coverage file the Codecov CLI
  recognized ("Found 1 coverage files to report"); the upload itself only
  failed on the expected, harmless "Token required" error since
  `CODECOV_TOKEN` isn't configured yet, and `fail_ci_if_error: false` kept
  every job green as designed. See "PR 25" below for the full contract.
  Docs status corrections for H10 PR 24 were bundled in this same PR.
  **This closes out H10's plan and the megaplan's own PR sequence**
  (PRs 1–25), except the items each PR along the way named as a
  deliberate, stated known gap. **The megaplan's own PR sequence is now
  complete.**
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
   `de8b551`); "PR 15" (verified model staging, resume, and replacement)
   merged as [PR #172](https://github.com/carlosmazzei/Kurn/pull/172)
   (commit `d66c10f`); "PR 16" (model inventory and health probes) merged as
   [PR #173](https://github.com/carlosmazzei/Kurn/pull/173) (commit
   `060276b`). **H7's plan is now fully addressed** except pinning
   whisper.cpp to an immutable revision, stated as a known gap in both PR 15
   and PR 16. **H8 is now in flight**: "PR 17" (observed-at/cooldown/
   recheck memory pressure and a global actor-based weight scheduler)
   merged as [PR #174](https://github.com/carlosmazzei/Kurn/pull/174)
   (commit `283d330`); "PR 18" (the `@unchecked Sendable`/`nonisolated
   (unsafe)`/continuation-bridge audit) merged as
   [PR #175](https://github.com/carlosmazzei/Kurn/pull/175) (commit
   `3b31bf7`); "PR 19" (ActivityKit start/end race fix via a `runID`
   generation counter) merged as
   [PR #176](https://github.com/carlosmazzei/Kurn/pull/176) (commit
   `5dd71c8`); "PR 20" (shared Watch protocol, command IDs/dedup/timeout/
   three-phase acknowledgements, reconnect reconciliation, and the same
   "accepted, not actual outcome" semantics applied to
   `StartRecordingIntent`) merged as
   [PR #177](https://github.com/carlosmazzei/Kurn/pull/177) (commit
   `7d15192`). **H8's plan is now fully addressed.** **H9 is done**:
   "PR 21" (`AppError` presentation metadata and a per-recording error
   queue for `TranscriptionViewModel`) merged as
   [PR #178](https://github.com/carlosmazzei/Kurn/pull/178) (commit
   `674687c`); "PR 22" (a bounded protected local event buffer, wider
   `ReliabilityEvent` adoption, removing four public raw-error-description
   log sites, and a redaction-preview export screen) merged as
   [PR #179](https://github.com/carlosmazzei/Kurn/pull/179) (commit
   `0765891`, merge commit `ea6eae8`); "PR 23" (a "Health & Recovery"
   screen aggregating pending recovery, quarantine, degraded transcripts,
   failed/deferred jobs, model verification, and recent failure codes
   behind one screen, dispatching to existing recovery actions) merged as
   [PR #180](https://github.com/carlosmazzei/Kurn/pull/180) (commit
   `9511f32`). **This closed out H9's plan** except items 2 and 4,
   deliberately deferred as known gaps in PR 21's own write-up. **H10 is
   done**: "PR 24" (split CI signals, retained failure artifacts, and
   allow-listed static-policy checks) merged as
   [PR #181](https://github.com/carlosmazzei/Kurn/pull/181) (commit
   `6189f1a`); "PR 25" (the scheduled/release hardening lane, a versioned
   physical release checklist, and Codecov coverage reporting) merged as
   [PR #182](https://github.com/carlosmazzei/Kurn/pull/182) (commit
   `dd4526a`). **This closed out H10's plan and the megaplan's own PR
   sequence (PRs 1–25).**
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
| H7    | Done, merged (PR 14/15/16) | `KeychainAccessing` (`KeychainReadOutcome`/`KeychainWriteOutcome`/`KeychainFailureReason`) replaces the old API that collapsed every Security-framework failure into the same value as "not configured"; `migrateToBackgroundAccessible()` now only marks itself complete after a confirmed outcome instead of after a failed fetch; provider credential edits commit only on explicit Save, after URL validation, with a failed Keychain write surfaced instead of silently assumed (PR 14, merged as [#171](https://github.com/carlosmazzei/Kurn/pull/171)). `ModelDownloading` (an injectable actor replacing the old static `ModelFileDownloader`) now verifies a completed download's exact byte count against the server's declared `Content-Length` and, when the origin volunteers one (HuggingFace's `X-Linked-ETag`), its SHA-256, installs atomically via `FileManager.replaceItemAt` with backup-and-restore on any post-install re-verification failure, keeps resume data across a cancelled/interrupted transfer, and wires a Cancel action into every download progress row (PR 15, merged as [#172](https://github.com/carlosmazzei/Kurn/pull/172)). `ModelVerification` now persists a third fact — "does this model actually load" — distinct from consent and from bytes-on-disk: whisper.cpp and sherpa-onnx each get a post-install health probe (`WhisperContext(modelPath:)` / `SherpaOnnxOfflineSpeakerDiarizationWrapper.init?`, both already-failable calls this PR now checks instead of ignoring) that deletes and fails the download outright on a bad file; the four FluidAudio-backed sets get the same fact for free, since `ModelDownloadConsent.download` already fully loads those models as part of downloading them; a storage-inventory pass (`ModelStore.installedModels()`) compares each installed model's current size against its last verified size, flags a mismatch as corrupt, and quietly re-applies `isExcludedFromBackup` if unset; Settings → Storage shows a checkmark/warning per row (PR 16, merged as [#173](https://github.com/carlosmazzei/Kurn/pull/173)). Remaining: pinning whisper.cpp's mutable `resolve/main` source to an immutable revision (no network path to HuggingFace to verify a real commit SHA in the environment both PRs were authored in), and retroactively verifying models installed before PR 16 (they read `.unverified`, not corrupt, until their next re-download).           |
| H8    | Done, plan fully addressed (PR 17/18/19/20 merged) | `MemoryPressureState` replaces the sticky memory-warning latch (a single boolean, set once, never cleared for the rest of the process) with an observed-at/cooldown/recheck model: new heavy work pauses for a measured interval after the *last* observed warning, then admission re-evaluates automatically, plus a live (non-latched) thermal-state check. `ResourceScheduler`, a global actor-isolated weight budget, gates preprocessing/transcription/diarization/enhancement/model-loading at their existing funnel points so two concurrent transcriptions picking the same heavy engine can't both pass an independent preflight and then both hold that engine's memory at once — generalizing across recordings the jetsam protection `TranscriptionService` already has within one (items 2–3, PR 17). A full audit of every `@unchecked Sendable`/`nonisolated(unsafe)`/continuation bridge fixed two "false timeouts" (`SherpaOnnxDiarizer`, `FluidAudioVAD` — a `TaskGroup` can't return until every child finishes, so racing a sleeping timer against a blocking call neither engine can abort never actually bounded time, it just discarded a valid slow result for a fabricated error), a leaked continuation (`RecorderViewModel`'s mic picker), and an unsynchronized mutable property (`CloudSettingsSync`) (items 4–5, PR 18). `LockScreenRecordingController` now closes the ActivityKit start/end race: a `runID` generation counter, bumped by both `start()` and `end()`, is checked synchronously by the queued start task immediately before the one non-cancellable call (`Activity.request`, which is `throws` but not `async`) that creates a Live Activity nothing would otherwise be tracking to end (item 6, PR 19). `WatchCommand`/`WatchSessionKey` now compile from one file shared into both the `Kurn` and `KurnWatch` targets instead of two independently-typed copies; Watch commands carry a `commandID` the phone deduplicates against (a redelivered duplicate replays its cached outcome instead of re-running the action), a bounded local timeout on the Watch side, and a three-phase `WatchAckPhase` reply (`received`/`stateChanged`/`finalized`) since every command handler in this app already runs synchronously to completion — `stop`'s file finalization included — before its caller learns the outcome; the phone also reconciles a stale application-context recording state on every `WCSession` (re)activation, since a live session never survives process termination (item 7, PR 20). `StartRecordingIntent` gets the same "accepted, not actual capture" semantics: it now awaits `RecordingLauncher`'s acceptance reply (bounded by a timeout) instead of claiming success the instant it posted the request, closing a cold-launch race where an unconfigured `RecordingLauncher` silently swallowed the request (item 8, PR 20). Item 1 (general operation ownership/run IDs) was audited against its own named examples: `MeetingsListView`'s semantic-search debounce already cancels correctly via SwiftUI's `.task(id:)`; `MeetingChatViewModel`'s reply `Task` did not cancel when its owning view was dismissed, now fixed with a `deinit` (PR 20). H8's plan is now fully addressed. |
| H9    | Done, plan fully addressed except items 2 and 4 (PR 21/22/23 merged) | `AppErrorCategory`/`AppErrorSeverity`/`AppErrorRecoveryAction` and a `privateContext` field extend `AppError` with the presentation metadata item 1 asks for (`Packages/KurnCore/.../AppErrorMetadata.swift`). `TranscriptionViewModel.errorsByRecording` fixes the one concrete "concurrent operations clobber a shared error" case found: the view model is a single app-wide shared instance, so two recordings' transcription failures used to be able to overwrite or misattribute each other through one `error` property; `MeetingDetailView`'s alert now binds to the per-recording accessor instead (PR 21). `ReliabilityEventStore` gives the pre-existing content-free `ReliabilityEvent`/`ReliabilityLog` vocabulary a bounded, protected on-device buffer (item 6); `TranscriptionViewModel.transcribe` gets its own instrumentation, correlated by one `OperationID` per attempt; the four exact sites logging an `AppError`'s raw `errorDescription` at `.public` now log `logCode`/`privateContext` instead; and `ReliabilityEventsListView` (Settings → Diagnostics) lists and shares recent events — every field content-free by construction, so displaying them verbatim already is the redaction preview item 6 asks for (PR 22, merged as [#179](https://github.com/carlosmazzei/Kurn/pull/179)). `HealthRecoveryView` (Settings → Health & Recovery) aggregates six conditions already tracked individually elsewhere — pending capture recovery, quarantined audio, degraded transcripts, failed/deferred transcription jobs, corrupt on-device models, and recent reliability failure codes — behind one screen, dispatching every action to the exact same recovery function its existing per-item UI already calls rather than reimplementing recovery logic (items 7–8, PR 23, merged as [#180](https://github.com/carlosmazzei/Kurn/pull/180)). Remaining, deliberately out of scope for this track: item 2 (contextual recovery-action UI), item 4 (optimistic-UI rollback), a reference ID surfaced in the UI error dialog, `persist()`'s own error surface (still shared, not recording-scoped), health/recovery-center accessibility test coverage, and the broader non-`AppError` raw-log-description sweep. |
| H10   | Done, plan addressed except items 1–2 (PR 24/25 merged) | `.github/workflows/swift.yml`'s single `build-and-test` job is now five parallel jobs (`lint-and-validate`/`static-policy`/`unit-tests`/`ui-accessibility-tests`, plus `kurncore-linux`), each reporting separately, with `.xcresult`/simulator-log retention on failure and a narrow allow-listed static-policy scan for four regression classes (PR 24, merged as [#181](https://github.com/carlosmazzei/Kurn/pull/181)). `.github/workflows/reliability-hardening.yml` (new, weekly + on-demand) adds Thread Sanitizer and Release-configuration runs against the concurrency-sensitive suites, and five repeated UI/accessibility attempts to measure flake rate, summarized without an invented threshold; `docs/release-physical-checklist.md` versions the manual device matrix as an actual checkbox list, referenced from both `beta` and `submit`; Codecov coverage reporting was added across `unit-tests`/`ui-accessibility-tests`/`kurncore-linux`, informational-only per `codecov.yml`, verified working end to end in CI (PR 25, merged as [#182](https://github.com/carlosmazzei/Kurn/pull/182)). Item 1–2's full fault-injection protocol/matrix stays threaded through prior PRs' own fakes rather than landing as one PR — see this section's known gaps. **The megaplan's own PR sequence (PRs 1–25) is now complete.** |

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

Status: merged into `main` as
[PR #172](https://github.com/carlosmazzei/Kurn/pull/172) (commit `d66c10f`).
CI was green after two rounds of fixes pushed to the same PR, both caught by
CI rather than locally, per "Verifying without a local macOS/Xcode
toolchain" in `CLAUDE.md`: the first push omitted `import KurnCore` in the
new test file (`AppError` lives there, not in the `Kurn` target); the second
push's test suite shared `MockURLProtocol`'s process-global stub queue with
five pre-existing suites that only serialize against themselves, and CI
caught the resulting cross-suite race (a request from this suite's tests
was captured and consumed by a `ProviderHTTPTests` assertion running at the
same moment, and vice versa) — fixed by giving the new suite its own
private `URLProtocol` double instead.

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

Status: implemented on branch `claude/resilience-roadmap-plan-fn23ki`; CI is
the verification of record, per "Verifying without a local macOS/Xcode
toolchain" in `CLAUDE.md`.

**What shipped.** Before this PR, an installed model had exactly two facts:
consent (an `AppSettings` flag) and "installed" (`ModelStore.isInstalled`, a
byte-count check PR 15 already made exact at transfer time). Neither proves
the file is *usable* — a bit flip after install, or a corruption PR 15's
checks don't cover, would read as "installed" forever and only surface the
first time a real transcription or diarization run tried to load it.

- **`ModelVerification`** (new, `Kurn/Services/ModelVerification.swift`)
  persists a third fact per model id: `.unverified` (no record — the honest
  state of every model installed before this PR, not a failure),
  `.verified(Date)` (a health probe proved it loads, and its size hasn't
  changed since), or `.corrupt(reason:)` (a probe failed, or the on-disk
  size has drifted since the last successful verification). Drift is a
  cheap size comparison, not a routine re-hash — re-reading gigabytes of
  model weights on every Settings→Storage visit would be its own cost, and
  nothing in this app ever grows or shrinks an installed model file in
  place, so any size difference already means the bytes changed by some
  means other than this app's own verified install path.
- **Two real health probes, both cheap.** whisper.cpp's `WhisperContext.init`
  and sherpa-onnx's `SherpaOnnxOfflineSpeakerDiarizationWrapper.init?` were
  already failable — `nil`/a thrown error on a corrupt file — but neither
  downloader called them until the first real transcription/diarization run
  did. `WhisperCppTranscriber.verifyModelLoads(at:)` and
  `SherpaOnnxDiarizer.verifyModelsLoad()` (new static functions, `#if
  canImport(whisper)` / `#if SHERPA_ONNX_ENABLED` with a no-op `#else` stub
  each, matching the existing split in both files) now call exactly those
  same already-failable initializers once, right after
  `WhisperCppModelDownloader.download`/`SherpaOnnxModelDownloader.download`
  install the bytes, and discard the result — proving the file loads
  without keeping a model in memory. Both are blocking C calls (loading a
  GGML file / two ONNX graphs), so both run inside `Task.detached` rather
  than on whatever actor's `download` call happened to reach them. A probe
  failure deletes the just-installed file(s) and rethrows as
  `AppError.modelDownloadFailed`, the same "leave nothing installed on
  failure" shape PR 15 already established for a bad transfer — this simply
  extends "verified" to include "loads correctly," not just "bytes match
  what the server declared."
- **The four FluidAudio-backed sets get the same fact for free.** Their
  models have no downloader of this app's own — `ModelDownloadConsent
  .download`'s FluidAudio branch calls straight into the package's own
  `AsrModels.downloadAndLoad`/`OfflineDiarizerModels.load`/`VadManager.init`/
  `loadModels`, which *download and fully load* the model (CoreML/ANE
  compilation included) as one inseparable operation — a successful return
  already **is** a passed health probe, previously just discarded rather
  than recorded. `ModelDownloadController`'s shared `download(...)` now
  calls `ModelVerification.record(...)` right after
  `ModelStore.recordDownload` succeeds, for exactly the groups that don't
  already record their own (`ModelGroup.isSelfVerifying` — true only for
  `.whisperCpp`/`.sherpaOnnxDiarization`, which record a precise per-variant
  id from inside their own downloaders and would otherwise be shadowed by a
  coarser group-level record here).
- **Storage inventory** (item 6): `ModelStore.installedModels()` now looks up
  `ModelVerification.state(id:currentSize:)` for every row it builds — using
  the exact same id scheme (`ModelVerification.recordID(for:folder:)`) the
  UI's `InstalledModel.id` already used, so a record always lines up with
  the row it describes — and quietly re-applies `isExcludedFromBackup` on
  whisper.cpp/sherpa-onnx folders if it's ever found unset, the same
  "verify and fix" shape `ModelStoreProtection.applyAndVerify` already uses
  for the app's SwiftData store. `ModelStore.delete(_:)` clears the
  corresponding record(s) so a later re-download starts from `.unverified`
  rather than comparing fresh bytes against a description of files that no
  longer exist.
- **Settings → Storage** (`StorageSettingsView.modelsSection`) renders the
  new fact: a small green checkmark next to a verified model's name, and a
  red warning line ("Failed verification — remove and re-download," new key
  `settings.models.corrupt` in all seven locales) under a corrupt one.
  "Offer redownload for corruption" is the existing delete button, not a
  new bespoke flow: `ModelDownloadController.deleteModel` already reverts
  the affected engine/consent flag when the deleted group is active, so
  removing a corrupt model naturally leaves the feature in its no-download
  fallback state, ready to be re-enabled (which re-triggers the consent +
  download + probe flow) exactly like a deliberate manual delete already
  does today. `.unverified` renders with no badge at all — deliberately: it
  is the state of every model installed before this PR, and a new warning
  icon on every existing user's already-working setup would be alarming for
  no reason.

**Tests.** `KurnTests/ModelVerificationTests.swift` (new) drives
`ModelVerification`'s pure state logic against a randomly-suffixed
`UserDefaults` suite per test (never `.standard`): no record reads as
`.unverified`; a matching size reads as `.verified` with the recorded date;
a size mismatch reads as `.corrupt`; `clear` reverts to `.unverified` and is
scoped to one id, leaving a sibling's record untouched; `recordID` folds in
the folder only for `.whisperCpp` (the one group that lists folders
separately) and ignores a folder argument for every other group; and
`ModelGroup.isSelfVerifying` is pinned to exactly the two groups with their
own downloader.

**Known gaps, stated plainly.**

- **Retroactive verification is out of scope.** A model installed before
  this PR, or one whose engine is already consented and selected (so the
  picker never re-enters the consent/download flow), stays `.unverified`
  until it happens to be deleted and re-downloaded. Probing it automatically
  at launch was considered and rejected: for the three FluidAudio-backed
  groups that would mean unconditional CoreML/ANE compilation on every
  launch, which is exactly the expensive, foreground-gated-only cost
  `KurnApp.prewarmFluidAudioModel` already exists to avoid paying
  unconditionally. A manual "Verify now" action per row would close this
  without that cost, but was judged separate scope from what H7's plan
  actually asks for ("Done when" only requires the fact to exist and be
  reported, not that every legacy install retroactively acquire it) and is
  not planned elsewhere in this document.
- **Digest verification is whisper.cpp/sherpa-onnx only, and is size-based
  drift detection, not a routine re-hash.** `ModelVerification.Record`
  stores the size at the moment a probe last succeeded, not a SHA-256 — a
  full re-digest on every Settings→Storage appearance would mean rereading
  gigabytes of model weights on every visit. The four FluidAudio-backed
  groups get no digest at all, not even at record time: their models are
  multi-file CoreML packages this app never downloads directly, so there is
  no single hash to compute against, and the load-time probe already proves
  usability more directly than a digest would.
- **`isExcludedFromBackup` reconciliation only covers this app's own model
  roots** (whisper.cpp, sherpa-onnx). FluidAudio's cache directory
  (`Application Support/FluidAudio/Models`) is written entirely by the
  FluidAudio package, never by this app's code — there is nothing here to
  verify or fix, and no seam to fix it through. Unchanged from the gap PR
  15 already stated: "FluidAudio remains a capability-limited adapter with
  preflight only until its library exposes session/path-change control."
- **Pinning whisper.cpp's mutable `resolve/main` source to an immutable
  revision (item 4's other half) remains open**, for the same reason PR 15
  stated it: no network path to `huggingface.co` in the environment either
  PR was authored in to obtain a real commit SHA to pin, and a wrong or
  stale hardcoded one would fail every future download outright. This is
  the one piece of H7's plan neither PR 15 nor PR 16 closes.

### Phase D — Ownership, resources, and integrations

#### PR 17 — H8 resource cooldown and global admission scheduler

Replace sticky memory pressure with observed-at/cooldown/recheck state and add a
global actor-based permit/weight scheduler for preprocessing, ASR, diarization,
enhancement, and model loading.

Status: implemented on branch `claude/resilience-roadmap-plan-fn23ki`; CI is
the verification of record, per "Verifying without a local macOS/Xcode
toolchain" in `CLAUDE.md`.

**What shipped.** `ResourcePressureMonitor` (`Kurn/Infrastructure/ResourceGuard.swift`)
used to set a single boolean the first time `UIApplication
.didReceiveMemoryWarningNotification` fired and never clear it — every
transcription/model-download/enhancement preflight from that point until the
user force-quit and relaunched saw a permanently unhealthy device, regardless
of how much memory had since been freed. That is item 2's "sticky resource
state," and the roadmap's own H8 status row named it directly.

- **`MemoryPressureState`** (new, pure value type, mirroring
  `SecurityCoverState`'s shape) replaces the boolean with an
  observed-at/cooldown/recheck model: `lastWarningObservedAt: TimeInterval?`
  plus the device's current `ProcessInfo.ThermalState`.
  `isHealthy(now:)` pauses new heavy work for `cooldownInterval` (60s) after
  the *last* observed warning, then re-admits automatically — no explicit
  "reset" call needed, unlike the old `resetMemoryWarning()` that nothing in
  production ever actually called (removed as dead code). Thermal state is a
  second, live signal checked independently: `.serious`/`.critical` blocks
  admission with no cooldown of its own, and clears itself the instant
  `ProcessInfo` next reports the device has cooled — `.fair` is deliberately
  not blocking, since it's iOS's normal state during any real transcription.
  `ResourcePressureMonitor` is now the thin OS-facing shell recording
  `lastWarningObservedAt` (via an injected `MonotonicSleepClock`, so a
  cooldown boundary is testable without a real wait); `ResourceGuard
  .requireNoMemoryPressure(clock:)` builds a `MemoryPressureState` from it
  plus `ProcessInfo.processInfo.thermalState` on every call — closing item
  2's "later admission reevaluates memory, thermal state and storage instead
  of disabling work until relaunch" exactly (storage was already
  reevaluated dynamically; only memory pressure was sticky).
- **`ResourceScheduler`** (new, `Kurn/Infrastructure/ResourceScheduler.swift`)
  is item 3's global actor-based permit/weight scheduler. A single shared
  weight budget (`defaultTotalWeight = 100`); `ResourceWorkKind` gives each
  of the five named categories — preprocessing, transcription (per engine),
  diarization (per engine), enhancement, model loading — a weight.
  `acquire(weight:)`/`release(weight:)` are cancellation-safe
  (`withTaskCancellationHandler`, the same idiom H7 PR 15's `Downloader
  .download` already established for this codebase), and a request that
  doesn't currently fit queues rather than failing outright; `release`
  admits every queued waiter that now fits the freed budget, not only the
  one at the front, so one heavy queued request can't starve a lighter one
  behind it.
- **Wired into all five categories at their existing funnel points**, not
  into every low-level file: `TranscriptionService.transcribeGated`/
  `.diarize` (every transcription and diarization engine already passes
  through these two), `AudioPreprocessor.process`,
  `PlaybackEnhancementRenderer.render`, `FluidAudioModelStore`'s coalesced
  load, `ModelDownloadConsent.download`'s FluidAudio branch, and (since they
  also load a model into memory) H7 PR 16's two post-install health probes,
  `WhisperCppTranscriber.verifyModelLoads(at:)` and `SherpaOnnxDiarizer
  .verifyModelsLoad()`.
- **Deliberately does not touch or duplicate**
  `TranscriptionService.transcribe`'s existing compile-time sequential/
  concurrent branch (cloud transcription runs concurrently with
  diarization; every on-device engine runs strictly sequentially before
  it, for exactly the jetsam reason this PR generalizes). The weight table
  was chosen so the scheduler *agrees* with that branch rather than
  fighting it: cloud transcription's weight (5) fits alongside any
  diarization engine's, matching the branch's own concurrent case; any
  on-device transcription engine's weight (55–60) never fits alongside
  FluidAudio's or sherpa-onnx's diarization weight (50), matching the
  branch's own sequential case — both pinned as regression tests (see
  below). What the scheduler adds is the case that branch never covered:
  two *different* recordings' heavy stages contending for memory at once,
  which nothing previously gated.

**Tests.** `KurnTests/ResourceGuardTests.swift` gained `MemoryPressureState`
coverage: no warning is always healthy; a recent warning stays unhealthy
within the cooldown and recovers once it elapses (and well past it, proving
it isn't merely "sticky at a different fixed point"); `.serious`/`.critical`
block even with no warning at all; `.fair` alone does not; thermal blocking
is a live signal that clears the moment the state changes, with no cooldown
memory of its own. `KurnTests/ResourceSchedulerTests.swift` (new) drives the
real actor: an acquire under budget succeeds immediately; one over budget
queues and is admitted once the holder releases; a lighter queued waiter is
admitted ahead of a heavier one still stuck at the front once it fits;
cancelling a queued acquire throws `CancellationError` and reserves nothing
(provable via a fresh full-budget acquire succeeding right after); and the
two weight-table invariants described above are pinned directly against
`TranscriptionService`'s own engine enums, so a future weight change that
silently breaks either invariant fails a test instead of only surfacing on
a device. Waiting for a waiter to actually be enqueued polls a `#if DEBUG`-only
`waiterCountForTesting` with `Task.yield()` (bounded), never a fixed
`Task.sleep`, so the suite can't be flaky under CI load.

**Known gaps, stated plainly.**

- **The weight table is a first-cut estimate, not a measurement.** No
  benchmark or memory-profiling data exists anywhere in this codebase
  quantifying relative cost per pipeline stage/engine (confirmed by
  research before writing this PR); the numbers were chosen only to
  preserve the two invariants against `TranscriptionService`'s existing
  behavior described above. A follow-up with access to real devices should
  replace them with measured figures, the same caveat H5's on-device-LLM
  char/token thresholds already carry in `docs/roadmap.md`'s F1 section.
- **The cooldown interval (60s) and thermal-blocking states
  (`.serious`/`.critical`) are likewise unmeasured defaults**, not tuned
  against real low-memory/thermal-throttling device behavior.
- **`ResourceScheduler` only gates the five named categories at their
  funnel points** — it does not reach into `VADAudioCompactor`,
  `DiarizationPreprocessor`, or `OfflineAudioRenderer` individually; those
  already run *inside* a category's held permit (e.g. diarization
  preprocessing runs inside `diarize`'s acquired weight), so they are
  covered, just not separately weighted.
- **Items 1, 4–8 of H8's plan** (operation ownership/run IDs,
  `@unchecked Sendable`/bridge audit, timeout truthfulness, ActivityKit
  lifecycle, shared Watch protocol, F3 intent semantics) **are PR 18–20's
  scope, not touched here.**

#### PR 18 — H8 cancellation truth and bridge audit

Audit every `@unchecked Sendable`, `nonisolated(unsafe)`, continuation, and
callback bridge. Add exactly-once assertions/stress tests. Use real engine abort
hooks where available; otherwise report deferred cancellation instead of a false
timeout.

Status: merged into `main` as
[PR #175](https://github.com/carlosmazzei/Kurn/pull/175) (commit `3b31bf7`,
plus two follow-up CI fixes — see the status snapshot entry above for both).
CI green after those two fixes, per "Verifying without a local macOS/Xcode
toolchain" in `CLAUDE.md`.

**The audit itself.** Every `@unchecked Sendable` (20 sites) and
`nonisolated(unsafe)` (12 sites) in `Kurn`/`KurnCore` non-test source, and
every `withCheckedContinuation`/`withCheckedThrowingContinuation`/
`withTaskCancellationHandler` bridge (11 sites), was read in full and
classified: what mutable state it protects (if any) and what actually
synchronizes access to it. Most were already correctly justified — a lock
(`ProviderHTTPTransport`'s `BoundedHTTPDataDelegate`, `ModelFileDownloader`
's `Downloader`, `RecordingSink`, `NetworkPathObserver`, …), actor isolation
the annotation merely routes around a spurious `Sendable` check for
(`FluidAudioDiarizer.manager`), or a synchronously-invoked `@Sendable`
closure that never actually crosses threads despite its type
(`RecordingSink.ConverterInput`, `VADAudioCompactor`'s feed-once flag) — and
those are left exactly as they were, per the plan's own "keep the justified
lock/queue wrappers." Five things worth reporting came out of it: three
real bugs, fixed here; one annotation that looked removable, checked, and
turned out to be necessary for a different reason than its own comment
gave; and one plan item that was already fixed before this PR started.

- **Two "false timeouts," found and fixed.** `SherpaOnnxDiarizer` and
  `FluidAudioVAD` each raced their real work against a sleeping child task
  in a `withThrowingTaskGroup` and called the loser "timeout" — but the
  real work in both cases is a call neither engine exposes any way to
  interrupt (sherpa-onnx's C API has no progress/abort parameter;
  FluidAudio's `VadManager` checks no cancellation anywhere in its per-chunk
  loop and calls CoreML's synchronous `model.prediction(from:)` directly).
  `group.cancelAll()` marks the loser cancelled without stopping it, and —
  the part that makes this worse than merely misleading — a `TaskGroup`
  cannot return until *every* child task finishes, cancelled or not. So the
  "timeout" never actually bounded wall-clock time at all: the call still
  blocked for the real operation's full duration, and only then discarded a
  valid, just-slow result in favor of a fabricated timeout error. Both now
  call the real work directly (`SherpaOnnxDiarizer` still off-actor, via
  `Task.detached`, so the actor stays free for other callers; `FluidAudioVAD`
  already ran inline on its own actor either way) and log a notice if it
  exceeded the stated budget, instead of throwing an error and discarding
  the result — identical real-world latency, but honest about what
  happened, exactly item 5's "report deferred cancellation truthfully."
  `WhisperTranscriber`'s cloud-upload timeout and `FluidAudioDiarizer`'s
  diarization timeout were audited too and left alone: the former
  genuinely cancels the underlying `URLSessionDataTask`
  (`ProviderHTTPTransport.swift`'s `onCancel` handler calls `task?.cancel()`
  ), and the latter's FluidAudio call chain calls `Task.checkCancellation()`
  between chunk/prediction/batch boundaries (verified against the pinned
  FluidAudio 0.15.6 source) — real, if only boundary-granular, not false.
  `FoundationModelsProvider`'s timeout wraps a closed-source Apple
  framework call and couldn't be verified either way; left alone and noted
  below. `WhisperCppTranscriber` doesn't use this pattern at all — it has a
  genuine engine abort hook (whisper.cpp's `abort_callback`, polled by
  ggml's compute threads) already wired to Swift task cancellation, and is
  the model item 5 asks other engines to match where possible.
- **A continuation leak, found and fixed.** `RecorderViewModel
  .prepareToRecord()`'s pending mic-choice `CheckedContinuation` was a
  plain property with nothing stopping a second concurrent call from
  silently overwriting it — leaking the first continuation, which nothing
  would ever resume, hanging that earlier call forever. The store operation
  is now `storeMicChoiceContinuation(_:)`: it resolves any already-pending
  continuation to `nil` ("use the system default", the same outcome
  `chooseMic(uid: nil)` produces) before storing the new one, so every
  stored continuation is resumed exactly once.
- **An unsynchronized mutable `var`, found and fixed.** `CloudSettingsSync
  .didChangeExternally` was a plain settable property on an
  `@unchecked Sendable` type, with its only protection a comment claiming
  "set once, from the main actor, by `AppSettings.init`" — true in
  practice, enforced by nothing. It's now guarded by the same `NSLock`
  pattern every other mutable-state `@unchecked Sendable` in this codebase
  already uses, making the claim executable instead of only documented.
- **A `nonisolated(unsafe)` checked, and confirmed necessary for a
  different reason than its own comment gave.**
  `LockScreenRecordingController.activity`'s annotation looked
  unnecessary at first read — the whole type is `@MainActor`, and every
  access site is inside a `Task { }`/`Task { @MainActor in }` created from
  a `@MainActor` method (inheriting that isolation, not `.detached`), so
  access was never racing across real threads. Removing it was tried and
  reverted: CI's first push failed with two Swift 6 "sending... risks
  causing data races" errors, because `Activity<T>.update(_:)`/
  `.end(_:dismissalPolicy:)` are `nonisolated` async methods in
  ActivityKit's own API — passing a main-actor-isolated value into a
  `nonisolated` call is exactly what Swift 6's region-based "sending"
  check exists to catch, independent of whether the value is genuinely
  shared across threads. The annotation is load-bearing after all, just
  not for the reason its own comment stated; it's kept, with a comment
  now explaining the real reason and citing that CI confirmed it.
- **The "racing lazy property" item 4 names for the background uploader
  session was already fixed before this PR** — `git log -p` on
  `WhisperBackgroundUploader.swift` shows an earlier commit
  (`797c578`) replaced the `lazy var session: URLSession` the plan
  describes with the current `NSLock`-guarded `storedSession` check-and-set,
  landing before H8 PR 17 branched. That fix had no test proving it holds
  under real concurrent access, though — this PR adds one.

**Tests.** `KurnTests/RecorderMicChoiceTests.swift` (new): drives
`storeMicChoiceContinuation(_:)` directly rather than through
`prepareToRecord()` (the real trigger,
`AVAudioSession.availableInputs.count > 1`, isn't reproducible against the
simulator's single built-in mic) — a second pending request resolves the
first to `nil` instead of leaking it, and the ordinary single-request path
still resolves normally. `KurnTests/WhisperBackgroundUploaderTests.swift`
(new): 20 concurrent first-accesses of a dedicated (non-`.shared`)
uploader's session all resolve to the same `URLSession` instance — the
"new coverage, not a fix" test the pre-existing lock never had. Both use
a `#if DEBUG`-only test accessor (`hasPendingMicChoiceContinuationForTesting`,
`sessionForTesting`) rather than widening the real API. `RecorderMicChoiceTests`
polls the pending-continuation flag with `Task.yield()` (bounded), never a
fixed `Task.sleep`, matching `ResourceSchedulerTests`' established pattern
so the suite can't be flaky under CI load.

**Known gaps, stated plainly.**

- **No Thread Sanitizer configuration exists anywhere in the project** —
  the `Kurn.xcscheme`'s `TestAction` has no diagnostics flag set, so H8's
  own "Verification" line ("Thread Sanitizer runs for first-party bridges")
  remains entirely unimplemented, not merely incomplete. Not attempted here:
  enabling TSan repo-wide risks materially slowing or destabilizing the
  whole CI suite, and that tradeoff deserves its own decision rather than
  a side effect of this PR.
- **Three duplicated `nonisolated(unsafe) static var` handler globals**
  (`AppLog.minimumLevel`, `KurnCore`'s `TranscriptQualityFilter.logHandler`,
  `ReliabilityEvent.handler`) share one unreasoned-about pattern — a global
  mutable static with no lock, explicitly modeled on each other rather than
  independently justified. Left as-is: consolidating them into one shared
  thread-safe wrapper is a real improvement but touches cross-cutting
  logging/diagnostics infrastructure, out of scope for this pass.
- **`SherpaOnnxOfflineSpeakerDiarizationWrapper`'s single-owner-at-a-time
  contract is a comment, not an enforced invariant** — nothing in the type
  itself prevents concurrent misuse if `SherpaOnnxDiarizer`'s own
  actor-serialized usage pattern is ever violated by a future caller. Left
  as-is; would need wrapping the type itself, a larger change.
- **`AudioRecorderService`'s `onAudioBuffer` callback property is settable
  from any isolation with no lock**, read from the real-time audio render
  thread. Benign today because it's set once at wiring time before
  recording starts, but unenforced. Left alone — this is deep in the
  recording hot path and any change there needs device-level audio testing
  this environment can't do, not just a CI-verified compile.
- **`FoundationModelsProvider`'s timeout could not be verified either way**
  — it wraps `FoundationModels.LanguageModelSession`, a closed-source Apple
  framework call. At minimum it participates in structured concurrency
  normally (so `group.cancelAll()` marks it cancelled), but whether Apple's
  implementation checks cancellation internally and aborts promptly isn't
  something this repo can confirm from source. Left as-is rather than
  guessed at.
- **Items 1 and 6–8 of H8's plan** (operation ownership/run IDs,
  ActivityKit lifecycle, shared Watch protocol, F3 intent semantics)
  **remain PR 19–20's scope, not touched here.**

#### PR 19 — H8 ActivityKit authoritative lifecycle

Serialize start/update/end on one actor, retain/cancel the start task, bind every
mutation to recording/run ID, and ensure start-immediate-end cannot create a late
orphan.

Status: merged into `main` as
[PR #176](https://github.com/carlosmazzei/Kurn/pull/176) (commit `5dd71c8`).
CI green on the first push.

**The race.** `LockScreenRecordingController.start()` fired an untracked
`Task { }` that unconditionally called `Activity.request(...)` and stored the
result once it ran. `Activity.request` is `throws` but not `async` — a fully
synchronous ActivityKit call with no internal suspension point — so once that
task actually started running, there was nothing for a concurrent `end()` to
interleave on *inside* it. The real race was scheduling order between the
`start()` task and an `end()` task created afterward (e.g. a start-immediate-
stop sequence): Swift's concurrency model does not guarantee that two
independently-created unstructured tasks on the same actor run in call order.
If `end()`'s task happened to run first, it would find `activity == nil` (the
start task hasn't run yet) and correctly do nothing; the start task, running
later, would then still create a real Live Activity and store it — and since
`end()` already ran and decided there was nothing to end, nothing would ever
end it. The result is an orphaned Live Activity on the Lock Screen/Dynamic
Island for a recording that has already stopped, left until the system
eventually evicts it on its own schedule.

**The fix.** `runID: UUID`, bumped by both `start()` and `end()`, replaces
"does `activity` exist" as the source of truth for whether a given `start()`
call is still the one that should proceed. `start()` captures the id it just
assigned and, once its `Task` actually runs, checks `runID` again —
synchronously, with no `await` between the check and `Activity.request` — and
skips creating anything if a later `end()` (or a later `start()`) has already
superseded it. Because `Activity.request` has no internal suspension point,
that single pre-check is sufficient: nothing can run between the check and the
call that would invalidate it. `update()` gained the same check (capture
`runID` before firing its `Task`, compare on entry) as stale-work hygiene,
though it is not orphan-critical the way `start()`'s check is — a stale
`update()` on a still-live activity is merely a wasted, possibly-out-of-order
UI refresh, not a leak. `startTask: Task<Void, Never>?` is retained so `end()`
can also explicitly `.cancel()` it, matching the plan's literal "retain/cancel
the start task" wording; `runID`, not the cancellation, is what's structurally
load-bearing, since a bare `Task.cancel()` can't interrupt `Activity.request`
itself (a synchronous foreign call with no cancellation checkpoint) — it can
only signal intent to code that checks `Task.isCancelled`, which is exactly
what the `runID` check already does more precisely.

**Tests.** None added. `Activity<RecordingActivityAttributes>` and
`ActivityAuthorizationInfo` are concrete ActivityKit types with no protocol
seam in this codebase to substitute a fake behind, and the simulator does not
support genuine Live Activity authorization — a unit test exercising the real
race would need to control the *scheduling order* of two independently-created
`Task { }`s relative to each other, which Swift's concurrency runtime
provides no supported way to force deterministically. This is a known gap in
this PR's coverage, not a claim that the fix is unverifiable in principle:
`runID` is the same generation-counter pattern already used and tested
elsewhere in this codebase for exactly this class of problem (e.g.
`storeMicChoiceContinuation` in PR 18), and the fix is verified by CI
compiling and passing the existing suite, not by a new test proving the race
is closed.

**Known gaps, stated plainly.**

- **No automated test proves the orphan race is actually closed** — see
  "Tests" above. Manual verification (rapid start/stop on a real device,
  watching for an orphaned Live Activity) is the only way to observe this
  today.
- **Item 1 of H8's plan** (operation ownership/run IDs as a *general*
  mechanism, beyond this one ActivityKit-specific application) **and items 7–8**
  (shared Watch protocol, F3 intent semantics) **remain PR 20's scope, not
  touched here.**

#### PR 20 — H8 shared Watch protocol and idempotent external commands

Compile one protocol source into both targets. Add command IDs, timeout,
deduplication, ordered reconciliation, and acknowledgements for received,
state-changed, and durably-finalized. Intents report accepted, not actual capture,
until the recorder confirms it.

Status: merged into `main` as
[PR #177](https://github.com/carlosmazzei/Kurn/pull/177) (commit `7d15192`,
plus one follow-up CI fix — `45d96d0`, restoring `nonisolated(unsafe)`-shaped
access for `MeetingChatViewModel.task` from a nonisolated `deinit`). CI green
after that fix.

**One shared protocol source (item 7's "compile one protocol source into
both targets").** `WatchCommand` and `WatchSessionKey` used to be typed
independently in `Kurn/Services/WatchSessionProtocol.swift` and
`KurnWatch/WatchSessionProtocol.swift` — byte-for-byte duplicates by
convention, not by the compiler. `KurnWatch/WatchSessionProtocol.swift` is
now deleted; the single remaining copy at `Kurn/Services/` is compiled into
both the `Kurn` and `KurnWatch` targets via an explicit `project.pbxproj`
Sources entry on `KurnWatch`, the same dual-target-membership pattern
`RecordingActivityAttributes.swift` already established for sharing one file
between `Kurn` and `KurnLiveActivityExtension` (a `PBXFileReference` plus a
`PBXBuildFile` referencing it from the second target's Sources phase,
alongside its own file-system-synchronized group rather than replacing it).
There is now exactly one definition to keep in sync with itself.

**Command IDs, dedup, and timeout.** Every Watch → phone command now carries
a `commandID` (`WatchSessionKey.commandID`), a fresh `UUID` string generated
per `send()` call. `RecordingCommandRouter.handleWatchCommand` caches the
last 20 `(commandID, handled, phase)` results; a redelivered duplicate — the
watch retrying after a lost reply — replays the cached outcome instead of
pausing, stopping, or marking a highlight a second time for one user action,
and `unregister()` clears the cache so a new recorder session starts clean.
`WatchConnectivityManager.send` gained a 10s local timeout
(`WatchCommandReplyBox`, a lock-guarded resume-exactly-once continuation
box — the same shape `RecorderViewModel.storeMicChoiceContinuation`
established in PR 18 for the same class of problem: `WCSession`'s
replyHandler/errorHandler and a `Task.sleep` timeout are two independent
completion sources with no structured-concurrency relationship, racing to
settle one continuation), so a remote-control button can't spin forever
against a phone that never answers.

**Three-phase acknowledgements (`received`/`stateChanged`/`finalized`).**
Every `RecordingCommandRouter` handler in this app already runs
synchronously to completion — `RecorderViewModel.stopAndSave()` included,
whose file finalization is entirely synchronous — before its caller learns
the outcome, so a *single* reply carrying `WatchAckPhase` covers item 7's
three cases without a multi-message round trip: `.received` when there was
no active session to act on, `.stateChanged` for pause/resume/highlight (and
a `stop` whose capture ended but didn't cleanly finalize), `.finalized` for
a `stop` that was durably saved. This is what `onStop`'s type change from
`() -> Void` to `() -> Bool` carries: `stopAndSave()`/`finalizeCapture`/
`discardShortRecording` all now return whether the outcome was durable,
threaded straight through to the reply instead of being discovered only
after the fact.

**Reconnect reconciliation.** `PhoneSessionController`'s
`activationDidCompleteWith` handler now checks
`RecordingCommandRouter.shared.hasActiveSession` on every (re)activation and,
if false, pushes a fresh idle context (`notifyEnded()`). A live recorder
session never survives process termination, so a fresh launch — including
one after a kill mid-recording — always starts with `hasActiveSession ==
false`; without this, any "recording"/"paused" application context
`WCSession` was still holding from before the kill would leave the Watch
showing a phantom in-progress recording until the user happened to start
and stop another one.

**F3 intent semantics (item 8).** `StartRecordingIntent.perform()` used to
post `.kurnStartRecordingRequested` and return `.result()` unconditionally —
claiming success even when `RecordingLauncher.configure()` hadn't run yet
(a cold-launch race) and the request was silently dropped. It now awaits a
reply notification (`.kurnStartRecordingRequestHandled`, `userInfo
["accepted"]`) from `RecordingLauncher.handleAutoStartRequest()`, bounded by
a 3s timeout via the same resume-exactly-once box shape as the Watch
timeout above (`StartRecordingAcceptanceBox`, with the `NSObjectProtocol`
observer token stored under the *same* lock as the continuation rather than
a bare captured `var` two independent closures would otherwise race to
remove). `RecordingLauncher.requestAutoStart()` now returns `Bool`: `true`
for "queued a meeting" or "a recording is already in progress" (still a
legitimate accepted outcome, not a failure), `false` only when the app
genuinely could not act (`configure()` hadn't run). A `false` result throws
`StartRecordingIntentError.notReady` (new `intent.startRecording.notReady`
localization key, all seven locales, mirrored into
`KurnLiveActivityExtension`'s copies alongside the intent's existing
title/description/shortTitle keys). What this deliberately does *not* do:
wait for actual microphone capture to start. `RecorderView`'s mic-permission
flow and `AudioRecorderService` run after this intent has already returned
`openAppWhenRun`'s foregrounded app UI, and there is no channel back from
that flow to a completed `perform()` call — confirming real capture remains
the Lock Screen Live Activity's job, unchanged.

**Item 1, audited against its own named examples.** The plan's "chat/search
tasks cancel on dismissal" names two concrete cases, both checked:
`MeetingsListView`'s semantic-search debounce (`.task(id: searchText)`)
already gets correct cancel-on-dismiss and cancel-on-new-query for free from
SwiftUI's `task(id:)` modifier — audited, no change needed.
`MeetingChatViewModel`'s reply `Task`, by contrast, had nothing cancelling
it when the owning `MeetingChatView` (which owns the view model via
`@State`) was dismissed mid-reply — an abandoned chat sheet kept a paid
cloud LLM call running to completion in the background. Fixed with a
`deinit { task?.cancel() }`: `Task.cancel()` is safe to call from any
isolation, including a nonisolated `deinit`, and deinit is the reliable
backstop regardless of which dismissal path was taken. The broader
"operation ownership/run ID" mechanism item 1 asks for as a *general*
pattern was not found to need further work beyond what PR 18 (continuation
leaks) and PR 19 (the ActivityKit `runID`) already fixed — `ResourceScheduler`
(PR 17), `TranscriptionScheduler`, `ModelDownloadController`, and
`RecorderViewModel.activeRecording` were the other candidates considered and
were already correctly scoped.

**Tests.** `KurnTests/RecordingCommandRouterTests.swift` (new): dedup
(a duplicate `commandID` replays the cached result without re-invoking the
handler; distinct IDs are not treated as duplicates; `unregister()` clears
the cache), and `WatchAckPhase` selection (`.received` with no active
session, `.finalized` when the handler reports a durable save, `.stateChanged`
when it doesn't) — all pure `@MainActor` state on the router, so unlike
ActivityKit or real `WCSession` traffic these are directly and
deterministically testable. `KurnTests/RecordingLauncherTests.swift` gained
assertions on `requestAutoStart()`'s new `Bool` return (accepted when a
meeting is queued; still accepted, not a failure, when a recording is
already in progress) and two call sites elsewhere in `KurnTests` that
register `onStop` closures were updated for the `() -> Bool` signature.

**Known gaps, stated plainly.**

- **The Watch-side timeout, the reconnect reconciliation, and the intent's
  acceptance wait are not covered by automated tests** — real `WCSession`
  traffic and `NotificationCenter`-based cross-callback races aren't
  reproducible deterministically without a paired device/simulator pair
  (`KurnWatchUITests` doesn't run in `iOS CI` today, per the accessibility
  section's own stated gap) or risk the same non-deterministic-ordering
  problem PR 19 already declined to force for ActivityKit. Verified by CI
  compiling and the existing suite passing, plus the same
  already-proven-in-this-codebase resume-exactly-once box shape used for
  `storeMicChoiceContinuation` (PR 18) and the Watch command timeout itself.
- **The "not configured yet" `requestAutoStart() == false` path has no
  automated test** — see the note in `RecordingLauncherTests.swift`:
  `RecordingLauncher` is a real process-wide singleton with no reset hook,
  and Swift Testing's `.serialized` gives no ordering guarantee across the
  suite's other tests, all of which call `configure()`.
- **Command IDs are generated client-side (`UUID().uuidString`) with no
  cryptographic binding to the session** — sufficient for this feature's
  actual threat model (a lost-reply retry from the *same* watch app, not an
  adversarial replay), consistent with `WCSession` itself carrying no
  authentication beyond OS-level device pairing.
- **Item 1's general "owner, run ID and explicit lifetime" mechanism was
  audited, not exhaustively re-implemented** — the two examples the plan
  itself names were checked and one was fixed; a full sweep of every
  `Task` in the app for the same pattern was judged out of scope for one PR
  boundary, consistent with PR 18's own audit methodology (check named
  examples and anything encountered along the way, not the whole codebase
  speculatively).

### Phase E — Actionable recovery and diagnostics

#### PR 21 — H9 structured errors and per-operation queues

Extend presentation metadata around `AppError` with category, severity,
retryability, safe explanation, private context, and recovery action IDs. Queue
blocking errors per operation and retain warnings in operation reports.
Cancellation is silent.

Status: merged into `main` as
[PR #178](https://github.com/carlosmazzei/Kurn/pull/178) (commit
`674687c`). CI green on the first push.

**The metadata (item 1).** `Packages/KurnCore/Sources/KurnCore/Infrastructure/AppErrorMetadata.swift`
(new, kept out of `AppError.swift` itself to keep that file to its own
concerns as this grows) adds four per-case properties: `category`
(`AppErrorCategory`, 11 cases — network/provider/transcription/audio/
storage/permission/authentication/resource/model/generation/integrity),
`severity` (`AppErrorSeverity.blocking`/`.warning`), `isRetryable`, and
`recoveryAction` (`AppErrorRecoveryAction?` — a stable identifier for the
single most relevant next step, not a UI: wiring these into actual
contextual buttons is item 2, a later PR). A fifth property,
`privateContext: String?`, surfaces the raw associated-value detail a
handful of cases already carried (typically another error's own
`localizedDescription`) as its own field, distinct from the safe,
localized `errorDescription` — not wired into any export or redaction path
yet, since that's item 6 (PR 22); this only names the field so that PR has
something to read. `category`'s switch has no `default`, so a future
`AppError` case added without a matching `category` arm fails to compile;
the other three intentionally do have a `default`, since they're judgment
calls a missing-case compile error can't validate — `AppErrorMetadataTests`
covers those instead. One correction made along the way:
`.authenticationFailed` (from `RecordingAccessGate`'s Face ID/Touch ID/
passcode gate) reads as a provider-authentication case by name alone, but
is unrelated to `AIProvider`; categorized as `.authentication`, not
`.provider`.

**The per-operation queue (item 3), scoped to the one concrete case
found.** `TranscriptionViewModel` is a single app-wide shared instance
(`KurnApp.swift`, injected via `.environment`, read by every
`MeetingDetailView` through `@Environment(TranscriptionViewModel.self)`) —
confirmed by reading every `TranscriptionViewModel(...)` call site in the
app (exactly two: `KurnApp`'s shared instance and
`TranscriptionScheduler`'s own separate one for the background resume
pass; a stale comment on `globalActiveIDs` claiming "`MeetingDetailView`
creates a view model per screen" was wrong and is corrected in the same
commit). Its `var error: AppError?` was one shared property regardless of
which recording's transcription set it, so a background transcription
failure for Recording B could pop up as an alert on the screen for
unrelated Recording A, or Recording A's own unrelated `modelContext.save()`
failure (e.g. renaming the meeting) could silently overwrite/hide
Recording B's real transcription failure before the user ever saw it. Now
split: `errorsByRecording: [UUID: AppError]`, keyed exactly like the
existing `diarizationWarnings: [UUID: String]` right next to it (same
problem, already solved once for a non-`AppError` warning type — this
generalizes that shape to blocking errors rather than inventing a new
one), with `transcriptionError(for:)`/`clearTranscriptionError(for:)`
accessors. `MeetingDetailView`'s `.errorAlert` now binds to a
`transcriptionErrorBinding` that surfaces the *first* of this meeting's own
`queriedRecordings` with a queued error and clears only that recording's
slot on dismiss — a second recording's still-queued failure (rare, but the
plan's "queue" wording allows for it) surfaces on the next evaluation
rather than being silently dropped alongside the first. `persist()` and
the AI-title-generation path deliberately keep using the original `error`
property: `persist()` commits whatever SwiftData has pending across the
whole context in one call, not one recording's own changes, so it has no
natural single recording to key against, and retrofitting it (13 call
sites across 5 files, several of them meeting-scoped rather than
recording-scoped) was judged a separate, riskier change not required to
fix the concrete bug this PR targets — stated as a known gap below rather
than attempted partially.

**Cancellation is silent (part of item 1) — audited, already correct.**
Checked the app's four biggest cancellable async flows:
`TranscriptionViewModel.transcribe`, `...+Summary.generateSummary`,
`DocumentGenerationViewModel`'s generation, and
`MeetingChatViewModel.send`. All four already catch `CancellationError`
(and, for summary generation, its `AppError.networkError` cancellation
shape) ahead of any catch-all that would otherwise set a visible `error`,
so a user-initiated cancel never surfaces as an alert. No fix needed; this
is recorded so a future PR doesn't re-derive it from scratch.

**Tests.** `Packages/KurnCore/Tests/KurnCoreTests/AppErrorMetadataTests.swift`
(new): the `.authenticationFailed` categorization fix, representative
severity/retryability/recoveryAction spot-checks per category (not
exhaustive over all 32 cases — `category`'s own missing-case compile error
already guarantees full coverage there), and `privateContext` pass-through
for cases that carry it vs. `nil` for those that don't.
`KurnTests/TranscriptionViewModelErrorAttributionTests.swift` (new): two
different recordings' failures set via a `#if DEBUG`-only
`setTranscriptionErrorForTesting(_:for:)` (matching the established
test-only-accessor pattern rather than widening the real API) don't
clobber each other, clearing one leaves the other intact, and a recording
with no failure reports none. Doesn't drive `transcribe()` itself — no
harness in this test target mocks the full pipeline (real engines) needed
to reach its catch blocks, so the isolation is tested directly on the
dictionary rather than end-to-end.

**Known gaps, stated plainly.**

- **`persist()` and the AI-title-generation path are not recording-scoped**
  — see "The per-operation queue" above. The single concrete symptom this
  PR targets (two *transcriptions* clobbering each other) is fixed;
  a `persist()` failure racing a transcription failure on a different
  recording is not, and remains the shared `error` property's behavior,
  unchanged from before this PR.
- **Item 2 (contextual recovery actions — Retry, Free Space, Open
  Settings, ...) is not built.** `recoveryAction` exists as data; no UI
  reads it yet. Every error dialog still shows the same "OK" it did
  before.
- **Item 4 (rolling back optimistic UI mutations after a persistence
  failure) is not attempted.**
- **H5 PR 13's "revisit when H9's action-metadata model lands" note**
  (`MeetingDetailView`'s completed-with-warnings banner, which explicitly
  deferred integrating with H9) is not revisited here — that's UI wiring
  work belonging with item 2, not this PR's data-model boundary.
- **Items 5–8** (structured reliability events beyond what
  `ReliabilityEvent`/`ReliabilityLog` already provide, the bounded
  encrypted event buffer, redacted export, the health/recovery center,
  and accessibility coverage of recovery UI) **remain PR 22–23's scope.**

#### PR 22 — H9 bounded encrypted events and redacted export

Standardize content-free operation events, remove public raw error descriptions
from resilience paths, keep a protected bounded local buffer, and provide a
redaction preview plus short reference ID. Nothing uploads automatically.

Status: merged into `main` as
[PR #179](https://github.com/carlosmazzei/Kurn/pull/179) (commit `0765891`,
merge commit `ea6eae8`). CI green on the first push.

**The bounded, protected local buffer (item 6).** `ReliabilityEvent`/
`ReliabilityLog` already existed (an earlier "Baseline and seams" step) as
a content-free vocabulary, but `ReliabilityLog.handler` only forwarded to
`os.Logger` — nothing durable, and Console.app only reads that from a
connected Mac, not from the device itself. `Kurn/Infrastructure/
ReliabilityEventStore.swift` (new) adds the buffer: one append-only
JSON-Lines file under `Application Support/ReliabilityEvents/`,
directory- and file-protected the same `.completeUnlessOpen` way
`DiagnosticReportStore` already protects MetricKit reports, capped at 500
events (pruned once it grows 100 past that, so pruning isn't a full
file rewrite on every single append). `KurnApp.swift`'s
`ReliabilityLog.handler` now also calls `ReliabilityEventStore.record`
alongside its existing `os.Logger` forwarding — both, not a replacement.
Guarded by an `NSLock` rather than made an actor: `ReliabilityLog.handler`
is a synchronous `@Sendable` closure callable from any isolation
(`TranscriptionViewModel` from the main actor, `DocumentGenerationService`
from off it), and an actor would force every call site to `await`, which
that synchronous signature doesn't support.

**Standardizing adoption (item 5), scoped to one concrete path.**
`ReliabilityEvent`/`OperationID` were previously adopted by exactly one
pair of call sites (`DocumentGenerationService`/`DocumentGenerationViewModel`).
`TranscriptionViewModel.transcribe()` — the app's single most important
resilience path, and the one PR 21 already gave per-recording error
attribution to — gets the same instrumentation: one `OperationID` per
attempt (`runID`), correlating a `.started` event at the top with whichever
terminal event the attempt actually reaches (`.succeeded`, `.cancelled` at
both cancellation sites, or `.failed` at all three failure sites — the two
`catch` blocks plus the Speech-permission-denied early return, which PR 21
had missed migrating to `errorsByRecording` and this PR also fixes for the
same reason). Elapsed time is computed from a `startedAt` captured with
`runID`.

**Removing public raw error descriptions (also item 5).** Grepped the app
for `error.localizedDescription`/`.errorDescription` interpolated at
`privacy: .public` (50 hits across 33 files) and narrowed to the precise
pattern item 5 names — an `AppError`'s own `errorDescription` logged
`.public`, which is unsafe because several cases interpolate a raw
underlying system error's `localizedDescription` into their safe
user-facing text (that's exactly what PR 21's `privateContext` property
exists to separate out). Four call sites matched exactly:
`TranscriptionViewModel.transcribe`'s two failure branches (fixed as part
of the instrumentation above), `RecorderViewModel`'s `startRecording`
failure path, and `AudioRecorderService.start`'s setup failure path. All
four now log `logCode` at `.public` and `privateContext` at `.private`
instead. The broader 50-hit grep — mostly a raw *non*-`AppError` system
error's own `localizedDescription` (AVFoundation, CoreML, SwiftData, ...)
logged directly — was reviewed and judged a different, much larger
question (is a given library's own error text ever privacy-sensitive) not
answerable case-by-case within this PR's scope; stated as a known gap.

**The redaction preview (item 6's other half).**
`Kurn/Views/ReliabilityEventsListView.swift` (new), wired into
`DiagnosticsSettingsView` alongside the existing diagnostic-reports row,
lists recent events and shares the exact text a report would contain.
Every `ReliabilityEvent` field is content-free *by construction* (the
type's own header states this), so showing precisely what would be
exported already delivers what a redaction preview is for — there is
nothing to redact because nothing sensitive was ever admitted into the
event in the first place, rather than needing a separate redaction pass to
catch it after the fact.

**Known gaps, stated plainly.**

- **"A short reference ID that also appears in the UI error" is not
  built.** `errorAlert` (`View+ErrorAlert.swift`) is one shared modifier
  used at 19+ call sites, taking only `Binding<AppError?>` — no
  per-occurrence context to attach a reference ID to. Doing this safely
  needs either widening that shared binding's type everywhere or a
  per-call-site opt-in, either of which is its own design pass; deferred,
  most naturally to PR 23, whose own plan text already mentions "recent
  safe codes" as part of the health/recovery center.
- **The 46 non-`AppError` raw-`localizedDescription`-at-`.public` sites**
  found by the broader grep above are unaudited — see "Removing public raw
  error descriptions."
- **Adoption of `ReliabilityEvent` is now two operations
  (`document_generation`, `transcription`), not every resilience path** —
  summary generation, wiki/document generation's other steps, model
  downloads, and Watch/intent commands (H8) still have no
  `ReliabilityEvent` instrumentation. Widening further was judged separate,
  incremental work rather than required to prove the buffer/export
  mechanism works.

#### PR 23 — H9 health and recovery center

Aggregate pending recovery, quarantine, degraded transcripts, failed/deferred
jobs, model verification, and recent safe codes. Reuse existing recovery actions
and cover VoiceOver, Dynamic Type, offline, low-storage, permission, degraded,
quarantine, and store-recovery states.

Status: merged into `main` as
[PR #180](https://github.com/carlosmazzei/Kurn/pull/180) (commit `9511f32`).
CI green on the first push. **This closes out H9's plan** except items 2 and
4 (contextual recovery-action UI buttons, optimistic-UI rollback),
deliberately deferred as known gaps in PR 21's own write-up.

**"Repair surface, not analytics."** `Kurn/Views/Settings/HealthRecoveryView.swift`
(new, split into `HealthRecoveryView+Sections.swift` to stay under
SwiftLint's `type_body_length` warning) is one screen — Settings → Health &
Recovery — that answers "does anything need my attention" without the user
having to already know which of six different screens tracks which
condition. Every action it exposes calls the *exact same* recovery function
its existing per-item counterpart already calls: `RecordingRecovery
.retryRecovery(for:context:)` (the same call `MeetingDetailView`'s
`RecordingSegmentRow` retry button makes), `TranscriptionViewModel
.startTranscription`/`.retryCorrection` (the same calls `MeetingDetailActions`
makes), and `RecordingQuarantine.recover`/`.delete`/`.exportURL` and
`ModelDownloadController.deleteModel` (the same calls `StorageSettingsView`
already makes, given full recover/export/delete parity here). This screen
only aggregates and dispatches — there is no second implementation of any
recovery behavior to keep in sync with the first.

**What is aggregated, and how.** Three of the six sections reuse an
existing aggregation wholesale (`RecordingQuarantine.items()`,
`ModelDownloadController.installedModels` filtered to `.corrupt`,
`ReliabilityEventStore.recentEvents(limit:)` filtered to `.failed`). The
other three needed a new cross-library query, run in `refresh()`: pending
capture recovery is a `FetchDescriptor<Recording>` on
`captureStateRaw == RecordingCaptureState.recoveryNeeded.rawValue`; stalled
transcriptions is a `FetchDescriptor<Recording>` on
`captureStateRaw == .ready && transcriptionStatusRaw ∈ {.failed, .pending}`;
degraded transcripts fetches every `Transcript`, decodes its
`pipelineReport`, and keeps the ones with `hasWarnings == true` alongside
their recording — `pipelineReportData` is opaque JSON, so this can't be
expressed as a `#Predicate` and every transcript is decoded instead. Every
enum `.rawValue` is pre-extracted into a local `let` before the `#Predicate`
closure, matching this codebase's existing convention. A degraded item's
retry button only appears when the warning is on the `.correction` stage,
the one stage cheap enough to retry without repeating audio/ASR/diarization
— matching the existing per-transcript warning banner's own rule.

**Row interaction.** Each row is two independent sibling `Button`s (a
label-wrapping `Button` with `.buttonStyle(.plain)` for navigation to
`MeetingDetailView`, and a separate `Button` with `.buttonStyle(.borderless)`
for the retry/recover/delete action) rather than a row-level tap gesture
with a button nested inside it, which risks the outer gesture swallowing the
inner button's own taps in a `List`.

**Known gaps, stated plainly.**

- **No new test coverage.** Every action this screen exposes calls an
  already-tested recovery function; the screen's own contribution is
  aggregation (six queries/filters) and dispatch (a thin wrapper per
  action), neither of which introduces new recovery *logic* to verify. Adding
  `HealthRecoveryView`-specific tests would mostly re-test
  `RecordingRecovery`/`RecordingQuarantine`/`TranscriptionViewModel`'s
  existing coverage under a different call site.
- **The reference ID PR 22 deferred here is still not built.** PR 22's
  known gaps named this PR as the natural place for a short reference ID
  surfaced in both the UI error dialog and the events list; this PR's
  "Recent Failure Codes" section reuses the existing `ReliabilityEventsListView`
  and `ReliabilityEvent.logLine` rather than adding a new ID scheme —
  `errorAlert`'s shared `Binding<AppError?>` signature would still need
  widening at 19+ call sites to carry one, which remains its own design
  pass and stays deferred.
- **Items 2 and 4 remain out of scope**, as PR 21 originally stated:
  contextual recovery-action UI buttons wired to `AppErrorRecoveryAction`,
  and optimistic-UI rollback. Neither is implied by "aggregate and dispatch
  to existing actions."

### Phase F — Continuous verification

H10 is implemented inside every prior PR: a new transition without its scripted
failure and post-relaunch assertion is incomplete.

#### PR 24 — H10 split CI signals, retained artifacts, and static policy

Split pure/unit, simulator integration, and UI/accessibility signals. Upload
`.xcresult`, failed screenshots, simulator/system logs, SwiftLint JSON, and
synthetic diagnostics on failure. Add allow-listed checks for production
`fatalError`, durability-boundary `try?`, raw public errors, custom destinations,
and unowned long-lived tasks.

Status: merged into `main` as
[PR #181](https://github.com/carlosmazzei/Kurn/pull/181) (commit
`6189f1a`). All five real jobs passed on the first push, confirmed by
reading the job logs directly rather than trusting the pass/fail summary:
`unit-tests` ran 934 tests in 113 suites (`KurnTests`) plus 13 in 3 suites
(`KurnSwiftDataTests`) with zero real failures (the single "error:" grep
hit was a deliberately-triggered network-error log line inside a
correction-fallback test, not a failure); `ui-accessibility-tests` ran 12
tests (`AccessibilityAuditUITests` + `ModelStoreRecoveryUITests`) with
`ScreenshotUITests` correctly excluded.

**Splitting the signals (item 3).** `.github/workflows/swift.yml`'s single
`build-and-test` job used to run SwiftLint, both config validators, and the
scheme's entire `TestAction` (`KurnTests` + `KurnSwiftDataTests` +
`KurnUITests`) as one `xcodebuild clean test` — one red X for a lint typo, a
data-integrity regression, or a flaky UI-test launch alike, indistinguishable
without opening the log. It is now five jobs, all parallel (no `needs:`
between them): `lint-and-validate` (SwiftLint, localization key-set parity,
App Store metadata — genuinely no simulator needed, so it now reports before
`unit-tests`/`ui-accessibility-tests` finish downloading a simulator
runtime), `static-policy` (below), `unit-tests` (`-only-testing:KurnTests
-only-testing:KurnSwiftDataTests` — the "simulator integration" signal;
`kurncore-linux`, unchanged, remains the fast pure/unit signal the plan
calls for), and `ui-accessibility-tests` (`-only-testing:KurnUITests
-skip-testing:KurnUITests/ScreenshotUITests`, the same skip the scheme
itself already declares for `AccessibilityAuditUITests`).
`release`/`beta`/`store-assets`'s `needs:` widened to all five.

**Retained artifacts (item 4).** Both Xcode test jobs now pass
`-resultBundlePath` and, `if: failure()`, upload the resulting `.xcresult`
(which already carries the full test log, timings, and — for a failing
`AccessibilityAuditUITests` case — its failure screenshot as an attachment,
so no separate extraction step exists) plus a best-effort simulator log
collection (`xcrun simctl spawn <booted-udid> log collect`, guarded end to
end with `|| true`/`set +e` since this step runs on an already-failing job
and must never itself become the reported failure). SwiftLint's JSON report
upload already existed and is unchanged, now inside `lint-and-validate`.

**Static policy (item 6), scoped down from the plan's five categories to
two, plus one line item under a third.** `Tools/check_static_policy.py`
(new; `static-policy` job, `ubuntu-latest`, no Xcode) is a narrow text
scanner, not a real analyzer, so it only checks patterns where a textual
match is actually reliable signal:

- **`fatal-error`** — production `fatalError`/`preconditionFailure`.
- **`unchecked-save`** — `try? <context>.save()`, the exact anti-pattern
  `ModelContext+Save.swift`'s own header names as what it replaced;
  `saveOrError()` is the sanctioned alternative.
- **`custom-url-session`** — an ad hoc `URLSession(...)` outside the app's
  three sanctioned transport/download seams (`ProviderHTTPTransport`,
  `ModelFileDownloader`, `WhisperBackgroundUploader`) — item 6's "custom
  destinations."
- **`raw-public-error`** — `.localizedDescription`/`.errorDescription`
  interpolated at `privacy: .public`, the same textual pattern PR 22 used
  to find its four exact sites.

Every finding is either fixed, added to `Tools/static_policy_baseline.txt`
(grandfathered, keyed by exact line content so it survives unrelated line
shifts elsewhere in the file — not by line number, which churns), or given
an inline `// static-policy:allow <check> - <reason>` comment on the same
line or the line above (mirroring this codebase's `// swiftlint:disable:next`
shape). Running the checker against the codebase as it stood when this PR
was written found 3 `fatal-error` (all provably-unreachable: two exhaustive
switches' `.appleOnDevice` case already handled by an earlier guard, one
`vDSP.DiscreteFourierTransform` setup call whose only failure mode is
already ruled out by a `precondition` immediately above), 3
`custom-url-session` (exactly the three sanctioned seams above — nothing
else in the app constructs its own session), 0 `unchecked-save` (already
fully compliant — `ModelContext+Save.swift` had already closed this one),
and 50 `raw-public-error` sites, all baselined rather than fixed blind:
these are H9 PR 22's own stated known gap, "the broader 46-site
non-`AppError` raw-log-description sweep... a different, much larger
question (is a given library's own error text ever privacy-sensitive) not
answerable case-by-case" — grandfathering them here does not re-open or
resolve that question, it only stops the count from growing while a real
audit remains a separate, deliberate piece of work.

**Two of the plan's five categories are not checked — a scope cut, not an
oversight.** "Unowned long-lived tasks": 101 `Task { }` sites exist, only
21 with `[weak self]`; narrowing to the 13 sites that actually matter (a
`Task` *stored* in a property, since only a stored reference can outlive
its intended scope) found only one of the 13 owning types
(`MeetingChatViewModel`, already fixed in H8 PR 20) has a `deinit` at all —
the other 12 are process-lifetime app/actor singletons
(`TranscriptionViewModel`, `ModelDownloadController`,
`FluidAudioModelStore`, …) for which "no `deinit`" is correct, not a leak.
Distinguishing a per-screen view model that should cancel on
deinitialization from a singleton that correctly never does needs type
lifecycle knowledge no text scan has. "Durability-boundary `try?`" beyond
`ModelContext.save()`: ~200 `try?` sites exist app-wide, the large majority
legitimately best-effort (temp-file cleanup, diagnostic sidecars); telling
those apart from a silently-dropped durable commit needs the same kind of
semantic judgment. Both stay manual-audit items — the same shape as H8
PR 18's concurrency-bridge audit, which was also done by hand rather than
with a generic pattern match — rather than shipping a check whose false-
positive rate would make it noise nobody could act on.

**Known gaps, stated plainly.**

- **No build-once/test-many optimization.** Each of the three macOS jobs
  (`lint-and-validate`, `unit-tests`, `ui-accessibility-tests`) runs its own
  full `clean` build; splitting the single job into three roughly triples
  total macOS compute versus sharing one `build-for-testing` output across
  `test-without-building` runs. That sharing needs passing Xcode's
  `DerivedData`/`.xctestrun` between jobs via artifact upload/download,
  which is its own source of flakiness (path/ABI mismatches, large-artifact
  transfer time) and impossible to validate without the macOS/Xcode
  toolchain this environment doesn't have (see "Verifying without a local
  macOS/Xcode toolchain" in `CLAUDE.md`); kept out on purpose rather than
  shipped unverified. A future PR can revisit this once the three-job split
  itself is confirmed green.
- **The workflow YAML and the new Python checker are verified by static
  validation only** (`yaml.safe_load`, `bash -n` on every extracted `run:`
  block, the Python one-liner run directly against sample JSON) — not by an
  actual `xcodebuild`/`simctl` invocation, since none is available here.
  The `xcrun simctl spawn ... log collect` flag shape is the least certain
  part; it is guarded end to end (`set +e`, `|| true`, a final `exit 0`) so
  a wrong flag degrades to "no simulator log collected," never a second,
  confusing failure layered on top of the real one.
- **Items 1–2 and 5, 7 of H10's plan remain**: injectable fault-injection
  protocols and the fault matrix (item 1–2, largely threaded through prior
  PRs' own fakes already — `ClockProviding`, `ReliabilityEventStore`, etc.
  — rather than a single PR); the scheduled/release hardening lane (item 5,
  PR 25's scope); the manual physical release checklist (item 7) already
  exists as this document's own "Release-only physical matrix" section and
  needs no code.

#### PR 25 — H10 scheduled/release hardening and scorecard

Add repeated cancellation/concurrency tests, migration fixtures, Release launch,
supported sanitizers, repeated UI subset, and measured flake rate. Keep the
manual physical checklist versioned and make it a release gate. Record baseline
counts without inventing a numeric reliability SLO.

Status: merged into `main` as
[PR #182](https://github.com/carlosmazzei/Kurn/pull/182) (commit
`dd4526a`). This PR also folds in test-coverage measurement and Codecov
reporting, added at the user's explicit request alongside its own scope
rather than as a separate follow-up. All five real `iOS CI` jobs passed on
the first push; the three new coverage-export steps
(`unit-tests`/`ui-accessibility-tests`'s `xcrun xccov`,
`kurncore-linux`'s `llvm-cov export`) were confirmed working by reading
the job logs directly, each producing a real coverage file the Codecov
CLI recognized before failing only on the expected "Token required" error
(no `CODECOV_TOKEN` configured yet), with `fail_ci_if_error: false`
keeping every job green as designed.

**A new, separate lane, not a widening of `iOS CI` (item 3, 5).**
`.github/workflows/reliability-hardening.yml` (new) triggers on
`workflow_dispatch` and a weekly Sunday cron, deliberately not `push`/
`pull_request` — the whole point of a "scheduled/release hardening lane"
is that it is slower and noisier than what gates every PR. It has four
jobs:

- **`thread-sanitizer`** — `-enableThreadSanitizer YES`, run as two
  independent matrix attempts (not retries of each other; both report).
  Scoped to the app's concurrency-sensitive suites specifically —
  `ResourceSchedulerTests`, `ResourceGuardTests`,
  `TranscriptionRecoveryTests`, `SpeechEnhancerTests`,
  `RecordingAccessGateTests`, `MeetingChatViewModelTests`,
  `ChunkedTranscriptionRunnerTests`, `SummaryMapRunnerTests`, and all of
  `KurnSwiftDataTests` (the target this project already isolated for a
  known SwiftData concurrency crash) — not the full ~950-test suite,
  whose TSan-instrumented runtime would make a weekly job impractically
  slow for little extra signal over the curated set. This is the first
  Thread Sanitizer configuration in the project; H7/H8's own write-ups
  named its absence as a stated gap ("no Thread Sanitizer configuration
  exists yet").
- **`release-configuration-tests`** — the same `KurnTests`/
  `KurnSwiftDataTests` selection as `iOS CI`'s `unit-tests`, but
  `-configuration Release` instead of the implicit Debug every other job
  uses. Release strips some assertions and enables whole-module
  optimization, either of which can hide or change the shape of a
  precondition/concurrency bug a Debug run never exercises.
- **`ui-flake-rate`** — five independent attempts at the same
  `-only-testing:KurnUITests -skip-testing:KurnUITests/ScreenshotUITests`
  selection `ui-accessibility-tests` runs on every PR. Each attempt
  uploads its own pass/fail marker as an artifact rather than only
  reporting the matrix job's overall (necessarily coarser) green/red, so
  the rate is an actual `passed/total`, not a guess from whether any leg
  went red.
- **`hardening-summary`** — downloads every attempt's marker, counts
  `passed/total` per repeated job, and writes a Markdown table to
  `$GITHUB_STEP_SUMMARY`. No pass/fail gate, no invented numeric SLO —
  the same "a maintainer reads and records a run by hand" philosophy
  `pipeline-eval.yml`/`docs/pipeline-evaluation.md` already established
  for accuracy measurement, applied here to reliability. `needs:` the
  three job types above but runs with `if: always()` so a red attempt
  still gets counted rather than skipping the summary.

Migration fixtures (also item 5) are not duplicated into this lane:
`LegacyStoreAdoptionTests` already runs on every PR inside `unit-tests`,
and H2's own design generates its legacy-store fixture same-run rather
than from committed N-1/N-2 binaries (see the H2 schema-baseline handoff),
so there is no separate fixture surface this lane would add coverage for
by re-running it on a schedule.

**The versioned physical checklist, made an actual release gate (item
7).** `docs/release-physical-checklist.md` (new) converts this document's
prose "Release-only physical matrix" bullets into an actual checkbox list
a maintainer runs on a real device — Data Protection, screen lock during
capture, phone/Siri interruption, Bluetooth route changes, background
expiration, low storage, memory/thermal pressure, Watch reconnect/
duplicate-command handling, and model compilation/cancellation on real
hardware. It is genuinely the release gate for everything a Simulator
cannot reproduce: `beta` and `submit` in `.github/workflows/swift.yml`
each gained a step that records a reminder to `$GITHUB_STEP_SUMMARY`
pointing at the file. That step cannot appear *before* the `release`
GitHub Environment's approval gate — a workflow step only runs after
approval is already granted, and GitHub's own approval UI is the only
surface that runs earlier, which this workflow has no way to add to — so
its role is a durable, hard-to-miss record on the run itself for whoever
reviews it, not a technical block. The file's own closing section states
this plainly rather than overclaiming automated enforcement.

**Coverage measurement and Codecov (added at the user's request,
alongside this PR's own scope).** `unit-tests` and `ui-accessibility-tests`
in `iOS CI` now pass `-enableCodeCoverage YES` and export a JSON report via
`xcrun xccov view --report --json` (bundled with Xcode, stable since
Xcode 11) from the `.xcresult` each already produces; `kurncore-linux`
adds `swift test --enable-code-coverage` and locates the resulting LLVM
profile/binary by search (SwiftPM prints no path for either) to export an
lcov report via `llvm-cov export`. All three upload to Codecov
(`codecov/codecov-action@v5`, `flags: unittests`/`uitests`/`kurncore` so
the three surfaces stay distinguishable rather than one blended number)
with `fail_ci_if_error: false` — a Codecov outage or a not-yet-configured
`CODECOV_TOKEN` secret must never turn an otherwise-green PR red over a
third-party service correctness doesn't depend on. `codecov.yml` (new,
repo root) marks every coverage status `informational: true`: the same
"no invented numeric SLO" rule this PR's own hardening-lane summary
follows, applied to coverage — Codecov reports the number, it does not
gate the merge on one nobody has established a baseline for yet.

**Known gaps, stated plainly.**

- **`CODECOV_TOKEN` is not configured by this PR.** A maintainer needs to
  connect the repository at codecov.io and add the resulting token as a
  repo secret; until then, coverage upload steps no-op (by design,
  `fail_ci_if_error: false`) rather than failing CI.
- **`kurncore-linux`'s coverage export is the least-verified piece of this
  PR.** No macOS/Xcode toolchain exists anywhere in this project's
  authoring environment to run a real `swift test --enable-code-coverage`
  and confirm the exact `.build/` layout `llvm-cov export` needs; the
  binary/profile discovery was smoke-tested against a synthetic directory
  layout standing in for SwiftPM's real output, both the macOS-bundle and
  Linux-flat-executable shapes, but not against a real build.
  `continue-on-error: true` on that one step so a wrong path assumption
  degrades to "no Linux coverage this run," not a red `kurncore-linux`
  job — which otherwise stays the fast, load-bearing pure-logic signal
  every PR depends on.
- **The `xcrun simctl ... log collect` step reused in
  `reliability-hardening.yml`'s three Xcode jobs carries the same
  not-yet-exercised-on-a-real-failure caveat PR 24's version does** — see
  that PR's own known gaps.
- **Items 1–2 of H10's plan** (the narrow injectable-fault-protocol seams
  and the full fault-injection matrix as a single, explicit artifact) stay
  threaded through prior PRs' own fakes (`ClockProviding`,
  `ReliabilityEventStore`, `ModelDownloading`, and the rest) rather than
  landing as one PR that introduces them from scratch — consistent with
  how this track has built durability seams incrementally since H1, not a
  gap specific to this PR.

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

The versioned, checkbox form of this matrix a maintainer actually runs
before a release — H10 PR 25, item 7's "keep the manual physical checklist
versioned and make it a release gate" — is
[`docs/release-physical-checklist.md`](release-physical-checklist.md).

## Explicitly deferred or out of scope

- New product features and unrelated diarization improvements.
- Background cloud upload while origin-lock cannot be guaranteed.
- Streaming before measured latency/memory evidence and atomic final-output
  semantics.
- Automatic diagnostic transmission or a third-party analytics SDK.
- A numeric reliability SLO before an instrumented baseline exists.
- Weakening branch protection, CI policy, package-security controls, or privacy
  guarantees to make a PR green.
