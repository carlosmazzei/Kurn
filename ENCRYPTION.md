# Encryption Documentation for Kurn

**Last updated: August 22, 2026**

This document describes Kurn's purpose and its use of encryption, for App
Store Connect's Export Compliance requirements under the U.S. Export
Administration Regulations (EAR), Category 5, Part 2.

## App Overview

Kurn is a local-first app for recording meetings, transcribing audio,
identifying speakers, and generating structured AI summaries, built so
recordings stay on the user's device by default. Its core functions are:

- Recording meetings, with pause/resume/stop controls available from the app,
  the Lock Screen, Dynamic Island, or a companion Apple Watch app.
- Transcribing recorded audio, either fully on device (Apple's Speech
  framework or an on-device multilingual model) or, optionally, via a
  cloud Whisper-compatible API for longer recordings.
- Identifying distinct speakers in a recording (diarization) and letting the
  user assign names to them.
- Generating structured, template-driven summaries of a meeting using an AI
  provider, and answering questions about one meeting or the user's whole
  library.
- Organizing meetings into folders, tags, and saved searches.

None of this requires an account or server operated by the developer — Kurn
has no backend. Full functional detail is in the App Store description; data
handling is described in [PRIVACY.md](PRIVACY.md).

## Use of Encryption

Kurn uses encryption in exactly two places, both through Apple's own
standard, publicly available operating system frameworks — no proprietary or
custom cryptographic algorithm is implemented anywhere in the app:

1. **At-rest encryption of local data.** Recordings, transcripts, summaries,
   and app preferences are protected by iOS's built-in Data Protection
   (hardware-backed, tied to the device passcode) and, for credentials, the
   iOS Keychain. This is the standard mechanism every iOS app gets from the
   platform for protecting data stored on the device — Kurn does not
   implement its own file or database encryption.
2. **In-transit encryption for optional network requests.** Kurn's core
   functionality — recording, on-device transcription, and organizing
   meetings — makes no network requests at all. Two features are opt-in and
   off by default: cloud transcription (an OpenAI-compatible Whisper API)
   and cloud AI summaries (OpenAI, Anthropic, Google, Groq, or a compatible
   endpoint the user configures). When either is enabled, requests are sent
   over standard HTTPS/TLS via Apple's `URLSession`, the same standard
   transport-layer encryption used by any app or website — not a
   proprietary protocol.

## Export Compliance Classification

Kurn's use of encryption is limited to the standard, publicly available
algorithms built into iOS (Apple Data Protection, Keychain Services, and
TLS via `URLSession`), used only for protecting the app's own data at rest
and securing its own network communications — not for any specialized,
non-standard, or proprietary cryptographic purpose. Kurn therefore qualifies
for the exemption available to mass-market applications distributed through
the App Store that rely solely on standard encryption, under Category 5,
Part 2 of the EAR (see License Exception ENC, 15 CFR § 740.17). This is
declared in the app's `Info.plist` via `ITSAppUsesNonExemptEncryption =
false`, so this classification applies to every build unless that changes.

## Contact

Questions about this documentation can be raised as a GitHub issue at
<https://github.com/carlosmazzei/Kurn/issues>, or by emailing
carlos.mazzei@gmail.com.
