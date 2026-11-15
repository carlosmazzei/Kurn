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

/// A finite background-execution window. The seam lets an owner's policy (what to
/// do when the window expires) be tested without UIKit granting real time.
@MainActor
protocol BackgroundExecutionWindow: AnyObject {
    func begin(name: String, onExpiration: (@MainActor @Sendable () -> Void)?)
    func end()
}

/// When an owner should start winding down: early enough that its own clean-up
/// (awaiting cancellation, saving state) still runs inside the granted window.
/// The system's expiration handler is too late for that — the task must end
/// inside it and the process is suspended right after.
struct BackgroundDeadline: Equatable {
    /// Seconds of background time an owner reserves for winding down.
    static let windDownLead: TimeInterval = 8

    /// True once the remaining background time no longer covers the wind-down.
    /// A foreground app reports `greatestFiniteMagnitude`, which never qualifies.
    static func shouldWindDown(remaining: TimeInterval, lead: TimeInterval = windDownLead) -> Bool {
        remaining <= lead
    }
}

/// One-shot wrapper around `UIApplication.beginBackgroundTask`. Begin it before
/// the work, end it (idempotently) when the work finishes; the expiration handler
/// ends it defensively if the system reclaims the time first.
@MainActor
final class BackgroundActivity: BackgroundExecutionWindow {
    #if canImport(UIKit)
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var watcher: Task<Void, Never>?
    #endif

    /// Request background execution time. No-op if already active or unavailable.
    /// - Parameter onExpiration: invoked (on the main actor) once the remaining
    ///   background time drops to `BackgroundDeadline.windDownLead`, while the
    ///   window is still held, so the owner can stop and save cleanly; it is
    ///   invoked again (the owner must tolerate that) from the system's own
    ///   expiration handler if the time runs out first.
    func begin(name: String, onExpiration: (@MainActor @Sendable () -> Void)? = nil) {
        #if canImport(UIKit)
        guard taskID == .invalid else { return }
        taskID = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // The system is about to reclaim the time; release it cleanly so it
            // doesn't kill the app for overrunning.
            AppLog.transcription.atNotice.notice("background activity expired: \(name, privacy: .public)")
            onExpiration?()
            self?.end()
        }
        if let onExpiration {
            watcher = Task { @MainActor in
                while !Task.isCancelled {
                    if BackgroundDeadline.shouldWindDown(remaining: UIApplication.shared.backgroundTimeRemaining) {
                        AppLog.transcription.atNotice.notice("background activity winding down: \(name, privacy: .public)")
                        onExpiration()
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        AppLog.transcription.atDebug.debug("background activity begin: \(name, privacy: .public)")
        #endif
    }

    /// Release the background time. Safe to call more than once.
    func end() {
        #if canImport(UIKit)
        watcher?.cancel()
        watcher = nil
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
        #endif
    }
}
