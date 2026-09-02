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
}
