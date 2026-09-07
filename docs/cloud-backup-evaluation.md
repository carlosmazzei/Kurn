# Evaluation: cloud backup for meetings, without a Kurn-owned service

This is a design evaluation, not an implementation record. No production code
changes accompany it. It exists to answer one question precisely: what would
it take to let a user back up their meetings to "the cloud" without Kurn
running any server, database, or account of its own — and does that square
with the invariants in `docs/roadmap.md`.

## 1. The problem and why today's export doesn't solve it

Kurn is local-first: nothing leaves the device unless the user opts into cloud
transcription or a cloud summary provider (invariant **I1**, `docs/roadmap.md`).
That is also exactly why there is no answer today to "my phone was lost/
replaced — where are my meetings." The nearest existing feature is
`MeetingExport` (`Kurn/Infrastructure/MeetingExport.swift`), which renders one
meeting's transcript/summary to Markdown (optionally Obsidian-flavored) and
hands it to the system share sheet via `Views/ActivityView.swift`. A user can
already save that Markdown into iCloud Drive/Files manually, but it is:

- one meeting at a time, never the whole library;
- text only — no audio, no highlights, no speaker voiceprints;
- one-way — there is no "restore this into a fresh install" path.

A cloud backup feature is a distinct capability from export: it needs to be
whole-library, include audio, and be round-trippable.

## 2. Constraints inherited from the existing design

Two invariants from `docs/roadmap.md` bound this evaluation directly:

- **I1** — "Nothing leaves the device without an explicit request." A backup
  feature is squarely a feature that "merely moves data off-device"; per the
  roadmap's own corollary, that still needs consent even with no LLM involved
  — the same reasoning that keeps `templatesSyncEnabled` off by default.
- **I2** — "Meeting-derived content lives in the encrypted store." Today that
  is enforced by `ModelStoreProtection`'s `.completeUnlessOpen` on the SwiftData
  store; the rule as stated in `CLAUDE.md` is "never write vectors,
  transcript-derived text, or chat content to a loose file, a cache directory,
  or `UserDefaults`." A cloud backup file is, structurally, exactly that kind
  of loose file — so it is the one deliberate, documented exception, and it
  only stays consistent with I2 if it carries its own encryption strong enough
  to substitute for `.completeUnlessOpen` while it's outside the store.

And one prior decision bounds the *mechanism*: **R1 · CloudKit content sync**
(`docs/roadmap.md:315-321`) already rejected syncing transcripts via CloudKit
outright, because CloudKit's private database, while encrypted in transit and
at rest, is not end-to-end encrypted the way `.completeUnlessOpen` is — those
records "can be served under legal process." `CloudSettingsSync`
(`Kurn/Infrastructure/CloudSettingsSync.swift`) is cited there as the correct
precedent specifically because it is scoped to non-secret preferences via
iCloud key-value, "deliberately not the SwiftData container."

This evaluation does not overturn R1. It proposes a mechanism that satisfies
R1's actual concern (Apple/legal-process visibility into meeting content)
while still using the user's own iCloud account rather than a Kurn-run
backend.

## 3. Proposed mechanism: a dedicated iCloud Drive container, encrypted client-side

Rather than CloudKit's private database, use a dedicated **iCloud Drive
ubiquity container** — an app-owned folder inside the user's iCloud Drive,
addressed via `FileManager.url(forUbiquityContainerIdentifier:)`. This is
still "iCloud," still entirely the user's own account and storage quota, and
still requires no Kurn-operated server — but it is a plain file store, not a
CloudKit record database, so the app fully controls what bytes land in it.

The decisive move that answers R1's objection: **every file written to the
container is encrypted on-device before it is written**, with a key the app
never uploads anywhere. Apple's infrastructure — and by extension any legal
process against Apple — sees only opaque ciphertext, which is a materially
different position than CloudKit's private database (encrypted, but not from
Apple itself). This is not a smaller version of what R1 rejected; it removes
the specific property R1 objected to.

Concretely, per meeting:

- A package at `CloudBackup/{meetingID}.kurnbackup` inside the ubiquity
  container, holding:
  - a JSON manifest (title, dates, a content hash, and a schema version — the
    same pattern `WikiArticle` already uses via `sourceContentHash`/
    `generatorModelIdentifier` to detect staleness);
  - the sections the user has enabled (see §4) — transcript `segmentsData`,
    summary `sectionsData`, highlights, wiki article, meeting/recording/
    speaker metadata;
  - the original `.m4a` file(s), read the same way every other consumer
    reads them — through `Recording.fileURL` / `AudioFileStore.resolveURL`,
    never by reconstructing a path.
