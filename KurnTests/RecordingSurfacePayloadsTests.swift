//
//  RecordingSurfacePayloadsTests.swift
//  KurnTests
//
//  The wire contract between the recorder and its glanceable surfaces: the
//  Live Activity's content state, the Watch application context, and how a
//  Watch command is decoded and answered. ActivityKit and WCSession cannot be
//  driven from a test, so the controllers that call them only hand these
//  values over; the `KurnWatch` copy of the keys must keep matching them.
//

import Foundation
import Testing
@testable import Kurn

struct RecordingSurfacePayloadsTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Live Activity

    @Test func onlyAnActiveRecordingReadsAsRunning() {
        let recording = RecordingSurfacePayloads.activityState(for: .recording, elapsed: 12, highlightCount: 2, now: now)
        #expect(recording == RecordingActivityAttributes.ContentState(
            isPaused: false, elapsed: 12, referenceDate: now, highlightCount: 2
        ))
        #expect(RecordingSurfacePayloads.activityState(for: .paused, elapsed: 0, highlightCount: 0, now: now).isPaused)
        #expect(RecordingSurfacePayloads.activityState(for: .idle, elapsed: 0, highlightCount: 0, now: now).isPaused)
    }

    // MARK: - Watch context

    @Test func recorderStatesMapToTheWatchVocabulary() {
        #expect(RecordingSurfacePayloads.watchState(.idle) == WatchSessionState.idle)
        #expect(RecordingSurfacePayloads.watchState(.recording) == WatchSessionState.recording)
        #expect(RecordingSurfacePayloads.watchState(.paused) == WatchSessionState.paused)
    }

    @Test func contextCarriesEveryKeyTheWatchReads() {
        let context = RecordingSurfacePayloads.watchContext(
            state: .paused,
            meetingTitle: "Recording",
            accumulatedElapsed: 42,
            referenceDate: now,
            isAvailable: true,
            highlightCount: 3
        )
        #expect(context.count == 6)
        #expect(context[WatchSessionKey.state] as? String == WatchSessionState.paused)
        #expect(context[WatchSessionKey.meetingTitle] as? String == "Recording")
        #expect(context[WatchSessionKey.accumulatedElapsed] as? TimeInterval == 42)
        #expect(context[WatchSessionKey.referenceDate] as? Date == now)
        #expect(context[WatchSessionKey.isAvailable] as? Bool == true)
        #expect(context[WatchSessionKey.highlightCount] as? Int == 3)
    }

    @Test func endedContextClearsEverything() {
        let context = RecordingSurfacePayloads.endedWatchContext(now: now)
        #expect(context[WatchSessionKey.state] as? String == WatchSessionState.idle)
        #expect(context[WatchSessionKey.meetingTitle] as? String == "")
        #expect(context[WatchSessionKey.accumulatedElapsed] as? TimeInterval == 0)
        #expect(context[WatchSessionKey.referenceDate] as? Date == now)
        #expect(context[WatchSessionKey.isAvailable] as? Bool == false)
        #expect(context[WatchSessionKey.highlightCount] as? Int == 0)
    }

    // MARK: - Watch commands

    @Test func decodesEveryKnownCommandWithItsID() {
        for command in [WatchCommand.pause, .resume, .stop, .highlight] {
            let decoded = RecordingSurfacePayloads.decodeCommand([
                WatchSessionKey.command: command.rawValue,
                WatchSessionKey.commandID: "id-1"
            ])
            #expect(decoded == RecordingSurfacePayloads.DecodedCommand(command: command, commandID: "id-1"))
        }
    }

    @Test func missingCommandIDGetsAFreshOne() {
        let decoded = RecordingSurfacePayloads.decodeCommand(
            [WatchSessionKey.command: WatchCommand.stop.rawValue],
            freshID: { "fresh" }
        )
        #expect(decoded == RecordingSurfacePayloads.DecodedCommand(command: .stop, commandID: "fresh"))
        let defaultID = RecordingSurfacePayloads.decodeCommand([WatchSessionKey.command: "pause"])?.commandID
        #expect(defaultID.flatMap(UUID.init(uuidString:)) != nil)
    }

    @Test func unknownOrMalformedCommandsAreRejected() {
        #expect(RecordingSurfacePayloads.decodeCommand([:]) == nil)
        #expect(RecordingSurfacePayloads.decodeCommand([WatchSessionKey.command: "rewind"]) == nil)
        #expect(RecordingSurfacePayloads.decodeCommand([WatchSessionKey.command: 7]) == nil)
    }

    @Test func unknownCommandReplyIsAReceivedFailure() {
        let reply = RecordingSurfacePayloads.unknownCommandReply()
        #expect(reply[WatchSessionKey.ok] as? Bool == false)
        #expect(reply[WatchSessionKey.error] as? String == WatchSessionReplyError.unknownCommand)
        #expect(reply[WatchSessionKey.ackPhase] as? String == WatchAckPhase.received.rawValue)
    }

    @Test func handledReplyCarriesOnlySuccessAndPhase() {
        let reply = RecordingSurfacePayloads.commandReply(handled: true, phase: .finalized)
        #expect(reply.count == 2)
        #expect(reply[WatchSessionKey.ok] as? Bool == true)
        #expect(reply[WatchSessionKey.ackPhase] as? String == WatchAckPhase.finalized.rawValue)
    }

    @Test func unhandledReplyReportsNoActiveRecording() {
        let reply = RecordingSurfacePayloads.commandReply(handled: false, phase: .received)
        #expect(reply[WatchSessionKey.ok] as? Bool == false)
        #expect(reply[WatchSessionKey.error] as? String == WatchSessionReplyError.noActiveRecording)
        #expect(reply[WatchSessionKey.ackPhase] as? String == WatchAckPhase.received.rawValue)
    }
}
