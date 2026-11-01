# Kurn — Threat Model

Repository: `carlosmazzei/Kurn` (iOS 26 app, watchOS companion, Live Activity extension, `Packages/KurnCore`). Built from the code, `SECURITY.md` (scope section), `PRIVACY.md`, `ENCRYPTION.md`, `CLAUDE.md`, and the owner's answers (2026-11-01).

## System overview and trust boundaries

Kurn is local-first: it records meetings, transcribes, diarizes and summarizes on device. There is **no backend**; no infrastructure repository applies. The only "infrastructure" is the GitHub Actions + fastlane release pipeline in this repo.

Trust boundaries:
1. **Device sandbox ↔ other apps / OS surfaces** — share sheet (PDF document type), `onOpenURL`, App Intents, Lock Screen / Dynamic Island controls, WatchConnectivity, iCloud KVS.
2. **App ↔ network** — opt-in cloud transcription (Whisper-compatible: OpenAI, Groq, ElevenLabs, custom endpoint) and cloud LLMs (OpenAI, Anthropic, Google, Groq, custom OpenAI-compatible endpoint); on-device model downloads (whisper.cpp, FluidAudio, Sherpa-ONNX, embeddings).
3. **Untrusted content ↔ LLM prompts** — transcripts, imported PDFs, OCR'd photos and provider responses flow into summary/chat/wiki/document/correction prompts and are rendered as Markdown.
4. **Repo contributors (PRs) ↔ CI/release secrets** — App Store Connect API key, `fastlane match` signing repo credentials, Codecov token, provider API keys used by evaluation workflows.

## Components

| Component | Code |
|---|---|
| **App UI & Access Gate** | `Kurn/Views/`, `Kurn/ContentView.swift`, `Kurn/ViewModels/`, `Kurn/Services/RecordingAccessGate.swift`, `SensitiveActionAuthorizer.swift`, `SystemLocalAuthenticator.swift`, `Kurn/Views/MarkdownText.swift`/`MarkdownPresentation.swift` |
| **Storage & Credentials** | `Kurn/Infrastructure/` (`KeychainManager`, `CredentialStore`, `ModelStore*`, `RecordingProtection`, `RecordingQuarantine`/`Trash`/`Recovery`, `MeetingExport*`, `PDFExportRenderer`, `LogExport`, `AppLog`, `CrashReporting/`, `CloudSettingsSync`, `TemplateSyncMerger`, `LibraryEraser`, `KurnSchema*`), `Kurn/Models/`, `Kurn/Application/MeetingLibrary.swift` |
| **Recording Surfaces** | `Kurn/Services/Audio*`, `Recording*` (`RecordingCommandRouter`, `RecordingLauncher`, `RecordingSink`, `RecordingSurfacePayloads`), `CaptureJournal*`, `PhoneSessionController.swift`, `LockScreenRecordingController.swift`, `Kurn/AppIntents/`, `KurnLiveActivityExtension/`, `KurnWatch/` |
| **Content Import** | `Kurn/Application/IncomingFileInbox.swift`, `MeetingAttachmentImporter.swift`, `Kurn/Services/PDFTextExtractor.swift`, `PhotoTextRecognizer.swift`, `PhotoCaptureController.swift`, `AttachmentFileStore.swift`, `PhotoFileStore.swift` |
| **Cloud Providers** | `Kurn/Providers/` (`ProviderURLPolicy`, `ProviderHTTPPolicy`/`Transport`/`Streaming`, `ProviderResponseParsing`, each `*Provider`), `WhisperBackgroundUploader.swift`, `Kurn/Services/Speech/CloudSpeechEngine.swift`, LLM features: `SummaryService`, `MeetingChatService*`, `WikiService`, `DocumentGenerationService`, `AutoTaggingService`, `Pipeline/LLMTranscriptCorrector.swift`, `Kurn/Application/*Coordinator.swift` |
| **On-device Models** | `ModelFileDownloader.swift`, `ModelVerification.swift`, `ModelStore.swift`, `*ModelDownloader.swift`, `FluidAudio*`, `SherpaOnnx*`, `Kurn/Services/Embedding/`, `Packages/WhisperCpp` (prebuilt XCFramework binary target), `ModelDownloadConsent*` |
| **KurnCore** | `Packages/KurnCore/` (pure-Foundation logic: export, pipeline types, provider types, policies) |
| **CI & Release** | `.github/workflows/` (`swift.yml`, `screenshots.yml`, `app-store-submit.yml`, `accessibility-labels.yml`, `reliability-hardening.yml`, `marketing-screenshots.yml`), `.github/actions/`, `fastlane/`, `scripts/` |

