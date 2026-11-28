# Kurn — Threat Model

Repository: `carlosmazzei/Kurn` (iOS 26 app, watchOS companion, Live Activity extension, `Packages/KurnCore`). Built from the code, `SECURITY.md` (scope section), `PRIVACY.md`, `ENCRYPTION.md`, `CLAUDE.md`, and the owner's answers (2026-11-01).

## System overview and trust boundaries

Kurn is local-first: it records meetings, transcribes, diarizes and summarizes on device. There is **no backend**; no infrastructure repository applies. The only "infrastructure" is the GitHub Actions + fastlane release pipeline in this repo.

Trust boundaries:
1. **Device sandbox ↔ other apps / OS surfaces** — share sheet (PDF document type), `onOpenURL`, App Intents, Lock Screen / Dynamic Island controls, WatchConnectivity, iCloud KVS.
2. **App ↔ network** — opt-in cloud transcription (Whisper-compatible: OpenAI, Groq, ElevenLabs, custom endpoint) and cloud LLMs (OpenAI, Anthropic, Google, Groq, custom OpenAI-compatible endpoint); on-device model downloads (whisper.cpp, FluidAudio, Sherpa-ONNX, embeddings); the daily remote model catalog check (`ModelCatalogUpdater`, a header-less GET of `catalog/model-catalog-v1.json` from this repository's default branch, only while a cloud provider is in use).
3. **Untrusted content ↔ LLM prompts** — transcripts, imported PDFs, OCR'd photos and provider responses flow into summary/chat/wiki/document/correction prompts and are rendered as Markdown.
4. **Repo contributors (PRs) ↔ CI/release secrets** — App Store Connect API key, `fastlane match` signing repo credentials, Codecov token, provider API keys used by evaluation workflows.

## Components

| Component | Code |
|---|---|
| **App UI & Access Gate** | `Kurn/Views/`, `Kurn/ContentView.swift`, `Kurn/ViewModels/`, `Kurn/Services/RecordingAccessGate.swift`, `SensitiveActionAuthorizer.swift`, `SystemLocalAuthenticator.swift`, `Kurn/Views/MarkdownText.swift`/`MarkdownPresentation.swift` |
| **Storage & Credentials** | `Kurn/Infrastructure/` (`KeychainManager`, `CredentialStore`, `ModelStore*`, `RecordingProtection`, `RecordingQuarantine`/`Trash`/`Recovery`, `MeetingExport*`, `PDFExportRenderer`, `LogExport`, `AppLog`, `CrashReporting/`, `CloudSettingsSync`, `TemplateSyncMerger`, `LibraryEraser`, `KurnSchema*`), `Kurn/Models/`, `Kurn/Application/MeetingLibrary.swift` |
| **Recording Surfaces** | `Kurn/Services/Audio*`, `Recording*` (`RecordingCommandRouter`, `RecordingLauncher`, `RecordingSink`, `RecordingSurfacePayloads`), `CaptureJournal*`, `PhoneSessionController.swift`, `LockScreenRecordingController.swift`, `Kurn/AppIntents/`, `KurnLiveActivityExtension/`, `KurnWatch/` |
| **Content Import** | `Kurn/Application/IncomingFileInbox.swift`, `MeetingAttachmentImporter.swift`, `Kurn/Services/PDFTextExtractor.swift`, `PhotoTextRecognizer.swift`, `PhotoCaptureController.swift`, `AttachmentFileStore.swift`, `PhotoFileStore.swift` |
| **Cloud Providers** | `Kurn/Providers/` (`ProviderURLPolicy`, `ProviderHTTPPolicy`/`Transport`/`Streaming`, `ProviderResponseParsing`, each `*Provider`, `ModelCatalogUpdater`), `catalog/`, `WhisperBackgroundUploader.swift`, `Kurn/Services/Speech/CloudSpeechEngine.swift`, LLM features: `SummaryService`, `WikiService`, `HarnessChatService`, `AutoTaggingService`, `Pipeline/LLMTranscriptCorrector.swift`, `Kurn/Application/*Coordinator.swift` |
| **On-device Models** | `ModelFileDownloader.swift`, `ModelVerification.swift`, `ModelStore.swift`, `*ModelDownloader.swift`, `FluidAudio*`, `SherpaOnnx*`, `Kurn/Services/Embedding/`, `Packages/WhisperCpp` (prebuilt XCFramework binary target), `ModelDownloadConsent*` |
| **Knowledge Engine** | `Kurn/Application/Knowledge/` (protected `KnowledgeStore`, `KnowledgeCompilationCoordinator`, `KnowledgeExtractionService`, readers), `Kurn/Application/Agent/Tools/ChatKnowledgeTools*`, `Kurn/Views/Knowledge*`, `Packages/KurnCore/Sources/KurnCore/Knowledge/` (`KnowledgeProcessingPolicy`, `KnowledgePolicyEvaluator`) |
| **KurnCore** | `Packages/KurnCore/` (pure-Foundation logic: export, pipeline types, provider types, policies) |
| **CI & Release** | `.github/workflows/` (`swift.yml`, `screenshots.yml`, `app-store-submit.yml`, `accessibility-labels.yml`, `reliability-hardening.yml`, `marketing-screenshots.yml`, `live-provider-smoke.yml`, `pipeline-eval.yml`, `knowledge-ask-eval.yml`), `.github/CODEOWNERS`, `Tools/check_workflow_security.py`, `.github/actions/`, `fastlane/`, `scripts/` |

## Entry points and who can reach them

- **Share sheet / `onOpenURL`** → `IncomingFileInbox` (PDFs only, copied into `Documents/Inbox/`): any app or any sender of a PDF (Mail, Safari).
- **Photo / PDF attachments** → OCR and text extraction → LLM prompts: whoever authors the document or whiteboard.
- **Audio being recorded / imported**: anyone speaking in the room — content can carry prompt injection into transcripts.
- **App Intents, Control widget, Live Activity buttons** (`StartRecordingIntent`, `RecordingControlIntent`): reachable from Lock Screen without unlocking the app.
- **WatchConnectivity** messages (`PhoneSessionController.session(_:didReceiveMessage:)`): paired Watch app.
- **iCloud KVS** (`CloudSettingsSync`): the user's other devices on the same Apple ID (templates/settings).
- **Network responses**: cloud providers, user-configured custom endpoints, model-download hosts, the remote model catalog (and anyone on-path if TLS/redirect policy is weak). Anyone who can merge to this repository's default branch can change the catalog.
- **GitHub PRs** → `swift.yml` (`pull_request` to any branch, `contents: read`); tag pushes → release jobs with protected `release` environment.

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
- Remote model catalog: read strictly (`ModelCatalogDocument`: one format and schema, bounded size, model count, IDs and numeric ranges; refused whole otherwise), never older than the bundled catalogs or the one applied, never dated more than two days in the future; it can change only context-window, capability and cost estimates, never an endpoint, key or what is sent.
- Knowledge egress (K6.1): extraction and Ask synthesis reach a cloud provider only when the default-deny `KnowledgeProcessingPolicy` admits the operation and the provider's grant in the cloud-consent ledger exists when the work starts; reads are authorized before and after they run, so unauthorized names, counts, quotes and errors are not returned; embeddings of knowledge pages need their own `embedding` authorization. `Tools/check_static_policy.py`'s `knowledge-network` rule fails CI if Knowledge code names `URLSession`, `URLRequest`, `LLMHTTP`, `ProviderHTTPTransport`, `NWConnection` or a CloudKit/iCloud key-value store, so its only egress is the provider call.
- Cloud features off by default; `LSSupportsOpeningDocumentsInPlace = false`; Inbox copies deleted after decision.
- CI: `permissions: contents: read` default, `persist-credentials: false`, SHA-pinned actions, protected `release` environment requiring admin approval.
- CI secrets: keys that spend money or ship the app live in protected environments (`paid-evals` for the AI provider and Hugging Face keys, `release` for App Store Connect and fastlane match), released only to a job that declares the environment, after its reviewer approves and only from `main`; `Tools/check_workflow_security.py` fails CI for a job that reads one without it, a paid workflow that is not `workflow_dispatch`-only, a trigger that runs outsider content with secrets (`pull_request_target`, `workflow_run`, comment/issue/review/discussion), `secrets: inherit` outside one documented case, or a lost `.github/CODEOWNERS` owner for `.github/`. Fork pull requests never receive secrets. Whether the environments, the code-owner ruleset and the providers' spend limits are configured is a repository setting this model cannot verify.

## Out of scope / accepted risk (owner)

- Attacker with **physical access to an unlocked device** (`SECURITY.md`).
- Vulnerabilities in third-party services/SDKs themselves (OpenAI, Anthropic, Google, Groq, FluidAudio, Apple frameworks) (`SECURITY.md`).
- **The user disabling the Face ID / passcode gate in Settings** — the user's choice; findings that only matter once the gate is off are accepted risk.
- **`Tools/` Python scripts and the evaluation pipeline** (`Tools/`, `Tools/evaluation/`, `.github/workflows/pipeline-eval.yml`, `KurnTests/Support/Evaluation/`).
- **DEBUG-only, UI-test and screenshot-seeding code** (`Kurn/DebugSupport/`, `#if DEBUG` paths, `KurnUITests/`, `KurnWatchUITests/`, screenshot seed data, `scripts/screenshots/`).

## Open questions

- Is a user-configured custom endpoint trusted (the user chose it), or should it be treated like any provider attacker? Currently: treated as provider attacker (attacker 2), but impact limited to what the user sent it.
- Is the `kurn-certificates` signing repository and its access model in scope? Not in this repository; not reviewed.
