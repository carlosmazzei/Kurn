# Kurn

[![iOS CI](https://github.com/carlosmazzei/Kurn/actions/workflows/swift.yml/badge.svg)](https://github.com/carlosmazzei/Kurn/actions/workflows/swift.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-iOS%2017%2B%20%7C%20watchOS%2010%2B-blue.svg)
![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF.svg)
![Architecture](https://img.shields.io/badge/architecture-local--first-2F855A.svg)
![Privacy](https://img.shields.io/badge/privacy-no%20tracking-2F855A.svg)

Kurn is a local-first iOS and watchOS app for recording meetings,
transcribing audio, identifying speakers, and generating structured AI
summaries. It is built with Swift 6, SwiftUI, SwiftData, AVFoundation, Apple's
Speech framework, ActivityKit, and WatchConnectivity.

Recordings and meeting data are stored on device by default. Network requests
only happen when the user chooses OpenAI Whisper transcription or generates a
summary with a configured AI provider.

## Current App

- Native iPhone and iPad app targeting iOS 17.0 or newer.
- Companion Apple Watch app targeting watchOS 10.0 or newer.
- Lock Screen and Dynamic Island Live Activity for active recordings.
- Local SwiftData store for meetings, recordings, speakers, transcripts, and
  summaries.
- Local `.m4a` audio files saved in the app's Documents directory.
- English and Brazilian Portuguese localizations.
- App Privacy Manifest with no tracking and no collected data types.

## Features

- Create and edit meeting sessions with title, notes, and preferred language.
- Record meetings in one or more audio segments.
- Pause, resume, cancel, and stop recordings from the app.
- Control active recordings from the Lock Screen, Dynamic Island, or Apple
  Watch.
- Mirror recording state and input level to the Watch app.
- Search meetings and filter them by all, today, or this week.
- Play saved recordings and seek from transcript timestamps.
- Delete meetings and individual recording segments.
- Track local audio storage usage and reset all app data from Settings.

## Recording And Transcription

- Records AAC `.m4a` audio through an `AVAudioEngine` input tap.
- Supports whole-room and focused-speaker microphone pickup preferences.
- Supports high, standard, and low audio quality presets.
- Handles audio interruptions and route changes, including automatic pause on
  relevant route changes.
- Cleans audio before transcription with preprocessing, while falling back to
  the original file if preprocessing fails.
- Transcribes on device with Apple's Speech framework.
- Optionally transcribes with OpenAI Whisper using chunked uploads for longer
  recordings.
- Runs lightweight heuristic speaker diarization and fuses speaker turns with
  transcript spans.
- Lets users rename detected speakers.

Supported transcription languages are auto-detect, Portuguese, English,
Spanish, French, German, Japanese, and Chinese.

## AI Summaries

Kurn can generate a structured meeting summary from existing transcripts.
Summaries include a markdown body, key decisions, and action items.

Supported summary providers:

- OpenAI
- Anthropic
- Google AI
- Groq

Each provider has selectable models in Settings. Cloud transcription always uses
OpenAI Whisper, regardless of the selected summary provider.

## Configuration

Kurn works without cloud credentials when using on-device transcription.
Cloud features require user-provided API keys.

- OpenAI key: required for Whisper transcription and OpenAI summaries.
- Anthropic key: required for Anthropic summaries.
- Google AI key: required for Gemini summaries.
- Groq key: required for Groq summaries.
- API keys are stored in the Keychain.
- Non-secret preferences are stored in `UserDefaults`.

Default preferences are managed in:

`Kurn/Infrastructure/AppSettings.swift`

Provider setup is handled through:

`Kurn/Providers/ProviderFactory.swift`

## Privacy

Kurn is designed to avoid a backend service controlled by the app.

- Audio files are saved locally in the app's Documents directory.
- Meeting metadata, transcripts, summaries, speakers, and recordings are stored
  locally with SwiftData.
- API keys are stored in the Keychain.
- Network requests are only made when the user selects a cloud transcription or
  summary feature.
- No analytics or tracking SDKs are included.
- The privacy manifest declares no tracking and no collected data types.

## Requirements

- macOS with Xcode installed.
- Xcode 16 or newer. The project has been opened with Xcode 26.5.
- iOS 17.0 or newer for the main app.
- watchOS 10.0 or newer for the Watch app.
- An iOS simulator or a physical iPhone/iPad.
- Optional: a paired Apple Watch or watchOS simulator for Watch remote control.
- Optional: API keys for OpenAI, Anthropic, Google AI, or Groq.

## Getting Started

1. Open `Kurn.xcodeproj` in Xcode.
2. Select the `Kurn` scheme.
3. Choose an iOS simulator or a connected device.
4. Press `Cmd + R` to build and run.
5. Grant microphone permission when prompted.
6. Grant speech recognition permission if you use on-device transcription.
7. Open Settings in the app to configure transcription mode, language, audio
   quality, microphone pickup, summary provider, model, and API keys.

## Running In The Simulator

In Xcode:

1. Use the device picker in the toolbar.
2. Select an iPhone simulator, such as `iPhone 17`.
3. Run the app with `Cmd + R`.

If no simulators are available, install an iOS runtime from:

`Xcode > Settings > Platforms`

For terminal builds, make sure the command line tools point to Xcode:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Then build with:

```bash
xcodebuild \
  -project Kurn.xcodeproj \
  -scheme Kurn \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build
```

Use another simulator name if `iPhone 17` is not installed locally.

## Running Tests

Unit tests live in the `KurnTests` target and use Swift Testing. They cover
logic such as JSON parsing, Markdown export, SwiftData model helpers, audio
chunking and preprocessing, provider setup, formatting helpers, and view model
behavior against an in-memory `ModelContainer`.

Run tests from Xcode with `Cmd + U`, or from the terminal:

```bash
xcodebuild \
  -project Kurn.xcodeproj \
  -scheme Kurn \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test
```

CI is configured in `.github/workflows/swift.yml` and runs clean test on macOS
with the `Kurn` scheme.

## Linting

Kurn uses SwiftLint for Swift style and static checks.

Install locally with Homebrew:

```bash
brew install swiftlint
```

Run it from the repository root:

```bash
swiftlint lint --config .swiftlint.yml
```

If SwiftLint cannot load SourceKit, make sure the active developer directory
points to Xcode:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

The GitHub Actions workflow installs SwiftLint and runs linting before the
build/test step.

## Export

Meetings can be shared as structured Markdown. The export includes:

- Meeting title, date, notes, and total duration.
- Summary content, key decisions, and action items when available.
- Speaker-attributed transcript lines with timestamps.

Export generation is implemented in:

`Kurn/Infrastructure/MeetingExport.swift`

## Architecture

The app follows an MVVM-style structure with `@Observable`, `@MainActor` view
models, async service APIs, and a SwiftData model container.

```text
Kurn/
├── KurnApp.swift                 # App entry point and SwiftData container
├── ContentView.swift            # Root NavigationStack
├── Models/                      # SwiftData @Model types and enums
├── Views/                       # SwiftUI screens and reusable views
├── ViewModels/                  # Main-actor observable coordinators
├── Services/                    # Audio, transcription, diarization, summaries
├── Providers/                   # OpenAI, Anthropic, Google AI, and Groq clients
├── Infrastructure/              # Keychain, errors, settings, export, extensions
├── Resources/                   # Localizations and privacy manifest
└── Assets.xcassets/             # App icon and accent color

KurnWatch/
├── KurnWatchApp.swift            # Watch app entry point
├── WatchRecorderView.swift      # Watch remote control UI
└── WatchConnectivityManager.swift

KurnLiveActivityExtension/
├── RecordingActivityAttributes.swift
└── RecordingLiveActivityWidget.swift
```

## Important Implementation Notes

- Cloud transcription always uses OpenAI Whisper.
- Summary generation can use OpenAI, Anthropic, Google AI, or Groq.
- Speaker diarization is heuristic and approximate by design.
- On-device transcription availability depends on Apple's Speech framework,
  simulator/device support, and the selected language.
- Background audio recording is enabled through `UIBackgroundModes`.
- The main app and extensions use checked-in `Info.plist` files.

## Development Notes

Useful files:

- `Kurn/Services/AudioRecorderService.swift`
- `Kurn/Services/TranscriptionService.swift`
- `Kurn/Services/SummaryService.swift`
- `Kurn/Services/SpeakerDiarizer.swift`
- `Kurn/Services/PhoneSessionController.swift`
- `Kurn/Views/SettingsView.swift`
- `Kurn/Infrastructure/MeetingExport.swift`

Before shipping:

- Confirm the bundle identifier and signing team.
- Test recording on a physical device.
- Test Watch remote control with a paired Apple Watch or watchOS simulator.
- Test microphone, speech recognition, Live Activity, and network permission
  flows.
- Validate export output with real meeting data.

## License

Kurn is released under the [MIT License](LICENSE).