## Entry points and who can reach them

- **Share sheet / `onOpenURL`** → `IncomingFileInbox` (PDFs only, copied into `Documents/Inbox/`): any app or any sender of a PDF (Mail, Safari).
- **Photo / PDF attachments** → OCR and text extraction → LLM prompts: whoever authors the document or whiteboard.
- **Audio being recorded / imported**: anyone speaking in the room — content can carry prompt injection into transcripts.
- **App Intents, Control widget, Live Activity buttons** (`StartRecordingIntent`, `RecordingControlIntent`): reachable from Lock Screen without unlocking the app.
- **WatchConnectivity** messages (`PhoneSessionController.session(_:didReceiveMessage:)`): paired Watch app.
- **iCloud KVS** (`CloudSettingsSync`): the user's other devices on the same Apple ID (templates/settings).
- **Network responses**: cloud providers, user-configured custom endpoints, model-download hosts (and anyone on-path if TLS/redirect policy is weak).
- **GitHub PRs** → `swift.yml` (`pull_request` to `main`, `contents: read`); tag pushes → release jobs with protected `release` environment.

## Assets and sensitivity

Owner: meeting content and provider API keys matter **equally** and are top priority.
- **Meeting audio, transcripts, summaries, chat history, wiki/documents, attachments, embeddings** — highly sensitive (confidential conversations). At rest: Data Protection (`completeUnlessOpen` store; protected `Documents/Recordings/`), Face ID/passcode gate by default.
- **Provider API keys** — Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), never synced.
- **CI/release secrets** — ASC API key, `MATCH_PASSWORD`/`MATCH_GIT_*` (signing certs), `CODECOV_TOKEN`, `GITHUB_TOKEN` with `contents: write` in the release job. Compromise allows shipping a malicious build to users.
- Logs / diagnostic reports — must not contain meeting content or keys.

## Attacker profiles (all in scope per owner)

1. **Malicious content author** — crafts a PDF, photo, shared file, or spoken content that reaches parsers or LLM prompts (prompt injection to exfiltrate other meetings via chat/document synthesis, Markdown/link rendering abuse, parser crashes).
2. **Network / provider attacker** — on-path attacker, malicious or compromised provider/custom endpoint, malicious model-download host: response-parsing bugs, redirect to another origin with the API key, unverified model binaries.
3. **Other apps / co-located device surfaces** — other apps via URL/share handling, Lock Screen access to recording controls, data leaking via pasteboard, exports, logs, backups, iCloud KVS.
4. **CI contributor** — an external PR author trying to reach release secrets or tamper with the build/release pipeline (workflow injection, unpinned actions, untrusted inputs in `run:`).

## Existing controls

- Data Protection on the store and recordings; `RecordingProtection`, `ModelStoreProtection`; Face ID gate (`RecordingAccessGate`, `SecurityCoverWindow`) with no Settings escape hatch while the device has a passcode.
- Keychain with this-device-only accessibility; keys never in UserDefaults/iCloud.
- `ProviderURLPolicy`: base-URL validation, unsafe-path rejection, same-origin redirect policy.
- Model downloads: SHA-256 verification at install (`ModelFileDownloader.verify`, `ModelVerification`), explicit download consent.
- Cloud features off by default; `LSSupportsOpeningDocumentsInPlace = false`; Inbox copies deleted after decision.
- CI: `permissions: contents: read` default, `persist-credentials: false`, SHA-pinned actions, protected `release` environment requiring admin approval.

## Out of scope / accepted risk (owner)

- Attacker with **physical access to an unlocked device** (`SECURITY.md`).
- Vulnerabilities in third-party services/SDKs themselves (OpenAI, Anthropic, Google, Groq, FluidAudio, Apple frameworks) (`SECURITY.md`).
- **The user disabling the Face ID / passcode gate in Settings** — the user's choice; findings that only matter once the gate is off are accepted risk.
- **`Tools/` Python scripts and the evaluation pipeline** (`Tools/`, `Tools/evaluation/`, `.github/workflows/pipeline-eval.yml`, `KurnTests/Support/Evaluation/`).
- **DEBUG-only, UI-test and screenshot-seeding code** (`Kurn/DebugSupport/`, `#if DEBUG` paths, `KurnUITests/`, `KurnWatchUITests/`, screenshot seed data, `scripts/screenshots/`).

## Open questions

- Is a user-configured custom endpoint trusted (the user chose it), or should it be treated like any provider attacker? Currently: treated as provider attacker (attacker 2), but impact limited to what the user sent it.
- Is the `kurn-certificates` signing repository and its access model in scope? Not in this repository; not reviewed.
