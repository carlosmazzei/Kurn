# App Store Submission Checklist

TestFlight (`fastlane beta`) and the App Store are two different things — a
build validated on TestFlight is not automatically submitted anywhere else.
This is what's still needed to take a TestFlight build public, split by who
does it.

## Already automated

- [x] Signing, archiving, and TestFlight upload — `fastlane beta` (CI, tag-triggered)
- [x] Text metadata (description, keywords, subtitle, promotional text,
      release notes, support/marketing/privacy URLs, copyright, category) —
      `fastlane metadata`, from `fastlane/metadata/en-US/`
- [x] Screenshots — `fastlane screenshots` (or the `App Store Screenshots`
      GitHub Actions workflow, `workflow_dispatch`, artifact `screenshots`)
- [x] Metadata + screenshots together — `fastlane store_assets`
- [x] Privacy policy, Terms of Use, EULA, encryption documentation —
      `PRIVACY.md`, `TERMS.md`, `EULA.md`, `ENCRYPTION.md`
- [x] Export compliance declared in `Info.plist`
      (`ITSAppUsesNonExemptEncryption = false`)

None of the above submits the app for review or changes what's publicly
visible — `deliver`'s `submit_for_review` is never set, deliberately.

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

- [ ] Select the TestFlight build to attach to the App Store version being
      submitted.
- [ ] Review the localized "What's New" text (`release_notes.txt` per
      locale) reads well for a public audience, not just testers.
- [ ] Click **Submit for Review**.

## Note on localization

Metadata (`fastlane/metadata/`) and screenshots (`Snapfile`) are currently
English-only (`en-US`), even though the app's UI ships in 7 languages. Adding
more App Store locales means adding matching `fastlane/metadata/<locale>/`
folders and `languages` entries in `Snapfile` — not required to submit, but
worth doing before or shortly after the first release.
