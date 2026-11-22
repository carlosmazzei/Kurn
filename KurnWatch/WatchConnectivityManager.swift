//
//  WatchConnectivityManager.swift
//  KurnWatch
//
//  Watch side of the remote control: receives recorder state pushed from the
//  iPhone via WCSession application context, and sends pause/resume/stop
//  commands back. Mirrors PhoneSessionController on the iOS target.
//

import Foundation
import Observation
import WatchConnectivity

enum RemoteRecordingState: Equatable {
    case idle
    case recording(meetingTitle: String, referenceDate: Date, accumulatedElapsed: TimeInterval, highlightCount: Int)
    case paused(meetingTitle: String, accumulatedElapsed: TimeInterval, highlightCount: Int)
}

/// Resumes a `WatchCommand` reply continuation exactly once, whichever of
/// `WCSession`'s replyHandler/errorHandler or the local timeout fires first
/// (H8 PR 20). Mirrors the resume-exactly-once shape
/// `RecorderViewModel.storeMicChoiceContinuation` established for the same
/// class of problem: multiple independent completion sources racing to
/// settle one continuation, with a lock (not actor isolation) guarding it
/// since the callbacks arrive off the main actor.
private final class WatchCommandReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WatchCommandOutcome, Never>?

    func store(_ continuation: CheckedContinuation<WatchCommandOutcome, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with result: WatchCommandOutcome) {
        lock.lock()
        let toResume = continuation
        continuation = nil
        lock.unlock()
        toResume?.resume(returning: result)
    }
}

/// What the phone answered to a command: the `ok` flag plus the lifecycle
/// phase it reached and a failure reason when there is one. Built inside
/// the `sendMessage` reply handler, because the raw `[String: Any]` reply
/// isn't `Sendable` and can't cross into the awaiting task.
struct WatchCommandOutcome: Sendable {
    let ok: Bool
    let phase: WatchAckPhase?
    let error: String?

    static let unreachable = WatchCommandOutcome(ok: false, phase: nil, error: nil)

    init(ok: Bool, phase: WatchAckPhase?, error: String?) {
        self.ok = ok
        self.phase = phase
        self.error = error
    }

    init(_ reply: [String: Any]) {
        ok = (reply[WatchSessionKey.ok] as? Bool) ?? false
        phase = (reply[WatchSessionKey.ackPhase] as? String).flatMap(WatchAckPhase.init(rawValue:))
        error = reply[WatchSessionKey.error] as? String
    }
}

private struct WatchRecordingContext: Sendable {
    let isAvailable: Bool
    let rawState: String
    let meetingTitle: String
    let referenceDate: Date
    let accumulatedElapsed: TimeInterval
    let highlightCount: Int

    init(_ context: [String: Any]) {
        isAvailable = (context[WatchSessionKey.isAvailable] as? Bool) ?? false
        rawState = (context[WatchSessionKey.state] as? String) ?? WatchSessionState.idle
        meetingTitle = (context[WatchSessionKey.meetingTitle] as? String) ?? ""
        referenceDate = (context[WatchSessionKey.referenceDate] as? Date) ?? Date()
        accumulatedElapsed = (context[WatchSessionKey.accumulatedElapsed] as? TimeInterval) ?? 0
        highlightCount = (context[WatchSessionKey.highlightCount] as? Int) ?? 0
    }
}

@MainActor
@Observable
final class WatchConnectivityManager: NSObject {
    private(set) var state: RemoteRecordingState = .idle
    /// True once the iPhone has reported a recording session exists to control.
    private(set) var isAvailable = false
    /// Set when the last command failed to reach the iPhone.
    private(set) var lastCommandFailed = false

    /// Clears the unreachable indicator — e.g. a `.start` the phone refused
    /// because a recording is already running isn't a reachability failure.
    func clearCommandFailure() { lastCommandFailed = false }

