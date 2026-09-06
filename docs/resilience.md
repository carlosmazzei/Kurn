# Reliability and Resilience

This is the single source of truth for Kurn's reliability/resilience track:
product invariants, risk register, per-track (H1–H10) contracts, the PR-by-PR
execution log, and current status. It used to be split across
`docs/roadmap.md`'s "Reliability and resilience track" section and
`docs/resilience-megaplan.md`; the two were merged here because they had grown
to describe the same H1–H10 work three times over (a status table, a risk
register, and a PR-by-PR handoff log, each independently maintained) with no
remaining reason to keep them separate now that the original 25-PR sequence is
complete. `docs/roadmap.md` still owns the rest of the product roadmap
(F1–F10, the diarization track) and links here for resilience.

This track is not a claim that Kurn is generally unreliable. It is the result
of a static, repository-wide failure-path audit on 2026-08-29, covering
capture, SwiftData, file mutation, transcription, cloud providers, model
downloads, background execution, WatchConnectivity, Live Activities,
diagnostics, UI state, and CI. The code already contains unusually strong
recovery work; the purpose of this document is to turn the remaining implicit
assumptions into explicit, testable contracts — and, now that most of them are
closed, to record what shipped and what (if anything) is still open per track.

A green CI run proves that the tested paths compile and pass; it does not
prove that disk exhaustion, a locked background launch, process death, a
broken route, or a malformed provider behaves safely until that failure is
injected. As with accuracy under I3, resilience must be measured rather than
inferred from clean-path tests.

## Reliability invariants

The five product invariants at the top of `docs/roadmap.md` still apply.
Hardening adds six operational invariants:

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

## Foundation already present

The plan builds on these controls rather than replacing them:

| Area          | Existing control                                                                                                                                                 |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Error domain  | `AppError` provides localized, content-free `logCode`s; `errorAlert` gives views one presentation path                                                           |
| Capture       | Fixed-format `RecordingSink`, audio interruption/route observers, engine restart, `finalizeIfAbandoned`, protected recording storage, and orphan recovery        |
| Transcription | Per-chunk checkpoints, ordered pipeline events, foreground and launch recovery sweeps, background task cancellation, and per-recording/global in-flight guards   |
| Pipeline      | Resource checks between heavy stages, temporary-file cleanup, measured WER/DER, and useful fallbacks for optional preprocessing/VAD/diarization stages           |
| Network       | Fail-closed destinations, origin locks, total deadlines, response caps, logical request identity, bounded retry/cooldown, and Wi-Fi-first large-transfer consent |
| Diagnostics   | Leveled `os.Logger`, user-exported logs, opt-in local MetricKit crash/hang reports, and no automatic diagnostic upload                                           |
| Tests         | 900+ Swift Testing cases, provider stubs through `MockURLProtocol`, recovery/resource tests, accessibility audits, and Linux `KurnCore` CI                        |

## Status

