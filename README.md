# MeetSync

MeetSync is a native iOS app for recording, transcribing, and summarizing
meetings. It is built with Swift 6, SwiftUI, SwiftData, and Apple's modern
concurrency APIs.

The app is local-first: recordings and meeting data stay on the device, on-device
transcription is supported through Apple's Speech framework, and optional cloud
features use API keys that the user provides in Settings.

## Features

- Record meetings to local `.m4a` files.
- Pause, resume, cancel, and stop recordings.
- Show active recordings as a custom Live Activity on the iPhone Lock Screen and
  Dynamic Island, with pause/resume and stop actions.
- Keep recordings grouped under named meeting sessions.
- Handle audio interruptions and route changes, including Bluetooth HFP input.
- Transcribe recordings on-device with Apple's Speech framework.
- Optionally transcribe with OpenAI Whisper using chunked uploads for longer
  recordings.
- Apply lightweight on-device speaker diarization using silence and audio
  feature clustering.
- Rename auto-detected speakers.
- Generate structured AI summaries with OpenAI or Anthropic.
- Extract key decisions and action items from transcripts.
- Store meeting metadata locally with SwiftData.
- Store API keys in the Keychain.
- Export a meeting as structured Markdown.
- Localized in English and Brazilian Portuguese.
- Includes a privacy manifest and does not include analytics or tracking SDKs.

## Requirements

- macOS with Xcode installed.
- Xcode 16 or newer. The project has been opened with Xcode 26.5.
- iOS 17.0 or newer.
- An iOS simulator or a physical iPhone/iPad.
- Optional: an OpenAI API key for Whisper transcription and OpenAI summaries.
- Optional: an Anthropic API key for Claude summaries.

## Getting Started

1. Open `MeetSync.xcodeproj` in Xcode.
2. Select the `MeetSync` scheme.
3. Choose an iOS simulator or a connected device.
4. Press `Cmd + R` to build and run.
5. Grant microphone permission when prompted.
6. Grant speech recognition permission if you use on-device transcription.
7. Open Settings in the app to choose the default transcription mode, language,
   AI provider, and API keys.

The app icon is currently a placeholder. Replace
`MeetSync/Assets.xcassets/AppIcon.appiconset` before distribution.

## Running In The Simulator

In Xcode:

1. Use the device picker in the toolbar.
2. Select an iPhone simulator, such as `iPhone 16 Pro`.
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
  -project MeetSync.xcodeproj \
  -scheme MeetSync \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  build
```

## Running Tests

Unit tests live in the `MeetSyncTests` target and use Swift Testing. They cover
pure logic such as JSON parsing, Markdown export, SwiftData model helpers, and
view model behavior against an in-memory `ModelContainer`. The Keychain-backed
provider tests touch the real Simulator keychain and restore whatever was
already stored when they finish.

Run them from Xcode with `Cmd + U`, or from the terminal:

```bash
xcodebuild \
  -project MeetSync.xcodeproj \
  -scheme MeetSync \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  test
```

## Configuration

MeetSync can work without cloud credentials when using on-device transcription.
Cloud transcription and AI summaries require user-provided API keys.

- OpenAI key: used for Whisper transcription and OpenAI summaries.
- Anthropic key: used for Claude summaries.
- API keys are stored in the Keychain.
- Non-secret preferences are stored in `UserDefaults`.

Default app preferences are managed in:

`MeetSync/Infrastructure/AppSettings.swift`

Provider setup is handled through:

`MeetSync/Providers/ProviderFactory.swift`

## Privacy

MeetSync is designed to avoid a backend service.

- Audio files are saved locally in the app's documents directory.
- Meeting metadata, transcripts, summaries, speakers, and recordings are stored
  locally with SwiftData.
- API keys are stored in the Keychain.
- Network requests are only made when the user selects a cloud transcription or
  summary feature.
- No analytics or tracking SDKs are included.

## Architecture

The app follows an MVVM-style structure with `@Observable`, `@MainActor` view
models, and async service APIs.

```text
MeetSync/
├── MeetSyncApp.swift            # App entry point and SwiftData container
├── ContentView.swift            # Root NavigationStack
├── Models/                      # SwiftData @Model types and enums
├── Views/                       # SwiftUI screens and reusable views
├── ViewModels/                  # Main-actor observable coordinators
├── Services/                    # Audio, transcription, diarization, summaries
├── Providers/                   # OpenAI and Anthropic URLSession clients
├── Infrastructure/              # Keychain, errors, settings, export, extensions
├── Resources/                   # Localizations and privacy manifest
└── Assets.xcassets/             # App icon and accent color
```

## Important Implementation Notes

- Cloud transcription always uses OpenAI Whisper.
- Summaries can use OpenAI or Anthropic.
- Speaker diarization is heuristic and approximate by design.
- On-device transcription availability depends on Apple's Speech framework,
  simulator/device support, and the selected language.
- Background audio recording is enabled through `UIBackgroundModes`.
- The app uses a checked-in `Info.plist` instead of generated build settings.

## Development Notes

Useful files:

- `MeetSync/Services/AudioRecorderService.swift`
- `MeetSync/Services/TranscriptionService.swift`
- `MeetSync/Services/SummaryService.swift`
- `MeetSync/Services/SpeakerDiarizer.swift`
- `MeetSync/Views/SettingsView.swift`
- `MeetSync/Infrastructure/MeetingExport.swift`

Before shipping:

- Replace the placeholder app icon.
- Confirm the bundle identifier and signing team.
- Test recording on a physical device.
- Test microphone, speech recognition, and network permission flows.
- Validate export output with real meeting data.
