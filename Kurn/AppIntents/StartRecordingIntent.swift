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
    /// H8 PR 20, item 8: posted by `RecordingLauncher` once it has decided
    /// whether the request could actually be queued —
    /// `userInfo["accepted"]` is a `Bool`. `perform()` awaits this (bounded
    /// by a timeout) instead of claiming success the instant the request
    /// notification goes out, so a cold-launch race (the app not finished
    /// configuring `RecordingLauncher` yet) is reported truthfully to
    /// Siri/Shortcuts rather than assumed.
    static let kurnStartRecordingRequestHandled = Notification.Name("ai.kurn.app.startRecordingRequestHandled")
}

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.startRecording.title"
    static let description = IntentDescription("intent.startRecording.description")
    static let openAppWhenRun: Bool = true

    /// How long to wait for `RecordingLauncher` to report whether it could
    /// queue the request before giving up and reporting failure.
    private static let acceptanceTimeout: Duration = .seconds(3)

    /// H8 PR 20, item 8: apply the same "accepted, not actual outcome"
    /// semantics F3 already asks of the Watch/Live Activity controls here —
    /// this only confirms the request was *accepted* (`RecordingLauncher`
    /// was configured and ready to queue a meeting, or recognized one is
    /// already recording, which is a legitimate outcome too), never that a
    /// microphone is now capturing. Actual capture is confirmed later, once
    /// `RecorderView` presents and its own mic-permission flow and
    /// `AudioRecorderService` run; that confirmation surfaces through the
    /// Lock Screen Live Activity, which this intent has no channel back
    /// from and — `openAppWhenRun` notwithstanding — no reliable way to wait
    /// on without risking Siri's own request timeout. What changed from the
    /// old unconditional `.result()`: a cold-launch race, where
    /// `RecordingLauncher.configure()` hasn't run yet when the notification
    /// is posted, used to be silently swallowed and still reported as
    /// success.
    func perform() async throws -> some IntentResult {
        let box = StartRecordingAcceptanceBox()
        let accepted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            box.store(continuation)
            let observer = NotificationCenter.default.addObserver(
                forName: .kurnStartRecordingRequestHandled,
                object: nil,
                queue: .main
            ) { note in
                box.resume(with: (note.userInfo?["accepted"] as? Bool) ?? false)
            }
            box.storeObserver(observer)
            NotificationCenter.default.post(name: .kurnStartRecordingRequested, object: nil)
            Task {
                try? await Task.sleep(for: Self.acceptanceTimeout)
                box.resume(with: false)
            }
        }
        guard accepted else {
            throw StartRecordingIntentError.notReady
        }
        return .result()
    }
}

/// Resumes the acceptance continuation exactly once, whichever of the reply
/// notification or the timeout fires first — the same resume-exactly-once
/// shape `RecorderViewModel.storeMicChoiceContinuation` and this PR's
/// `WatchCommandReplyBox` (`KurnWatch/WatchConnectivityManager.swift`) use
/// for the same class of problem: two independent completion sources racing
/// with no structured-concurrency relationship between them. The observer
/// token lives under the same lock as the continuation (rather than a bare
/// captured `var` shared between the notification callback and the timeout
/// `Task`) so there is exactly one place mutating shared state, not two
/// racing to remove the same observer.
private final class StartRecordingAcceptanceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var observer: NSObjectProtocol?

    func store(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func storeObserver(_ observer: NSObjectProtocol) {
        lock.lock()
        self.observer = observer
        lock.unlock()
    }

    func resume(with result: Bool) {
        lock.lock()
        let toResume = continuation
        let toRemove = observer
        continuation = nil
        observer = nil
        lock.unlock()
        if let toRemove {
            NotificationCenter.default.removeObserver(toRemove)
        }
        toResume?.resume(returning: result)
    }
}

enum StartRecordingIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case notReady

    var localizedStringResource: LocalizedStringResource {
        "intent.startRecording.notReady"
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
