//
//  RecordingSinkFaultTests.swift
//  KurnTests
//
//  Proves the `AudioSinkWriting` seam: (1) a fake conforming to it can record
//  writes and be told to fail from a specific call, and (2) `AudioRecorderService`
//  actually accepts an injected sink instead of always building its own
//  `RecordingSink` — the DI point this seam exists for. Driving a real
//  recording through `AudioRecorderService.start()` needs microphone
//  permission and a live `AVAudioEngine` session, which isn't reliable in CI
//  (see CLAUDE.md's note that the recorder is one of the least-tested
//  surfaces), so this stops short of that; reacting to a write failure is
//  H1's job, not this seam's.
//

import AVFoundation
import Testing
@testable import Kurn

struct RecordingSinkFaultTests {

    private static func makeBuffer() throws -> AVAudioPCMBuffer {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        buffer.frameLength = 64
        return buffer
    }

    @Test func fakeSinkReportsFailureFromTheConfiguredCall() throws {
        let sink = FakeAudioSinkWriting()
        let buffer = try Self.makeBuffer()
        sink.failWrites(fromCall: 3)

        #expect(sink.write(buffer) == true)
        #expect(sink.write(buffer) == true)
        #expect(sink.write(buffer) == false)
        #expect(sink.write(buffer) == false)
        #expect(sink.writesAttempted == 4)
    }

    @Test @MainActor func audioRecorderServiceAcceptsAnInjectedSink() {
        let sink = FakeAudioSinkWriting()
        let recorder = AudioRecorderService(sink: sink)
        #expect(recorder.state == .idle)
    }
}
