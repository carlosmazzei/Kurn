//
//  StartRecordingIntent.swift
//  Kurn
//
//  Compiled into both the Kurn and KurnLiveActivityExtension targets (see
//  `RecordingActivityAttributes.swift` for the same dual-membership pattern),
//  so the Control Center/Lock Screen control defined in the extension can
//  reference this intent directly in its button configuration.
//
//  `openAppWhenRun = true` means the system always launches/foregrounds the
//  app before calling `perform()`, so the intent body always *executes*
//  inside the main app process, never the extension's — but Swift still needs
//  a full, self-contained definition of this type to compile into whichever
//  target references it. That is why `perform()` only posts a plain
//  `Notification` (Foundation, available identically in both targets) rather
//  than reaching into `RecordingLauncher` or any other Kurn-target-only type
//  directly: doing that would drag `RecordingLauncher`'s whole dependency
//  chain (`MeetingsViewModel`, `Meeting`, `AppSettings`, SwiftData) into the
//  widget extension just to satisfy the compiler. `RecordingLauncher` listens
//  for the notification once it is actually running in the app process.
//

import AppIntents
import Foundation

extension Notification.Name {
    static let kurnStartRecordingRequested = Notification.Name("ai.kurn.app.startRecordingRequested")
}

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "intent.startRecording.title"
    static var description = IntentDescription("intent.startRecording.description")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .kurnStartRecordingRequested, object: nil)
        return .result()
    }
}

struct KurnShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording in \(.applicationName)",
                "\(.applicationName) start recording"
            ],
            shortTitle: "intent.startRecording.shortTitle",
            systemImageName: "record.circle.fill"
        )
    }
}
