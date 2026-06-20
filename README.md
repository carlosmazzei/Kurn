# MeetSync

A native iOS app (Swift 6 / SwiftUI) for recording, transcribing, and
summarizing meetings — fully on-device first, with optional cloud transcription
and AI summaries using your own API keys. No backend, no third-party
dependencies.

## Features

- **Record meetings** locally to `.m4a` (offline-first, background audio,
  interruption + route-change handling).
- **Group recordings** into named meeting sessions.
- **Transcribe** on-device with Apple's `Speech` framework, or via the OpenAI
  Whisper API (chunked upload for long recordings).
- **Speaker diarization** — heuristic, on-device (silence + energy/ZCR
  clustering). Speakers are auto-labelled and user-renamable.
- **AI summaries** — OpenAI GPT-4o or Anthropic Claude, configurable, returning
  a markdown summary plus extracted action items and key decisions.
- **Local-only storage** with SwiftData. API keys live in the Keychain.
- **Share** a meeting as a structured Markdown file.
- Localized in English and Portuguese (pt-BR). Privacy manifest included; no
  analytics or tracking.

## Requirements

- Xcode 16+
- iOS 17.0+
- Your own OpenAI and/or Anthropic API key (entered in Settings)

## Getting started

1. Open `MeetSync.xcodeproj` in Xcode.
2. Select the `MeetSync` scheme and a simulator or device.
3. Build & run. On device, grant microphone and speech-recognition permission.
4. Open **Settings** (gear icon) to choose your AI provider and paste API keys.

> The app icon is a placeholder — replace `Assets.xcassets/AppIcon` before
> distribution.

## Architecture

MVVM with `@Observable` and `async/await` throughout.

```
MeetSync/
├── MeetSyncApp.swift            // @main, SwiftData container
├── ContentView.swift            // root NavigationStack
├── Models/                      // SwiftData @Model types + enums
├── Views/                       // SwiftUI screens
├── ViewModels/                  // @MainActor @Observable coordinators
├── Services/                    // audio, transcription, diarization
├── Providers/                   // OpenAI / Anthropic via URLSession
├── Infrastructure/              // Keychain, errors, settings, export, extensions
└── Resources/                   // localizations + PrivacyInfo.xcprivacy
```

Notes:

- Cloud transcription always uses OpenAI Whisper; summaries can use either
  provider.
- Speaker labels are approximate by design — the UI flags them as auto-detected.
