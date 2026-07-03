# Contributing to Kurn

Thanks for considering a contribution to Kurn! This guide explains how to
report issues, propose changes, and submit pull requests so they fit the
project's conventions.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to contribute

- **Report a bug** — open a [bug report](.github/ISSUE_TEMPLATE/bug_report.yml)
  with reproduction steps, expected vs. observed behavior, and device/OS info.
- **Suggest a feature** — open a
  [feature request](.github/ISSUE_TEMPLATE/feature_request.yml) describing the
  use case and why on-device or local-first matters for it.
- **Improve documentation** — README, docs, comments, or localization strings
  are all welcome.
- **Submit code** — see "Development workflow" and "Pull requests" below.
- **Translate** — Kurn ships with English and Brazilian Portuguese. New
  localizations are welcome; see "Localization".

If you plan to send a substantial change (new screen, new service, new
provider, refactor across modules), please open an issue first to discuss the
approach so effort is not wasted.

## Reporting security issues

Please **do not** open a public issue for security vulnerabilities. Follow
the process in [SECURITY.md](SECURITY.md) instead.

## Requirements

Kurn is an iOS + watchOS app built with Swift 6, SwiftUI, and SwiftData.
Building and testing requires Apple's toolchain.

- macOS with Xcode 16 or newer (the project has been opened with Xcode 26.5).
- iOS 17.0+ simulator or device for the main app.
- watchOS 10.0+ simulator or a paired Apple Watch for the watchOS target.
- [SwiftLint](https://github.com/realm/SwiftLint) for local linting
  (`brew install swiftlint`).

If `xcodebuild` or SwiftLint cannot find SourceKit, point the toolchain at
Xcode:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Development workflow

1. **Fork** the repository on GitHub and clone your fork.
2. **Create a branch** from `main` with a descriptive name, e.g.
   `feature/whisper-retry`, `fix/watch-pause-state`, `docs/contributing`.
3. **Open `Kurn.xcodeproj` in Xcode** and pick the `Kurn` scheme (or
   `KurnWatch` / `KurnLiveActivityExtension` when working on those targets).
4. **Make focused changes.** Avoid unrelated refactors in the same PR.
5. **Run lint, build, and tests locally** before pushing.
6. **Push** your branch to your fork and open a pull request against `main`.

### Build, lint, and test commands

```bash
# Lint (must pass before build in CI)
swiftlint lint --config .swiftlint.yml

# Build
xcodebuild -project Kurn.xcodeproj -scheme Kurn \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# Run all tests (Swift Testing, not XCTest)
xcodebuild -project Kurn.xcodeproj -scheme Kurn \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

# Run a single test suite
xcodebuild -project Kurn.xcodeproj -scheme Kurn \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:KurnTests/SummaryJSONParsingTests
```

Substitute another installed simulator name if `iPhone 17` is unavailable
locally. CI uses `iPhone 17` (see `.github/workflows/swift.yml`).

## Project layout and architecture

The high-level structure and architectural conventions are described in the
[README](README.md#architecture). Key things to keep in mind while changing
code:

- **MVVM** — `@Observable` `@MainActor` view models own services and persist
  results; SwiftUI views stay thin.
- **Services are value types and `Sendable`** so they can run off the main
  actor. Anything touching SwiftData or UI must be `@MainActor`.
- **Single SwiftData `ModelContainer`** lives at the app root. `Meeting` is the
  aggregate root and cascades deletes.
- **No arbitrary `Codable` arrays in SwiftData.** Encode them as JSON `Data`
  through computed properties (see `Transcript.segmentsData`).
- **Relationships are set by assigning the parent** (e.g. `Recording(meeting:)`),
  not by appending to the parent collection — SwiftData maintains the inverse.
- **Providers** go behind the `LLMProvider` protocol and are resolved through
  `ProviderFactory`. Cloud transcription always uses OpenAI Whisper.
- **The watchOS target does not share source files with the app.** Types like
  `WatchCommand` are intentionally duplicated in `KurnWatch/`; keep both copies
  in sync when you change one.

## Coding conventions

- **Swift 6 strict concurrency.** Respect actor isolation; do not paper over
  warnings with `@unchecked Sendable` unless you can justify it.
- **SwiftLint must pass.** Limits worth knowing: file length warns at 600
  lines, function body at 120, cyclomatic complexity at 15, type body at 400.
  Split files or extract helpers instead of adding `// swiftlint:disable`.
- **Errors:** surface recoverable failures as `AppError`
  (`Kurn/Infrastructure/AppError.swift`), a `LocalizedError` whose messages
  come from `NSLocalizedString`. New error cases must add a matching
  localization key.
- **Logging:** use `AppLog.<category>` (subsystem `ai.kurn.app`) and pick the
  severity per call site — `.debug` for high-frequency traces, `.info` for
  details, `.notice` for lifecycle milestones, `.error` / `.fault` for
  failures. Mark interpolated values `privacy:` explicitly.
- **Secrets never go in `UserDefaults`.** API keys live in the Keychain via
  `KeychainManager`. Non-secret preferences live in `AppSettings`.
- **Comments:** prefer self-explanatory code. Only add a comment when the
  *why* is non-obvious (a hidden constraint, a workaround, a subtle
  invariant).

## Localization

User-facing strings are localized through `NSLocalizedString`. Kurn ships
English (`en`) and Brazilian Portuguese (`pt-BR`) under `Kurn/Resources/`.

- When you add or change a user-facing string, update **all** existing
  localizations. Do not leave keys out of sync.
- `displayName` on enums is the localization seam — keep it as the only way to
  surface enum cases to the user.
- New languages are welcome. Add a new `.lproj` directory under
  `Kurn/Resources/`, translate the string tables, and note it in the PR.

## Tests

- Tests live in the `KurnTests` target and use **Swift Testing** (`@Test`,
  `#expect`) — not XCTest.
- Use `TestModelContainer.make()` for an in-memory `ModelContainer` when
  exercising real SwiftData relationship behavior.
- New behavior should come with tests when it is reasonable to test it
  (parsing, formatting, model helpers, view-model logic).
- Avoid network in tests. Provider tests should exercise request construction
  and response parsing, not real HTTP calls.

## Commits

- Write commit messages in **English**, regardless of the language used to
  discuss the change.
- Use the imperative mood ("Add Whisper retry", "Fix watch pause state"), keep
  the subject under ~72 characters, and add a body when the *why* needs
  context.
- Group related changes into one commit; split unrelated changes across
  separate commits when possible.

## Pull requests

- Write PR titles and descriptions in **English**.
- Target `main`. Keep the PR focused — one logical change per PR.
- Fill in the [PR template](.github/PULL_REQUEST_TEMPLATE.md): summary,
  motivation, screenshots/recordings for UI changes, and a test plan.
- Link related issues (`Fixes #123`, `Refs #456`).
- Make sure the `iOS CI` workflow passes. It builds, lints, and runs the full
  test suite on macOS.
- Be ready to iterate on review. Push follow-up commits to the same branch
  rather than force-pushing rebases unless asked.

## Releasing

Cutting a release (version bump, git tag, GitHub Release) is a maintainer-only
task — contributors don't need to touch versioning in regular PRs. See
[README.md#releasing](README.md#releasing) for the process.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE) that covers the project. If your change pulls in a new
third-party dependency or model, update
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) with its attribution and
license, and confirm the license is compatible with MIT distribution.