- The whole package is AES-GCM encrypted before it touches the container. The
  key is either derived from a user-chosen passphrase (PBKDF2/Argon2) or
  generated randomly and held only in the local Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, the same class
  `KeychainManager` already uses for API keys) — never written into the
  backup package itself, never synced anywhere.
- Restoring on a second device requires the same key/passphrase. This is a
  real, user-facing trade-off worth stating plainly: **there is no "forgot my
  password" recovery**, because there is no server to hold a reset flow. A
  lost key means an unreadable backup. The UI must say this in the consent
  step, not bury it in a settings footnote.

`SemanticChunk` (the on-device search index) and `summaryMapCheckpointData`
(a transient generation-resume artifact) are deliberately excluded from the
backup payload — both are regenerable from the transcript/summary already
included, and including them would only inflate the package for no
restorability benefit.

## 4. Per-artifact selection, and folding templates sync into it

Rather than one `cloudBackupEnabled` switch that backs up everything or
nothing, the user should choose *which* artifact types leave the device. This
matters concretely: audio dominates payload size (tens of MB per hour) while
transcript/summary/metadata JSON is kilobytes — a user on a constrained iCloud
plan may want text-only backup, or none of the audio, or the reverse.

This also creates a natural point to fix an existing UX inconsistency:
`templatesSyncEnabled` (`AppSettings.swift`) already syncs data — custom
summary templates — via `CloudSettingsSync`/`TemplateSyncMerger`, but today it
lives as an isolated toggle buried inside another settings screen, with no
visible relationship to "things that leave this device via iCloud." Once a
second iCloud-based sync mechanism exists, having two unrelated "sync to
iCloud" toggles in two different screens would be confusing rather than
additive.

The proposed UI is a single new **Sync** row in the `SettingsView` hub
(alongside Intelligence/Capture/Library/System, the grouping style already
used there), opening one screen — `Views/Settings/SyncSettingsView.swift`, in
the shape of `StorageSettingsView.swift` — that lists every artifact type that
can leave the device via iCloud, each its own toggle:

| Toggle                    | Controls                                     | Notes |
| -------------------------- | --------------------------------------------- | ----- |
| `syncTemplatesEnabled`     | Custom summary templates via `CloudSettingsSync` | This **is** today's `templatesSyncEnabled`, relocated to live next to the others rather than isolated. `CloudSettingsSync`/`TemplateSyncMerger` logic is unchanged — only the settings surface moves. |
| `syncTranscriptEnabled`    | `Transcript.segmentsData`                     | Small; the main text asset users actually want recoverable. |
| `syncSummariesEnabled`     | `Summary.sectionsData`                        | Small. |
| `syncWikiEnabled`          | `WikiArticle`                                 | Only meaningful when `wikiEnabled` is already on. |
| `syncAudioEnabled`         | The original `.m4a`                           | Dominates size/time; off by default is a reasonable starting point given cost. |

Each flag follows the exact idiom already used throughout `AppSettings` for
opt-in features — a `Bool` with `didSet` persisting to `UserDefaults`, the
same shape as `wikiEnabled`/`correctionEnabled`. A single higher-level
`cloudSyncConsented` flag gates whether the ubiquity container is created/used
at all — mirroring how `diarizationConsented` gates *whether* a model
download can happen, separately from *which* engine is chosen. The
per-artifact toggles above are the fine-grained choice made after that
consent, the same relationship `fluidAudioSpeakerCount` has to
`diarizationConsented`.

The backup package's manifest only includes the sections whose toggle is on;
turning audio off, for instance, produces a metadata+transcript-only package
at a fraction of the size.

## 5. Fit with the rest of the architecture

- **Consent + progress UI**: a new `CloudSyncController`
  (`@Observable @MainActor`), modeled directly on
  `ViewModels/ModelDownloadController.swift` — the same consent-flag →
  `pending*` staged choice → transfer-with-progress → `onSuccess` sets the
  consent flag pattern already used for FluidAudio/whisper.cpp model
  downloads. `SyncSettingsView` would attach a `.cloudSyncAlerts(...)`
  modifier analogous to `.modelDownloadAlerts(...)`.
- **Transfer mechanics**: reuse the shape of `Services/ModelFileDownloader.swift`
  — stage into a temp location, verify (byte count / hash) before committing,
  atomic swap-in via `FileManager.replaceItemAt`, resumable — applied to
  upload instead of download, and to a ubiquity container path instead of an
  HTTPS endpoint. `Infrastructure/LargeTransferPolicy.swift` (Wi-Fi-only
  unless the user allows expensive/constrained transfers) gates it the same
  way it gates model downloads today.
