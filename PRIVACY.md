# Privacy Policy for Kurn

**Last updated: August 22, 2026**

Kurn is a local-first app. This policy describes, plainly, what that means in
practice — grounded in what the app's code actually does, not aspirational
language. Kurn's iOS Privacy Manifest (`PrivacyInfo.xcprivacy`) declares no
tracking and no collected data types, and this document explains the substance
behind that declaration.

## What Kurn stores

When you record a meeting, Kurn stores the following **on your device only**:

- Audio recordings (`.m4a` files)
- Transcripts, speaker labels, and AI-generated summaries
- Meeting titles, notes, tags, folders, and your organization of them
- Any semantic search index or chat history you generate while using the app

This data lives in the app's local SwiftData store and a protected directory
under the app's Documents folder, encrypted at rest by iOS Data Protection. By
default, opening the parts of the app that show recordings requires Face ID,
Touch ID, or your device passcode — you can turn that requirement off in
Settings, but the on-disk encryption stays on regardless.

Kurn does not operate a server. There is no backend that receives, stores, or
processes your meetings. Nothing you record is uploaded anywhere unless you
explicitly turn on one of the optional cloud features described below.

## What Kurn does not collect

Kurn has no analytics SDK, no crash-reporting service, no advertising
identifiers, and no user accounts. Nothing about how you use the app is
collected, aggregated, or sent to the developer. This is declared formally in
the app's Privacy Manifest, which lists zero collected data types.

## When data leaves your device

Two features are opt-in and off by default. If you turn one on, the relevant
audio or transcript text is sent **directly from your device** to the
third-party AI provider you choose and configure, using an API key you supply
and that Kurn stores in the iOS Keychain (never in plain app storage, never
transmitted to the Kurn developer):

- **Cloud transcription** — an OpenAI-compatible Whisper API (OpenAI, Groq, or
  a custom compatible endpoint you enter yourself). Sends audio to that
  provider for transcription.
- **Cloud AI summaries and chat** — OpenAI, Anthropic, Google Gemini, Groq, or
  a custom OpenAI-compatible endpoint. Sends transcript text to that provider
  to generate a summary or answer a question.

In both cases, the request goes straight from your device to the provider
using your own credentials — Kurn's developer is not a party to that request
and never sees the content. That provider's own privacy policy and terms
govern how they handle what you send them. If you never enable these features,
none of your meeting content ever leaves your device.

## Diagnostics

Settings includes an opt-in toggle for on-device crash/hang reports (built on
Apple's MetricKit) and a log viewer/exporter. Both stay on-device and are only
shared if you explicitly export and send them yourself — for example,
attaching an exported log to a bug report. Nothing diagnostic is transmitted
automatically. Simple in-app usage counters (e.g., for onboarding prompts)
never leave the device at all.

## Your controls

- Delete an individual recording or meeting at any time from within the app.
- Reset all app data from Settings, which removes every recording, transcript,
  and summary from the device.
- Turn the Face ID / Touch ID / passcode gate on or off in Settings.
- Turn diagnostic reports on or off in Settings, and delete previously saved
  reports from the diagnostics screen.
- Remove a configured AI provider's API key from the Keychain at any time from
  Settings.

## Children's privacy

Kurn does not collect data of any kind, from any user, so there is no
age-related data collection to describe. The app is not directed at children.

## Open source

Kurn's full source code, including every file referenced in this policy, is
public. You can verify any claim made here directly:
<https://github.com/carlosmazzei/Kurn>.

## Changes to this policy

Changes to this policy are made through the same public GitHub repository as
the app's source code, so its history is visible in the repository's commit
log.

## Contact

Questions about this policy or the app's data handling can be raised as a
GitHub issue at <https://github.com/carlosmazzei/Kurn/issues>, or by emailing
carlos.mazzei@gmail.com.
