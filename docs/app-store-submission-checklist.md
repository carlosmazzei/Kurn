# App Store Submission Checklist

TestFlight (`fastlane beta`) and the App Store are two different things — a
build validated on TestFlight is not automatically submitted anywhere else.
This is what's still needed to take a TestFlight build public, split by who
does it.

## Already automated

- [x] Signing, archiving, and TestFlight upload — `fastlane beta`, runs
      automatically in the `beta` job whenever a `vX.Y.Z` tag is pushed
      (`.github/workflows/swift.yml`).
- [x] Text metadata (description, keywords, subtitle, promotional text,
      release notes, support/marketing/privacy URLs, copyright, category),
      **for all 7 UI locales** (`fastlane/metadata/{en-US,pt-BR,es-ES,fr-FR,
      it,de-DE,zh-Hans}/`) — pushed to App Store Connect automatically by
      the `metadata` job on the same tag push, via `fastlane metadata`. No
      signing needed (text-only), so it runs on `ubuntu-latest`.
- [x] Screenshots — captured by `fastlane screenshots` via the
      `App Store Screenshots` GitHub Actions workflow
      (`workflow_dispatch`), always uploaded as the `screenshots` artifact.
      **English (`en-US`) only for now** — `KurnUITests/ScreenshotUITests.swift`
      already drives navigation purely through `.accessibilityIdentifier`,
      but `Kurn/DebugSupport/ScreenshotSeedData.swift`'s seeded meeting
      titles, transcript lines, and summaries are hardcoded English, so
      adding more `Snapfile` languages today would just localize the chrome
      around still-English content. Translating the seed data is a
      prerequisite, not wired up here.
- [x] Pushing screenshots + text metadata together —
      `fastlane store_assets`. Dispatch `App Store Screenshots` against the
      matching `vX.Y.Z` tag with `upload: true`; leave it `false` to capture
      from any branch without touching App Store Connect. An invalid branch
      upload now fails immediately instead of spending up to 90 minutes
      capturing.
- [x] Static metadata validation — `Tools/validate_store_metadata.py` runs in
      the regular `iOS CI` workflow and checks locale/file completeness, Apple's
      text limits (including the 100-byte keyword limit), and HTTPS URLs before
      a release tag can reach the metadata upload job.
- [x] Attaching an exact processed TestFlight build and submitting it to App
      Review — manually dispatch `App Store Submission`
      (`.github/workflows/app-store-submit.yml`) against its `vX.Y.Z` release
      tag, enter the matching `MARKETING_VERSION` and build number, then
      approve the `release` Environment deployment. The `submit_review` lane
      rejects malformed or mismatched tags/versions and never releases an
      approved version automatically.
- [x] Privacy policy, Terms of Use, EULA, encryption documentation —
      `PRIVACY.md`, `TERMS.md`, `EULA.md`, `ENCRYPTION.md`.
- [x] Export compliance declared in `Info.plist`
      (`ITSAppUsesNonExemptEncryption = false`).

Tag-driven jobs never submit the app for review or change what's publicly
visible. Metadata, screenshot upload, TestFlight upload, and the separately
and explicitly dispatched App Review submission are gated behind the `release`
GitHub Environment, so each App Store Connect mutation can require reviewer
approval. The submission lane sets `automatic_release: false`, leaving the
public release after Apple's approval as a deliberate manual action.

## Manual, in App Store Connect — one-time setup

These are account-level decisions with no fastlane equivalent worth
automating (each is either a one-off judgment call or requires PII/business
information this repo has no business holding):

- [ ] **Pricing and Availability** — free vs. paid, which countries/regions.
- [ ] **App Privacy** ("nutrition label") — data collection questionnaire.
      Per `PRIVACY.md` and the Privacy Manifest, the honest answer is "Data
      Not Collected."
- [ ] **Age Rating** questionnaire.
- [ ] **Content Rights** declaration (whether the app contains third-party
      content requiring rights — no, for Kurn).
- [ ] **App Review Information** — reviewer contact phone/email and testing
      notes. Suggested notes: *"No account or login required. Grant the
      microphone permission when prompted, tap Record, then Stop — on-device
      transcription (Apple Speech, no configuration needed) and speaker
      identification run automatically under the Transcript tab. Cloud
      transcription and AI summaries are optional, off by default, and
      require the reviewer's own API key to test — on-device transcription
      covers the core flow without one. The Face ID/Touch ID prompt can be
      disabled under Settings > Recording if inconvenient during review."*
- [ ] **Advertising Identifier (IDFA)** — no, Kurn doesn't use it.
- [ ] **License Agreement** — Apple's Standard, or paste `EULA.md` as a
      custom agreement (see that file's header for how).

## Manual, per release

- [ ] Review the localized "What's New" text (`release_notes.txt` per
      locale) reads well for a public audience, not just testers.
- [ ] Wait for the tagged build to finish processing in TestFlight and note its
      exact build number.
- [ ] Dispatch `App Store Submission` against the matching `vX.Y.Z` tag with
      the exact version/build and approve its `release` Environment deployment.
      This is the explicit human decision to submit; the workflow then attaches
      the build and clicks the App Review API equivalent of **Submit for Review**.
- [ ] After Apple approves the version, release it manually in App Store Connect.
      The workflow deliberately does not enable automatic or phased release.

## Note on localization

Text metadata (`fastlane/metadata/`) now covers all 7 UI locales and is
pushed automatically on every tag (see above). Screenshots (`Snapfile`) are
still `en-US` only: the seeded meeting content in `ScreenshotSeedData.swift`
is hardcoded English, so localizing screenshots means translating that seed
data first, then adding `languages` entries to `Snapfile` — not required to
submit, but worth doing before or shortly after the first public release.