    override init() {
        super.init()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("UI-Testing-Screenshots") {
            seedForScreenshot()
            return
        }
        #endif
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    #if DEBUG
    /// Mock "recording in progress" state for App Store screenshot automation
    /// (`KurnWatchUITests`, run via `bundle exec fastlane screenshots`). There is
    /// no paired iPhone during a UI test run, so this bypasses WatchConnectivity
    /// entirely rather than waiting on a session that will never activate.
    private func seedForScreenshot() {
        isAvailable = true
        state = .recording(
            meetingTitle: Self.screenshotMeetingTitle(),
            referenceDate: Date().addingTimeInterval(-642),
            accumulatedElapsed: 0,
            highlightCount: 2
        )
    }

    /// The hero meeting's title in the launch language, matching the iPhone
    /// screenshots' `ScreenshotSeedText.roadmapTitle` (the Watch target does
    /// not share source files with the app, so the titles are repeated here).
    private static func screenshotMeetingTitle(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let titles = [
            "pt": "Alinhamento do roadmap",
            "es": "Revisión del roadmap",
            "fr": "Point roadmap produit",
            "it": "Allineamento roadmap",
            "de": "Produkt-Roadmap-Abstimmung",
            "zh": "产品路线图同步会"
        ]
        for identifier in preferredLanguages {
            let code = identifier.split(separator: "-").first.map { String($0).lowercased() } ?? ""
            if code == "en" { break }
            if let title = titles[code] { return title }
        }
        return "Product Roadmap Sync"
    }
    #endif

    /// How long to wait for the phone's reply before giving up locally (H8
    /// PR 20, item 7's "timeout"). `WCSession.sendMessage`'s own
    /// replyHandler/errorHandler contract isn't a hard guarantee that one of
    /// them always fires promptly — without a local bound, a remote-control
    /// button could spin forever waiting on a phone that never answers.
    private static let commandTimeout: Duration = .seconds(10)

    @discardableResult
    func send(_ command: WatchCommand) async -> Bool {
        await sendWithOutcome(command).ok
    }

    /// Sends a command and returns the phone's full reply — needed by the
    /// `.start` flow, which distinguishes "started now" (`.stateChanged`)
    /// from "queued until the app is foreground" (`.queued`).
    @discardableResult
    func sendWithOutcome(_ command: WatchCommand) async -> WatchCommandOutcome {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
            lastCommandFailed = true
            return .unreachable
        }
        let commandID = UUID().uuidString
        let box = WatchCommandReplyBox()
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<WatchCommandOutcome, Never>) in
            box.store(continuation)
            WCSession.default.sendMessage(
                [WatchSessionKey.command: command.rawValue, WatchSessionKey.commandID: commandID],
                replyHandler: { @Sendable reply in
                    box.resume(with: WatchCommandOutcome(reply))
                },
                errorHandler: { @Sendable _ in
                    box.resume(with: .unreachable)
                }
            )
            Task {
                try? await Task.sleep(for: Self.commandTimeout)
                box.resume(with: .unreachable)
            }
        }
        lastCommandFailed = !outcome.ok
        return outcome
    }

    private func applyContext(_ context: WatchRecordingContext) {
        self.isAvailable = context.isAvailable
        switch context.rawState {
        case WatchSessionState.recording:
            state = .recording(
                meetingTitle: context.meetingTitle,
                referenceDate: context.referenceDate,
                accumulatedElapsed: context.accumulatedElapsed,
                highlightCount: context.highlightCount
            )
        case WatchSessionState.paused:
            state = .paused(
                meetingTitle: context.meetingTitle,
                accumulatedElapsed: context.accumulatedElapsed,
                highlightCount: context.highlightCount
            )
        default:
            state = .idle
        }
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        let context = WatchRecordingContext(session.receivedApplicationContext)
        Task { @MainActor in
            self.applyContext(context)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let context = WatchRecordingContext(applicationContext)
        Task { @MainActor in
            self.applyContext(context)
        }
    }
}
