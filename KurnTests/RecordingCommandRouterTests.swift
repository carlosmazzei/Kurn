//
//  RecordingCommandRouterTests.swift
//  KurnTests
//
//  H8 PR 20: `RecordingCommandRouter.handleWatchCommand` gained two things —
//  a `commandID`-keyed dedup cache, so a redelivered duplicate (the watch
//  retrying after a lost reply) replays the cached outcome instead of
//  pausing/stopping/highlighting a second time for one user action, and a
//  `WatchAckPhase` reply distinguishing "received" (no session to act on),
//  "state changed" (the handler ran), and "finalized" (a `stop` whose
//  recording was durably saved). Both are pure `@MainActor` state on the
//  router itself, so — unlike ActivityKit or real `WCSession` traffic —
//  they're directly testable with no simulator/device dependency.
//
//  Uses `.serialized`, matching `RecordingLauncherTests`: `.shared` is a
//  real process-wide singleton other test files also register handlers on.
//

import Testing
import UIKit
@testable import Kurn

@MainActor
@Suite(.serialized)
struct RecordingCommandRouterTests {

    @Test func duplicateCommandIDReplaysCachedResultWithoutReinvokingHandler() {
        let router = RecordingCommandRouter.shared
        defer { router.unregister() }
        var highlightCount = 0
        router.register(
            onTogglePause: {}, onPause: {}, onResume: {},
            onStop: { true },
            onHighlight: { highlightCount += 1 }
        )

        let first = router.handleWatchCommand(.highlight, commandID: "duplicate-id")
        let replay = router.handleWatchCommand(.highlight, commandID: "duplicate-id")

        #expect(first.handled)
        #expect(first.phase == .stateChanged)
        #expect(replay.handled == first.handled)
        #expect(replay.phase == first.phase)
        // The handler itself only ran once — the replay didn't mark a
        // second highlight.
        #expect(highlightCount == 1)
    }

    @Test func distinctCommandIDsAreNotTreatedAsDuplicates() {
        let router = RecordingCommandRouter.shared
        defer { router.unregister() }
        var highlightCount = 0
        router.register(
            onTogglePause: {}, onPause: {}, onResume: {}, onStop: { true },
            onHighlight: { highlightCount += 1 }
        )

        _ = router.handleWatchCommand(.highlight, commandID: "id-1")
        _ = router.handleWatchCommand(.highlight, commandID: "id-2")

        #expect(highlightCount == 2)
    }

    @Test func stopReportsFinalizedWhenTheHandlerConfirmsDurableSave() {
        let router = RecordingCommandRouter.shared
        defer { router.unregister() }
        router.register(onTogglePause: {}, onPause: {}, onResume: {}, onStop: { true }, onHighlight: {})

        let result = router.handleWatchCommand(.stop, commandID: "stop-finalized")

        #expect(result.handled)
        #expect(result.phase == .finalized)
    }

    @Test func stopReportsStateChangedWhenTheHandlerDidNotCleanlyFinalize() {
        let router = RecordingCommandRouter.shared
        defer { router.unregister() }
        router.register(onTogglePause: {}, onPause: {}, onResume: {}, onStop: { false }, onHighlight: {})

        let result = router.handleWatchCommand(.stop, commandID: "stop-recovery-needed")

        #expect(result.handled)
        #expect(result.phase == .stateChanged)
    }

    @Test func commandWithNoActiveSessionReportsReceivedOnly() {
        RecordingCommandRouter.shared.unregister()

        let result = RecordingCommandRouter.shared.handleWatchCommand(.pause, commandID: "no-session")

        #expect(!result.handled)
        #expect(result.phase == .received)
    }

    @Test func unregisterClearsTheDedupCache() {
        let router = RecordingCommandRouter.shared
        var highlightCount = 0
        router.register(
            onTogglePause: {}, onPause: {}, onResume: {}, onStop: { true },
            onHighlight: { highlightCount += 1 }
        )
        _ = router.handleWatchCommand(.highlight, commandID: "reused-id")
        router.unregister()

        // A new recorder session reusing the same commandID (astronomically
        // unlikely with a real UUID, but the cache shouldn't rely on that)
        // must not be treated as a leftover duplicate from the torn-down
        // session.
        router.register(
            onTogglePause: {}, onPause: {}, onResume: {}, onStop: { true },
            onHighlight: { highlightCount += 1 }
        )
        defer { router.unregister() }
        _ = router.handleWatchCommand(.highlight, commandID: "reused-id")

        #expect(highlightCount == 2)
    }

