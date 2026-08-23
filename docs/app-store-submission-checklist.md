# App Store Submission Checklist

TestFlight (`fastlane beta`) and the App Store are two different stages. A
`vX.Y.Z` tag now drives both in sequence, but every App Store Connect mutation
waits for an administrator to approve its protected `release` Environment job.
This is what's still needed to take a tagged build public, split by who does it.

## Already automated

- [x] Signing, archiving, and TestFlight upload — `fastlane beta`, runs
      automatically in the `beta` job whenever a `vX.Y.Z` tag is pushed
      (`.github/workflows/swift.yml`).
- [x] Text metadata (description, keywords, subtitle, promotional text,
      release notes, support/marketing/privacy URLs, copyright, category),
      **for all 7 UI locales** (`fastlane/metadata/{en-US,pt-BR,es-ES,fr-FR,
      it,de-DE,zh-Hans}/`) — uploaded together with screenshots by the
      `store-assets` job after the tag passes `build-and-test`.
- [x] Screenshots — captured automatically for every successful `vX.Y.Z` tag
      through the reusable `App Store Screenshots` workflow, and always uploaded
      as the `screenshots` artifact before their protected upload job starts.
      The workflow can still be dispatched manually for ad-hoc captures.
      **English (`en-US`) only for now** — `KurnUITests/ScreenshotUITests.swift`
      already drives navigation purely through `.accessibilityIdentifier`,
      but `Kurn/DebugSupport/ScreenshotSeedData.swift`'s seeded meeting
      titles, transcript lines, and summaries are hardcoded English, so
      adding more `Snapfile` languages today would just localize the chrome
      around still-English content. Translating the seed data is a
      prerequisite, not wired up here.
- [x] Pushing screenshots + text metadata together — `fastlane store_assets`
      runs automatically for the tag after capture, behind its own `release`
      Environment approval. A manual dispatch with `upload: false` still captures
      from any branch without touching App Store Connect; manual upload requires
      a `vX.Y.Z` ref.
- [x] Static metadata validation — `Tools/validate_store_metadata.py` runs in
      the regular `iOS CI` workflow and checks locale/file completeness, Apple's
      text limits (including the 100-byte keyword limit), and HTTPS URLs before
      a release tag can reach the metadata upload job.
- [x] Accessibility Nutrition Labels — `fastlane/accessibility.json` declares
      VoiceOver, Larger Text, Reduced Motion, and Differentiate Without Color
      Alone for iPhone, iPad, and Apple Watch. `store_assets` upserts those
      declarations as drafts through Apple's API on every tagged release. The
      protected `App Store Accessibility` workflow publishes them when run with
      `publish: true` after an App Store version is live.
- [x] Waiting for TestFlight processing, attaching the tagged build, and
      submitting it to App Review — `beta` now waits for Apple to finish
      processing, then the dependent `submit` job derives version/build from the
      tagged project and waits for its own `release` Environment approval. The
      standalone `App Store Submission` workflow remains available as a manual
      retry. Neither path releases an approved version automatically.
- [x] Privacy policy, Terms of Use, EULA, encryption documentation —
      `PRIVACY.md`, `TERMS.md`, `EULA.md`, `ENCRYPTION.md`.
- [x] Export compliance declared in `Info.plist`
      (`ITSAppUsesNonExemptEncryption = false`).

The tag-driven workflow reaches App Review only after `beta` and `store-assets`
succeed. TestFlight upload, screenshot/metadata upload, and App Review submission
each reference the protected `release` GitHub Environment, so each mutation
requires a separate administrator approval. The submission lane sets
`automatic_release: false`, leaving the public release after Apple's approval as
a deliberate manual action.

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

- [ ] Before tagging, review that each localized `release_notes.txt` reads well
      for a public audience, not just testers.
- [ ] After `build-and-test` succeeds, approve the protected `beta` job to build,
      upload, and wait for TestFlight processing.
- [ ] Approve the protected screenshot/metadata upload after inspecting the
      generated `screenshots` artifact if desired.
- [ ] When both prerequisites are green, approve the protected `submit` job. This
      is the explicit human decision to send the derived tagged build to App
      Review; no version/build entry or separate workflow dispatch is required.
- [ ] After Apple approves the version, release it manually in App Store Connect.
      The workflow deliberately does not enable automatic or phased release.
- [ ] Once the first version is live — and whenever the declared capabilities
      change — dispatch `App Store Accessibility` against a tag with
      `publish: true`, then approve its protected deployment. Apple allows draft
      synchronization before launch but rejects label publication until a live
      version exists.

## Note on localization

Text metadata (`fastlane/metadata/`) now covers all 7 UI locales and is
pushed automatically on every tag (see above). Screenshots (`Snapfile`) are
still `en-US` only: the seeded meeting content in `ScreenshotSeedData.swift`
is hardcoded English, so localizing screenshots means translating that seed
data first, then adding `languages` entries to `Snapfile` — not required to
submit, but worth doing before or shortly after the first public release.