Status is evidence-based: PR [#151](https://github.com/carlosmazzei/Kurn/pull/151)
established the first baseline; later rows include controls that predated
that PR where they already satisfied part of a planned contract. "See
Execution log below" points at the PR-by-PR detail further down this document.

| Track                                                                            | Priority                   | Status                                                                                   | Remaining                                                                                                                                                                                                                                                          |
| --------------------------------------------------------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Baseline and seams                                                                 | —                            | In progress                                                                                | `OperationID`/`ReliabilityEvent`, injectable `SleepClock`, scoped `FileSystem`, `ModelContainerFactory`, `AudioSinkWriting`, and deterministic fakes are present. Filesystem/store/network coverage is still intentionally narrow, and there is no complete fault-matrix harness. |
| **H1** · Lossless capture and truthful finalization                                | P0 release gate             | Core merged in [PR #153](https://github.com/carlosmazzei/Kurn/pull/153)                    | Physical protection, route, interruption, background, and low-storage release matrix — see "Completed H1 boundary" below and `docs/release-physical-checklist.md`.                                                                                              |
| **H2** · Recoverable store bootstrap and explicit migrations                       | Done                         | Done, merged ([#155](https://github.com/carlosmazzei/Kurn/pull/155), [#157](https://github.com/carlosmazzei/Kurn/pull/157), [#158](https://github.com/carlosmazzei/Kurn/pull/158)) | Nothing open.                                                                                                                                                                                                                                                       |
| **H3** · Atomic model/file mutations and non-destructive reconciliation            | Done                         | Done, all PR boundaries merged ([#159](https://github.com/carlosmazzei/Kurn/pull/159), [#160](https://github.com/carlosmazzei/Kurn/pull/160), [#162](https://github.com/carlosmazzei/Kurn/pull/162), plus commits `d7e3dee`/`e7a156a`) | Nothing open. A separate reconciliation pass for derived (enhanced) copies remains uncovered, but they stay separately disposable and are never quarantined, so nothing is at risk.                                                                              |
| **H4** · Checkpoint identity and durable operation state                           | P0 → closed except item 3   | Done, PR 8/9/10 merged ([#165](https://github.com/carlosmazzei/Kurn/pull/165), [#166](https://github.com/carlosmazzei/Kurn/pull/166), [#167](https://github.com/carlosmazzei/Kurn/pull/167)) | Item 3 (the full explicit operation-state enum with reason codes/`nextAttemptAt`) is deliberately deferred until a concrete need shows up. `DocumentGenerationService` has no durable map-stage resumability — it spans multiple meetings, so there is no single `Meeting` to checkpoint against. |
| **H5** · Typed degradation and output-integrity gates                             | Done                         | Done, merged ([#168](https://github.com/carlosmazzei/Kurn/pull/168), [#169](https://github.com/carlosmazzei/Kurn/pull/169), [#170](https://github.com/carlosmazzei/Kurn/pull/170)) | Nothing open — H5's plan is fully addressed.                                                                                                                                                                                                                       |
| **H6** · Exact network boundaries, bounded retry, and cost control                 | P1                           | Core implemented                                                                            | Dedicated waiting UI (owned by H9), FluidAudio's unobservable mid-transfer path changes (its library exposes no session to preflight against), and measured streaming evaluation before it's more than evidence-gated polish.                                    |
| **H7** · Credential and model integrity                                           | P1 → closed except one item  | Done, merged (PR 14/15/16, [#171](https://github.com/carlosmazzei/Kurn/pull/171)/[#172](https://github.com/carlosmazzei/Kurn/pull/172)/[#173](https://github.com/carlosmazzei/Kurn/pull/173)) | Pinning whisper.cpp's mutable `resolve/main` source to an immutable revision — no network path to HuggingFace in the authoring environment to obtain a real commit SHA. Models installed before PR 16 read `.unverified`, not corrupt, until their next re-download. |
| **H8** · Operation ownership, resource recovery, and external controls            | Done                         | Done, plan fully addressed (PR 17–20, [#174](https://github.com/carlosmazzei/Kurn/pull/174)–[#177](https://github.com/carlosmazzei/Kurn/pull/177)) | Nothing open.                                                                                                                                                                                                                                                       |
| **H9** · Actionable error UX and privacy-safe diagnostics                          | P1/P2 → partially closed     | Done, plan fully addressed except items 2 and 4 (PR 21–23, [#178](https://github.com/carlosmazzei/Kurn/pull/178)–[#180](https://github.com/carlosmazzei/Kurn/pull/180)) | Item 2 (contextual recovery-action UI) and item 4 (optimistic-UI rollback) remain deliberately out of scope. The broader non-`AppError` raw-log sweep is unaudited; `HealthRecoveryView` has no accessibility test coverage of its own.                          |
| **H10** · Fault injection and CI resilience                                       | P0, cross-cutting            | Done, plan addressed except items 1–2 (PR 24–25, [#181](https://github.com/carlosmazzei/Kurn/pull/181)/[#182](https://github.com/carlosmazzei/Kurn/pull/182), plus the post-megaplan hardening review [#185](https://github.com/carlosmazzei/Kurn/pull/185)) | The full fault-injection protocol/matrix as one explicit artifact stays threaded through prior PRs' own fakes rather than landing as a single PR.                                                                                                                 |

## Reliability scorecard

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
instrumented release establishes rates; later releases compare the same
counters. The immediate release gates are invariants: no loss of the only
original under an injected failure, no unintended network destination, no
recoverable launch `fatalError`, no false durable success, and every supported
old-store fixture migrates.

## How this track was sequenced

The original plan phased the work as: (1) baseline and seams — operation IDs,
a safe event vocabulary, injectable clock/filesystem/store/network/sink
adapters, and a fault-matrix harness, so every later claim would be
reproducible; (2) small P0 containment — fail closed on invalid endpoints,
latch audio write failures, stop auto-deleting unmatched originals, detect
authoritative JSON decode failures, make Keychain status visible; (3)
durability core — versioned store migration/bootstrap, protected backups,
provisional capture rows, the operation journal/trash/quarantine, throwing
commit boundaries; (4) resume correctness — version and fingerprint
checkpoints, gate the next chunk on a durable checkpoint write, validate final
output, bound automatic retries; (5) visible degradation and recovery —
persist stage reports, actionable error UI/health surfaces, previous-artifact
preservation and repair actions; (6) network lifecycle — foreground-only
traffic with a unified destination/retry/cost policy; (7) external and
concurrency hardening — a resource scheduler, non-cooperative cancellation
truth, a shared Watch protocol, command acknowledgements, Activity/intent race
handling; (8) a continuous release gate — split CI signals, retained failure
artifacts, migrations/faults/sanitizers/repetition, and a scorecard alongside
the existing accuracy history. All eight phases are complete except H1's and
H6's release-gate items named in the "Status" table above; carry that release
work in parallel with any next code work rather than letting it block new
features.

P0 containment and durability take precedence over new features that widen the
same surfaces (capture entry points, import, provider work, or filesystem
mutation). Independent feature work may continue, but it does not redefine
these failure contracts.

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

## How to resume

1. Read the "Status" table above.
2. Every track is done except what its "Remaining" column names: H1's
   physical-device release matrix, H4's item 3 (deliberately deferred), H6's
   named follow-ups, H7's whisper.cpp revision pin (blocked on network access
   to HuggingFace in the environments this track was authored in), and H9's
   items 2 and 4.
3. Keep the physical H1 matrix as a release gate; it does not block later work.
4. Create the next branch from updated `main` and implement only the next open
   item.
5. Every new durability/state transition must land with deterministic fault
   injection in the same PR.
6. Update this document only after observed verification.
7. Two standing operational notes from this track's history: the deleted
   source branch `devin/resilience-h1-capture-lifecycle` (H1's original
   branch) must not be recreated or stacked on, and the Xcode-generated
   `Kurn.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
   is unrelated to this track and must not be included without a separate
   dependency-pinning review.

## Completed H1 boundary

PR #153 (commit `458a502`) shipped the code contract now documented in
CLAUDE.md's "Audio storage format" section: `RecordingCaptureState`
(preparing/recording/finalizing/ready/recoveryNeeded) with stable recovery
reasons; a `Recording` row committed before `AudioRecorderService` opens the
output file; `RecordingLifecycleSaving` for fault-injectable provisional/final
SwiftData commits; and `RecordingFileFinalizer` as the single production
definition of "ready" (non-empty readable file, measured duration/size,
`.completeUnlessOpen` applied and verified). Sink, stall, validation, and
persistence failures preserve useful bytes as an explicit recovery artifact;
launch/foreground recovery reconciles interrupted rows through the same
finalizer; playback, transcription, export/share, compaction, and enhancement
all reject non-ready rows.

Local verification (no physical-device access in the authoring environment):
738 simulator tests passed, zero failed, six intentional skips; SwiftLint
clean; KurnCore 83 passed; localization key parity and `git diff --check`
passed. The one remaining gap is the physical-device release matrix (Data
Protection, interruption, background expiration, low storage) — see
`docs/release-physical-checklist.md`.

## Execution log: PR boundaries

### Phase A — P0 durability core

#### PR 1 — H1 provisional ownership and truthful finalization

Status: merged as [PR #153](https://github.com/carlosmazzei/Kurn/pull/153)
(`458a502`). See "Completed H1 boundary" above for the shipped contract; the
physical matrix remains a release gate.

#### PR 2 — H2 versioned-schema baseline

Status: merged as [PR #155](https://github.com/carlosmazzei/Kurn/pull/155)
(`a14fab3`), after a `Tag`-name-collision compile fix (Swift Testing's own
`Tag` type vs. Kurn's `Tag` model).

Shipped: `KurnSchemaV1`/`KurnSchemaMigrationPlan`/`KurnModelGraph`
(`Kurn/Infrastructure/KurnSchema.swift`) centralize the SwiftData model graph
and declare it as the app's first `VersionedSchema` with an explicit
`SchemaMigrationPlan`; `ModelContainerBootstrap`, `KurnApp`, and
`TestModelContainer` all read schema/version from there instead of each
declaring their own. `KurnTests/LegacyStoreAdoptionTests.swift` proves an
existing unversioned production store adopts cleanly — generated at run time
rather than committed, since no app version before this PR ever declared a
schema version and there is no earlier released layout to fabricate as a
fixture.

#### PR 3 — H2 recoverable bootstrap state machine

Status: merged as [PR #157](https://github.com/carlosmazzei/Kurn/pull/157)
(`12850ae`), CI green on the first push.

Shipped: `ModelStoreBootCoordinator` replaces `KurnApp`'s production
`fatalError` with four states (`waitingForProtectedData`/`opening`/`ready`/
`recoveryRequired`); `ModelStoreOpenFailureClassifier` classifies a thrown
error into a stable reason; `ModelStoreRecoveryView`/
`ModelStoreLaunchProgressView` render store-independent recovery/waiting
shells; `TranscriptionScheduler`'s background-task registration now runs
before the store is ever opened. Item 6 from the roadmap's H2 plan (store/file
protection verification as part of bootstrap) was deliberately left to PR 4.
Known gap: the classifier's NSError mappings are unverified against a real
device failure, and PR 3's own UI tests are a Debug-configuration launch, not
a true Release-configuration device run.

#### PR 4 — H2 protected backup, restore, salvage, and recovery UI

Status: merged as [PR #158](https://github.com/carlosmazzei/Kurn/pull/158)
(`e46ded2`).

Shipped: `ModelStoreBackupManager` backs up the live store (plus WAL/SHM)
before every open attempt, rate-limited to once per app version+build,
retaining 3 protected generations with schema/app metadata; `ModelStoreSalvage`
attempts a read-only recovery against an isolated copy (production schema
first, then a bare unversioned schema), exporting to Markdown on success;
`ModelStoreProtection.applyAndVerify` checks store/sidecar protection during
bootstrap, routing to `.recoveryRequired(.protectionVerificationFailed)` on
failure; `ModelStoreRecoveryViewModel`/`ModelStoreRecoveryView` wire
retry/restore/salvage/confirmed-fresh-start (fresh start reachable only via a
double-confirmed dialog). A real use-after-free was found and fixed during
this PR's CI rounds: `ModelStoreSalvage.openReadOnly` fetched `[Meeting]` from
a locally-scoped `ModelContainer` and returned the model objects after the
container deallocated — SwiftData resets a deallocated container's
`mainContext`, destroying every instance registered in it, so the caller's
first property read on those already-dead objects crashed the process. This
would have crashed real users on the recovery screen — the one screen that
exists because something already went wrong. The fix (`recoverReadOnly`) does
the fetch *and* the Markdown export inside the container's lifetime, wrapped
in `withExtendedLifetime`, and returns only value types; the rule worth
carrying forward is **never let a `@Model` instance outlive the
`ModelContainer` it was fetched from**. Known gap: salvage is best-effort — it
recovers data from a transient/environmental failure or a migration-plan
bookkeeping issue, but a genuinely corrupt SQLite file or a real
un-migratable schema mismatch fails salvage exactly as it failed live.

#### PR 5 — H3 fail-closed protected storage and quarantine

Status: merged as [PR #162](https://github.com/carlosmazzei/Kurn/pull/162)
(`fd4b417`).

Shipped: recording-directory creation/verification is now throwing, removing
the unverified fallback path for writers; `RecordingQuarantine` moves
unmatched, malformed, unreadable, and collision-ambiguous originals to
protected quarantine (never deletes them), persisting size/date/reason
metadata with recover/export/confirmed-delete in Storage Settings; derived
copies stay separately disposable.

#### PR 6 — H3 durable mutation journal and protected trash

Status: merged into `main` as commit `d7e3dee`.

Shipped: `RecordingOperationJournal` records intent → trashed → committed for
every destructive file operation and replays or rolls back unfinished
operations on launch/foreground (ahead of the heuristic trash sweep, which now
only handles pre-journal leftovers); meeting/recording deletion and the
compaction/replacement boundary both go through it; "Delete All Data" reports
residual audio files instead of implying a clean wipe.

#### PR 7 — H3 versioned authoritative JSON envelopes

Status: merged into `main` as commit `e7a156a`.

Shipped: extends `JSONStorage`'s versioned envelope (encode/decode with typed
`.corrupted`-vs-`.empty` outcomes, established for transcript/summary JSON) to
the transcription checkpoint — `Recording.transcriptionCheckpoint` writes an
authoritative envelope, legacy bare payloads still decode, and a corrupted
checkpoint is an explicit non-resumable state instead of reading as "never
checkpointed." Operation reports (H5) adopt the same envelope once introduced.

This closes the full H3 track scope.

#### PR 8 — H4 pipeline fingerprint and checkpoint validation

Status: merged as [PR #165](https://github.com/carlosmazzei/Kurn/pull/165)
(`08a0192`), after a CI-caught duration-rounding bug fix (a value set after
construction stored the raw unrounded duration; fixed by moving the rounding
into `==`).

Shipped: `TranscriptionPipelineFingerprint`
(`Kurn/Models/TranscriptionPipelineFingerprint.swift`) and
`Infrastructure/PipelineDigest.swift` fingerprint source size/duration/content
digest, effective preprocessing/VAD, language, the exact ASR provider+model,
a compaction-map digest, and — via
`ChunkedTranscriptionRunner.Progress.planDigest` — the exact chunk-plan
identity, strictly tighter than the old "same chunk count" check.
`TranscriptionCheckpoint.isStructurallyValid` bounds-checks span
finiteness/order/duration before a resume or the recovery sweep trusts a
checkpoint. A pre-PR-8 in-flight checkpoint deliberately fails to decode under
the new shape and is treated as `.corrupted` (manual retry), never a false
match — a one-time compatibility break affecting only a device transcribing at
the exact moment it updates across this change.

#### PR 9 — H4 throwing chunk commits and bounded operation states

Status: merged as [PR #166](https://github.com/carlosmazzei/Kurn/pull/166)
(`4efe374`).

Shipped: `ChunkedTranscriptionRunner`'s chunk-completion callback is now
`async throws` and awaited before the next chunk starts, so a checkpoint-save
failure stops the run at the last durably-committed chunk instead of
continuing past an undurable one; `Recording.automaticResumeAttempts` bounds
unattended automatic resume attempts (default 3, via
`admitAutomaticResume`) — an exhausted row is marked `.failed` with its
checkpoint intact rather than retried forever, and every manual retry resets
the budget. Known gap: item 3 (the full explicit operation-state enum —
queued/running/paused/deferred/retryScheduled/permanentFailure with reason
codes and `nextAttemptAt`) was not built; the simpler counter on top of the
existing `TranscriptionStatus` enum was judged sufficient, revisit only if a
concrete richer-UI need appears (e.g. a "retrying in 2 minutes" display).

#### PR 10 — H4 expensive generated-artifact operation state

Status: merged as [PR #167](https://github.com/carlosmazzei/Kurn/pull/167)
(`663ab09`).

Shipped: `SummaryMapCheckpoint`/`SummaryMapRunner` extend PR 9's
gated-durable-progress contract to the map stage of staged summary and wiki
generation, sharing one `Meeting.summaryMapCheckpointData` field since both
artifacts condense byte-identical notes for the same meeting content via
`SummaryService`'s `notesTemplate`. Deliberately excluded:
`DocumentGenerationService`, which spans multiple meetings and has no single
`Meeting` to checkpoint against. Known gaps: no end-to-end test exercises
`generateSummary`/`WikiCoordinator.generate` resuming against a real (mocked)
`LLMProvider` — the loop itself is proven in isolation
(`SummaryMapRunnerTests`); the narrow concurrent Summary+Wiki race on one
meeting is reasoned about (both run on the same `@MainActor`, so no torn
write is possible), not tested.

**H4's plan is otherwise closed except item 3**, deliberately deferred per PR
9's own handoff.

### Phase B — Visible degradation and integrity

#### PR 11 — H5 typed stage outcomes and pipeline report

Status: merged as [PR #168](https://github.com/carlosmazzei/Kurn/pull/168)
(`d9f5120`).

Shipped: `PipelineReport`/`PipelineStageReport`/`PipelineStageOutcome`/
`PipelineStageReason` (KurnCore, pure/`Sendable`, closed-vocabulary — no
free-text or `underlyingError` field, since the report is a diagnostics-export
candidate) give every stage a requested/effective engine and a
succeeded/degraded/skipped/failed outcome with a stable reason;
`TranscriptionService` builds one report per run across preprocessing,
language detection, VAD, compaction, transcription, diarization, and
correction; `Transcript.pipelineReportData` persists the aggregate in the same
save as the segments — optional, `nil` meaning *unknown*, never *clean*.
Surfacing this in the UI is PR 13's job; nothing read it yet at this point.

#### PR 12 — H5 final integrity gate and atomic artifact replacement

Status: merged as [PR #169](https://github.com/carlosmazzei/Kurn/pull/169)
(`e3c1c54`), CI green on the first push.

Shipped: `TranscriptIntegrityGate` (KurnCore, pure) validates a fused/corrected
result before `TranscriptionService.transcribe` ever returns it — source
readability, span bounds/order (mirroring
`TranscriptionCheckpoint.isStructurallyValid`'s existing 30s-slack tolerance),
non-blank text/speaker attribution, and (for a `TranscriptCorrecting`
conformer) exact segment-identity preservation. A violation throws
`AppError.transcriptIntegrityFailed` instead of reaching
`TranscriptionViewModel.saveTranscript`, so a structurally broken result can
never replace an existing transcript; a corrector that violates its contract
has its output discarded in favor of the pre-correction segments and recorded
as `.degraded` rather than corrupting or failing the run. Summary and the
semantic index already satisfied "keep the previous artifact until the
replacement is valid and durable" before this PR (neither ever deletes before
the new content is ready) and needed no change. Known gap: no end-to-end test
forces `TranscriptionService.transcribe` to actually throw this — the gate
itself is proven in isolation, but neither `TranscriptionService` nor the view
model is behind an injectable seam for a real pipeline run.

#### PR 13 — H5 stage-specific recovery actions

Status: merged as [PR #170](https://github.com/carlosmazzei/Kurn/pull/170)
(`b5d2233`), CI green on the first push.

Shipped: `MeetingDetailView`'s Transcript tab renders a one-line "completed
with warnings" banner from the stored `PipelineReport`, naming every warning's
stage. Correction — the one stage cheap enough to retry without repeating
audio/ASR/diarization — gets its own retry action
(`TranscriptionViewModel.retryCorrection`), re-validated through the same
integrity gate and guarded by a stale-write check against a concurrent full
re-transcribe; every other warning falls back to the existing full
re-transcribe confirmation. **H5's plan is now fully addressed.** Known gap:
the banner shows one combined sentence, not a per-stage reason — a deliberate
scope cut against the translation cost of eleven per-reason phrases across
seven languages.

### Phase C — Credentials and models

#### PR 14 — H7 typed Keychain and explicit credential save

Status: merged as [PR #171](https://github.com/carlosmazzei/Kurn/pull/171)
(`de8b551`, plus a follow-up CI fix serializing a real-Keychain test race).

Shipped: `KeychainAccessing` (mirroring `CloudSettingsSync`'s seam) replaces
raw `OSStatus` handling with `KeychainReadOutcome`/`KeychainWriteOutcome`/
`KeychainFailureReason` (locked/denied/transient) so a locked device is no
longer indistinguishable from "key never stored";
`migrateToBackgroundAccessible()` now only marks itself complete after a
confirmed outcome, closing the bug where a locked device at first launch
looked identical to "nothing to migrate" and silently never migrated again;
provider credential edits in `ProviderEditor` commit only on explicit Save
after URL validation, instead of writing to the Keychain on every keystroke.
Known gaps: no locked-device migration test (the simulator can't simulate a
locked Keychain, the same limitation H1's physical matrix names for Data
Protection); no end-to-end UI test for the Keychain-failure alert path.

#### PR 15 — H7 verified model staging, resume, and replacement

Status: merged as [PR #172](https://github.com/carlosmazzei/Kurn/pull/172)
(`d66c10f`), after two CI-caught fixes (a missing `KurnCore` import, then
isolating the new test suite's network double from a cross-suite race).

Shipped: `ModelDownloading` (new injectable actor protocol) unifies the
whisper.cpp and sherpa-onnx downloaders, replacing a bare static-function API
that trusted a download at a loose size floor and installed by delete-then-move
(a crash between the two steps left no model installed at all). Verification
now checks the exact declared `Content-Length` and, when the origin volunteers
one (HuggingFace's `X-Linked-ETag`), SHA-256; install is atomic via
`FileManager.replaceItemAt` with backup-and-restore on a post-install
re-verification failure; resume data (in-memory only) survives a
cancelled/interrupted transfer; every download row gets a working Cancel
action. Known gap, stated by the PR itself: **immutable revision pinning for
whisper.cpp is not done** — the authoring environment had no network path to
HuggingFace to obtain a real commit SHA to pin against, and a wrong or stale
hardcoded one would fail every future download outright (sherpa-onnx's two
models were already pinned before this PR). Resume data also does not survive
a relaunch, only a backgrounding; there is no automatic retry-with-backoff.

#### PR 16 — H7 model inventory and health probes

Status: merged as [PR #173](https://github.com/carlosmazzei/Kurn/pull/173)
(`060276b`), CI green on the first push.

Shipped: `ModelVerification` persists a third fact per model —
`.unverified`/`.verified(Date)`/`.corrupt(reason:)` — distinct from consent and
from bytes-on-disk. whisper.cpp and sherpa-onnx each get a real post-install
health probe (calling their own already-failable initializers once, deleting
and failing the download on a bad file); the four FluidAudio-backed sets get
the same fact for free, since downloading them already fully loads the model.
`ModelStore.installedModels()` compares installed size against last-verified
size to flag drift as corruption and quietly re-applies backup exclusion if
unset; Settings → Storage shows a checkmark/warning per row, with the existing
delete action serving as "offer redownload." **H7's plan is now fully
addressed except pinning whisper.cpp's revision** (same network-access gap PR
15 stated — neither PR closes it). Known gap: retroactive verification of
models installed before this PR is out of scope — they stay `.unverified`
until their next re-download, not probed automatically at launch (which would
mean unconditional CoreML/ANE compilation for the FluidAudio-backed groups).

### Phase D — Ownership, resources, and integrations

#### PR 17 — H8 resource cooldown and global admission scheduler

Status: merged as [PR #174](https://github.com/carlosmazzei/Kurn/pull/174)
(`283d330`, plus two follow-up CI fixes).

Shipped: `MemoryPressureState` replaces a sticky memory-warning boolean (set
once on the first `didReceiveMemoryWarningNotification`, never cleared) with
an observed-at/cooldown(60s)/recheck model, plus a live (non-latched) thermal
state check. `ResourceScheduler` (new global actor, shared weight budget of
100) admits preprocessing/transcription/diarization/enhancement/model-loading
at their existing funnel points, so two different recordings' heavy stages can
no longer both pass an independent preflight and hold memory at once — the
gap `TranscriptionService`'s existing sequential/concurrent engine branch
never covered. Known gap: the weight table and cooldown/thermal thresholds
are first-cut estimates, not measurements against real device behavior.

#### PR 18 — H8 cancellation truth and bridge audit

Status: merged as [PR #175](https://github.com/carlosmazzei/Kurn/pull/175)
(`3b31bf7`, plus two follow-up CI fixes).

Shipped: a full audit of every `@unchecked Sendable` (20 sites),
`nonisolated(unsafe)` (12 sites), and continuation/callback bridge (11 sites)
in `Kurn`/`KurnCore`. Found and fixed: two "false timeouts"
(`SherpaOnnxDiarizer`, `FluidAudioVAD` — a `TaskGroup` can't return until every
child finishes, so racing a sleeping timer against a call neither engine can
abort never actually bounded time, it just discarded a valid slow result for a
fabricated error); a leaked continuation (`RecorderViewModel`'s mic picker,
now resolved-then-replaced instead of silently overwritten); and an
unsynchronized mutable property (`CloudSettingsSync.didChangeExternally`, now
lock-guarded). One `nonisolated(unsafe)` annotation
(`LockScreenRecordingController.activity`) was checked, found necessary for a
different reason than its own comment gave (Swift 6's "sending" check on a
`nonisolated` ActivityKit API, not a real data race), and kept with a
corrected comment. Known gaps: no Thread Sanitizer configuration exists in the
project yet (added in PR 25); a few other patterns (duplicated logging-handler
globals, `SherpaOnnxOfflineSpeakerDiarizationWrapper`'s single-owner contract,
`AudioRecorderService.onAudioBuffer`) were reviewed and left as-is — benign
today, unenforced; `FoundationModelsProvider`'s timeout behavior couldn't be
verified either way (closed-source Apple framework).

#### PR 19 — H8 ActivityKit authoritative lifecycle

Status: merged as [PR #176](https://github.com/carlosmazzei/Kurn/pull/176)
(`5dd71c8`), CI green on the first push.

Shipped: a `runID` generation counter, bumped by both `start()` and `end()`,
closes a race where an untracked `start()` task could still create a Live
Activity after a same-instant `end()` had already run and decided there was
nothing to end — an orphan nothing would ever end, left on the Lock
Screen/Dynamic Island until the system eventually evicted it. Known gap: no
automated test proves the race is closed — ActivityKit has no protocol seam to
fake, and Swift's concurrency runtime provides no supported way to force two
independently-created tasks' scheduling order; verified by code review and CI
passing the existing suite, not by a race-specific test.

#### PR 20 — H8 shared Watch protocol and idempotent external commands

Status: merged as [PR #177](https://github.com/carlosmazzei/Kurn/pull/177)
(`7d15192`, plus one follow-up CI fix).

Shipped: `WatchCommand`/`WatchSessionKey` now compile from one file shared
into both the `Kurn` and `KurnWatch` targets (previously two
independently-typed copies), the same dual-target-membership pattern
`RecordingActivityAttributes.swift` already established. Watch commands carry
a `commandID` the phone deduplicates against (caching the last 20 outcomes), a
10s local timeout, and a three-phase `WatchAckPhase` reply
(received/stateChanged/finalized); the phone reconciles a stale "recording"
application-context on every `WCSession` reactivation, since a live session
never survives process termination; `StartRecordingIntent` now awaits an
actual acceptance reply (bounded 3s timeout) instead of claiming success
unconditionally, closing a cold-launch race where an unconfigured
`RecordingLauncher` silently swallowed the request. Item 1 (general operation
ownership) was audited against its own named examples: `MeetingChatViewModel`'s
reply `Task` didn't cancel on view dismissal, fixed with a `deinit`.
**H8's plan is now fully addressed.** Known gap: the Watch-side timeout,
reconnect reconciliation, and intent acceptance wait have no automated test
coverage — `KurnWatchUITests` doesn't run in CI, and real `WCSession` traffic
isn't reproducible deterministically.

### Phase E — Actionable recovery and diagnostics

#### PR 21 — H9 structured errors and per-operation queues

Status: merged as [PR #178](https://github.com/carlosmazzei/Kurn/pull/178)
(`674687c`), CI green on the first push.

Shipped: `AppErrorMetadata` (KurnCore) adds `category` (11 cases),
`severity`, `isRetryable`, `recoveryAction`, and a private-only `privateContext`
to every `AppError` case. `TranscriptionViewModel.errorsByRecording`
(`[UUID: AppError]`, keyed like the existing `diarizationWarnings`) replaces
the single shared `error` property that let one recording's transcription
failure clobber or misattribute another's, since the view model is a single
app-wide shared instance. Cancellation was audited across the app's four
biggest cancellable flows and confirmed already silent everywhere — no fix
needed. Known gaps: item 2 (contextual recovery-action UI reading
`recoveryAction`) is not built — the data exists, no UI reads it yet;
`persist()` and the AI-title-generation path are still not recording-scoped;
item 4 (optimistic-UI rollback) not attempted.

#### PR 22 — H9 bounded encrypted events and redacted export

Status: merged as [PR #179](https://github.com/carlosmazzei/Kurn/pull/179)
(`0765891`), CI green on the first push.

Shipped: `ReliabilityEventStore` gives the pre-existing content-free
`ReliabilityEvent` vocabulary a bounded (500 events, pruned in batches),
protected, on-device JSON-Lines buffer under `Application Support/
ReliabilityEvents/`. `TranscriptionViewModel.transcribe` — the app's single
most important resilience path — gets its own correlated instrumentation (one
`OperationID` per attempt). The four sites logging an `AppError`'s raw
`errorDescription` at `.public` now log `logCode`/`privateContext` instead.
`ReliabilityEventsListView` (Settings → Diagnostics) lists and shares recent
events — already the redaction preview item 6 asks for, since every field is
content-free by construction. Known gaps: a short reference ID surfacing in
both the UI error dialog and the events list is not built (`errorAlert`'s
shared binding has no per-occurrence context to attach one to — deferred to
PR 23); the broader ~46-site non-`AppError` raw-log sweep found by the audit
is unaudited; `ReliabilityEvent` adoption covers only two operations (document
generation, transcription), not every resilience path.

#### PR 23 — H9 health and recovery center

Status: merged as [PR #180](https://github.com/carlosmazzei/Kurn/pull/180)
(`9511f32`), CI green on the first push.

Shipped: `HealthRecoveryView` (Settings → Health & Recovery) aggregates six
conditions already tracked individually elsewhere — pending capture recovery,
quarantined audio, degraded transcripts, failed/deferred transcription jobs,
corrupt on-device models, recent reliability failure codes — behind one
screen, dispatching every action to the exact same recovery function its
existing per-item UI already calls, so there is no second implementation of
any recovery behavior to keep in sync. **This closes out H9's plan except
items 2 and 4** (contextual recovery-action UI, optimistic-UI rollback),
deliberately deferred as known gaps in PR 21. Known gap: the reference-ID work
PR 22 deferred here is still not built — it would need widening `errorAlert`'s
shared binding at 19+ call sites, its own design pass.

### Phase F — Continuous verification

H10 is implemented inside every prior PR: a new transition without its
scripted failure and post-relaunch assertion is incomplete.

#### PR 24 — H10 split CI signals, retained artifacts, and static policy

Status: merged as [PR #181](https://github.com/carlosmazzei/Kurn/pull/181)
(`6189f1a`); all five jobs passed on the first push, confirmed by reading the
actual job logs rather than the pass/fail summary alone.

Shipped: `.github/workflows/swift.yml`'s single `build-and-test` job is now
five parallel jobs (`lint-and-validate`/`static-policy`/`unit-tests`/
`ui-accessibility-tests`/`kurncore-linux`), each reporting separately, with
`.xcresult` and simulator-log retention on failure. `Tools/check_static_policy.py`
(new, `static-policy` job, Linux) is a narrow text scanner covering four
patterns where a textual match is reliable signal: production `fatalError`,
`try? <context>.save()`, an ad hoc `URLSession` outside the app's three
sanctioned transport seams, and a raw error description logged at `.public`;
findings are fixed, baselined (`Tools/static_policy_baseline.txt`, keyed by
line content), or given an inline allow-list comment. Two of the plan's five
static-policy categories (unowned long-lived tasks; durability-boundary
`try?` beyond `ModelContext.save()`) stay manual-audit items rather than a
text scan — telling a real leak apart from a correct process-lifetime
singleton needs type-lifecycle judgment a pattern match can't make. Known gap:
no build-once/test-many optimization across the three macOS jobs (each runs
its own full `clean` build).

#### PR 25 — H10 scheduled/release hardening and scorecard

Status: merged as [PR #182](https://github.com/carlosmazzei/Kurn/pull/182)
(`dd4526a`); all five `iOS CI` jobs passed on the first push, confirmed by
reading the job logs.

Shipped: `.github/workflows/reliability-hardening.yml` (new, weekly +
on-demand) adds a Thread Sanitizer run over the concurrency-sensitive suites
(two independent matrix attempts), a Release-configuration test run, and five
repeated UI/accessibility attempts summarized as an actual passed/total flake
rate with no invented threshold — the same "a maintainer reads and records a
run by hand" philosophy `docs/pipeline-evaluation.md` already established for
accuracy, applied to reliability. `docs/release-physical-checklist.md` (new)
converts the "Release-only physical matrix" below into an actual checkbox
list, referenced from both the `beta` and `submit` jobs in `swift.yml`.
Codecov coverage reporting was added across `unit-tests`/
`ui-accessibility-tests`/`kurncore-linux`, informational-only per
`codecov.yml`. **This closes out H10's plan and the original 25-PR
sequence**, except items 1–2 (the fault-injection protocols/matrix stay
threaded through prior PRs' own fakes — `ClockProviding`,
`ReliabilityEventStore`, `ModelDownloading`, and the rest — rather than
landing as one PR that introduces them from scratch). Known gap, since
resolved: the initial Codecov/lcov export needed a follow-up fix (`xccov`'s
JSON report isn't a type Codecov accepts, and `llvm-cov` wasn't on the Linux
runner's `PATH`) — both macOS jobs now read the `.xcresult` coverage archive
via `Tools/xccov_to_lcov.py` and emit lcov, and the Linux job resolves
`llvm-cov` next to the `swift` binary.

#### Post-megaplan hardening review (PR #185)

Status: merged as [PR #185](https://github.com/carlosmazzei/Kurn/pull/185).

A full re-read of H1–H10 against the code, after the original 25-PR sequence
closed, found four P1 gaps and fixed them in one PR: `ModelStoreBootCoordinator`
no longer falls back to `temporaryDirectory` when Application Support is
unavailable, entering `.recoveryRequired(.applicationSupportUnavailable)`
instead (hiding the restore/salvage/fresh-start actions, which presuppose a
durable directory); `JSONStorage` distinguishes an envelope written by a newer
app version (`.unsupportedVersion`, original bytes preserved) from actual
corruption; `RecordingOperationJournal.advance` reports a failed rewrite
instead of ignoring it and moves unreadable records to `Journal/Unreadable`
rather than dropping them; reliability events now cover capture sink failures
and finalization (`CaptureReliability`), store boot, journal replay,
recovery/quarantine, model downloads, and circuit-breaker transitions — not
only transcription and documents. `withResourceReservation` replaces the
`defer { Task { release } }` pattern at every `ResourceScheduler` call site so
a reservation releases in the same async flow on success, throw, and
cancellation, and weights above budget are clamped instead of waiting
forever. `Error.publicLogCode` replaced every remaining
`localizedDescription`-at-`.public` log line, taking the static-policy
baseline's `raw-public-error` and `unchecked-save` entries to zero;
`check_static_policy.py` now fails when a baseline entry no longer matches any
code. The Thread Sanitizer lane gained the capture-ownership, sink-fault,
journal, circuit-breaker, event-store, and downloader suites.

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
- Update the H10 fault matrix and this document after the result is observed.

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