    // MARK: - Watch .start

    @Test func startWhileARecordingIsActiveIsRefused() {
        let router = RecordingCommandRouter.shared
        defer { router.unregister() }
        var starts = 0
        router.requestStart = { starts += 1; return true }
        router.register(
            onTogglePause: {}, onPause: {}, onResume: {},
            onStop: { true }, onHighlight: {}
        )

        let result = router.handleWatchCommand(.start, commandID: "start-busy")

        #expect(!result.handled)
        #expect(result.phase == .received)
        #expect(result.error == WatchSessionReplyError.recordingAlreadyActive)
        #expect(starts == 0)
    }

    @Test func startInTheForegroundQueuesARecordingImmediately() {
        let router = RecordingCommandRouter.shared
        router.unregister()
        defer { router.unregister() }
        var starts = 0
        router.isForeground = { true }
        router.requestStart = { starts += 1; return true }

        let result = router.handleWatchCommand(.start, commandID: "start-fg")

        #expect(result.handled)
        #expect(result.phase == .stateChanged)
        #expect(starts == 1)
    }

    /// When no presenter wired `requestStart` (or it refuses) the reply is
    /// "received" with the no-active-recording error — never `.queued`.
    @Test func startIsRefusedWhenRequestStartFails() {
        let router = RecordingCommandRouter.shared
        router.unregister()
        defer { router.unregister() }
        router.requestStart = { false }

        let result = router.handleWatchCommand(.start, commandID: "start-unwired")

        #expect(!result.handled)
        #expect(result.phase == .received)
        #expect(result.error == WatchSessionReplyError.noActiveRecording)
    }

    /// `.queued` is true in practice: `RecordingSessionPresenter` consumes
    /// the queued meeting only once `scenePhase` becomes `.active`.
    @Test func startWhileBackgroundedReportsQueued() {
        let router = RecordingCommandRouter.shared
        router.unregister()
        defer { router.unregister() }
        router.isForeground = { false }
        router.requestStart = { true }

        let result = router.handleWatchCommand(.start, commandID: "start-bg")

        #expect(result.handled)
        #expect(result.phase == .queued)
        #expect(result.error == nil)
    }

    // MARK: - Live Activity buttons

    @Test func liveActivityActionsReachTheMatchingHandler() {
        let router = RecordingCommandRouter.shared
        defer { router.unregister() }
        var calls: [String] = []
        router.register(
            onTogglePause: { calls.append("toggle") }, onPause: {}, onResume: {},
            onStop: { calls.append("stop"); return true },
            onHighlight: { calls.append("highlight") }
        )

        for action in RecordingControlAction.allCases {
            let handled = router.handle(action)
            #expect(handled)
        }

        #expect(calls == ["toggle", "stop", "highlight"])
    }

    @Test func liveActivityActionsWithoutASessionAreIgnored() {
        let router = RecordingCommandRouter.shared
        router.unregister()
        for action in RecordingControlAction.allCases {
            let handled = router.handle(action)
            #expect(!handled)
        }
        #expect(!router.hasActiveSession)
    }

    // MARK: - App termination

    @Test func appTerminationStopsAndSavesTheLiveRecording() {
        let router = RecordingCommandRouter.shared
        defer { router.unregister() }
        var stops = 0
        router.register(
            onTogglePause: {}, onPause: {}, onResume: {},
            onStop: { stops += 1; return true },
            onHighlight: {}
        )

        NotificationCenter.default.post(name: UIApplication.willTerminateNotification, object: nil)

        #expect(stops == 1)
    }

    @Test func appTerminationAfterTheSessionEndedDoesNothing() {
        let router = RecordingCommandRouter.shared
        var stops = 0
        router.register(
            onTogglePause: {}, onPause: {}, onResume: {},
            onStop: { stops += 1; return true },
            onHighlight: {}
        )
        router.unregister()

        NotificationCenter.default.post(name: UIApplication.willTerminateNotification, object: nil)
        router.stopForTermination()

        #expect(stops == 0)
    }
}