- **Reliability**: failures (upload failed, restore failed, conflict) are
  recorded as `ReliabilityEvent`s (`operation: "cloud_sync"`,
  `stage: "upload"/"restore"/"conflict"`) via `ReliabilityLog.record`, with the
  same content-free contract as the rest of the app — an operation ID and a
  closed-vocabulary code, never a filename, title, or error string.
  `Views/Settings/HealthRecoveryView.swift` is the natural place a failed sync
  would surface for retry.
- **Concurrency**: this is network I/O, not the kind of memory pressure
  `ResourceScheduler`'s `ResourceWorkKind` weights were calibrated against
  (preprocessing/transcription/diarization/enhancement/model loading, each
  sized against jetsam risk). No new `ResourceWorkKind` case looks necessary
  unless in-memory zip/encryption of a large audio file turns out to need its
  own admission control — worth measuring, not assuming, before adding one.
- **Secrets**: a passphrase-derived or random backup key goes through
  `KeychainManager`'s existing dynamic string-account API (the same one
  `AIProvider.keychainAccount` uses), under a new account namespace (e.g.
  `cloudsync.backupKey`) — no new Keychain service, no new storage class
  needed beyond what's already used for API keys.

## 6. What stays true, what's the one exception

- `UIFileSharingEnabled` stays unset — the ubiquity container is a separate
  tree from `Documents/Recordings/`, so raw `.m4a` files are still never
  exposed to Files/Finder outside of it.
- No other cloud-LLM feature (auto-tagging, wiki, correction) is implied or
  auto-enabled by turning sync on — this is purely a storage/transport
  concern, unrelated to any provider call.
- **The one documented exception to I2** is the backup package itself: it is,
  by construction, meeting-derived content living outside the SwiftData
  store. It stays consistent with I2's intent only because it carries its own
  encryption at least as strong as `.completeUnlessOpen`, and only for as long
  as that holds — this is the property future changes to the format must not
  weaken.

## 7. Multi-device conflicts

Two devices editing the same meeting (e.g., renaming it, adding a tag) before
both have synced needs a resolution rule. The simplest consistent choice is
per-meeting last-write-wins by an `updatedAt` timestamp, the same strategy
`TemplateSyncMerger` already uses for templates — including inheriting that
mechanism's known v1 limitation: deletions don't propagate, so a meeting
deleted on one device and not yet synced from another can reappear. That
limitation is already accepted for templates; carrying it into meeting sync
is a reasonable stated trade-off, not a novel gap.

## 8. Alternatives considered and set aside

- **CloudKit private database** — the mechanism R1 already rejected, for the
  legal-process/non-E2E reason above. Not revisited by this proposal.
- **BYO S3/WebDAV credentials** — genuinely provider-neutral, and arguably a
  closer fit for "no proprietary service" since it doesn't depend on Apple
  either. Set aside as the *primary* proposal here because it requires
  building and testing an HTTP client per protocol and a credential-entry UX,
  a materially larger surface than reusing an OS-level ubiquity container.
  Worth registering as a plausible "advanced" mode in a later iteration.
- **`UIDocumentPickerViewController` (pick any Files-integrated destination)**
  — lets the user point at whatever provider they already have in the Files
  app (iCloud Drive, Dropbox, Google Drive, WebDAV, ...) with no new
  entitlement at all. Set aside as the primary proposal because it has no
  OS-level background sync (`NSMetadataQuery`, which the dedicated-container
  approach gets for free) and requires managing security-scoped bookmarks
  across app launches. Worth noting as the lowest-effort way to ship a first,
  manual version of this feature before investing in the dedicated-container
  design above.

## 9. Costs and risks

- **Entitlements**: `Kurn.entitlements` today declares only
  `com.apple.developer.ubiquity-kvstore-identifier` (for `CloudSettingsSync`).
  This proposal needs a new `com.apple.developer.icloud-container-identifiers`
  entry plus `com.apple.developer.icloud-services` = `CloudDocuments`, which
  means updating provisioning profiles in the private `kurn-certificates` repo
  and re-signing — a release-pipeline change, not just an app change.
- **Size and time**: audio dominates payload size; uploading tens of MB per
  hour of meeting over a constrained connection is real latency the UI needs
  to report honestly (progress, not a spinner).
  `Recording.fileSize`/`effectiveBitRate` already give the numbers needed to
  estimate this up front.
  - **Key loss = backup loss**, with no recovery path, by design (no server to
  hold a reset flow). This needs explicit, unambiguous copy in the consent
  flow, not a settings footnote.
- **New test surface**: encryption round-trip, per-artifact package
  composition, conflict resolution, partial/interrupted restore, and behavior
  on a device with iCloud Drive disabled or storage full all need coverage
  before this could ship — none of it exists today since no comparable
  mechanism is in the codebase to reuse test fixtures from.
