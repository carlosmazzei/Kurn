//
//  BackgroundActivity.swift
//  Kurn
//
//  Requests a finite window of background execution time from the system so a
//  long-running task — chiefly transcribing a long recording — isn't suspended
//  the instant the app leaves the foreground. Without this, iOS suspends the app
//  a few seconds after it backgrounds, which aborts any in-flight transcription
//  and surfaces a failure. The granted window is finite (the system decides how
//  long), so this is a best-effort buffer, not a guarantee the work completes in
//  the background.
//

#if canImport(UIKit)
import UIKit
#endif

/// One-shot wrapper around `UIApplication.beginBackgroundTask`. Begin it before
/// the work, end it (idempotently) when the work finishes; the expiration handler
/// ends it defensively if the system reclaims the time first.
@MainActor
final class BackgroundActivity {
    #if canImport(UIKit)
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// Request background execution time. No-op if already active or unavailable.
    func begin(name: String) {
        #if canImport(UIKit)
        guard taskID == .invalid else { return }
        taskID = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // The system is about to reclaim the time; release it cleanly so it
            // doesn't kill the app for overrunning.
            AppLog.transcription.log("background activity expired: \(name, privacy: .public)")
            self?.end()
        }
        AppLog.transcription.log("background activity begin: \(name, privacy: .public)")
        #endif
    }

    /// Release the background time. Safe to call more than once.
    func end() {
        #if canImport(UIKit)
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
        #endif
    }
}
