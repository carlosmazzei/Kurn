//
//  RecordingSinkFaultTests.swift
//  KurnTests
//
//  Exercises H1's fault seams without a microphone: the real `RecordingSink`
//  latches a scripted writer failure and metrics, while the injected sink drives
//  `AudioRecorderService`'s write and final-drain reporting paths. Starting a real
//  `AVAudioEngine` session still belongs to the device matrix rather than CI.
//

import AVFoundation
import Foundation
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
        #expect(sink.snapshot.firstFailure == .write)
        #expect(sink.snapshot.attemptedInputFrames == 256)
        #expect(sink.snapshot.writtenOutputFrames == 128)
    }

    @Test func recordingSinkLatchesTheFirstWriterFailureAndMetrics() throws {
        let buffer = try Self.makeBuffer()
        let converter = try #require(AVAudioConverter(from: buffer.format, to: buffer.format))
        let writer = ScriptedAudioFileWriter(failFromWrite: 2)
        let timestamp = Date(timeIntervalSince1970: 42)
        let sink = RecordingSink(now: { timestamp })
        var callbackCount = 0
        sink.open(writer, converter: converter, targetFormat: buffer.format) { _ in
            callbackCount += 1
        }

        #expect(sink.write(buffer))
        #expect(!sink.write(buffer))
        #expect(!sink.write(buffer))

        let snapshot = sink.snapshot
        #expect(snapshot.firstFailure == .write)
        #expect(snapshot.attemptedInputFrames == 192)
        #expect(snapshot.writtenOutputFrames > 0)
        #expect(snapshot.lastSuccessfulWriteAt == timestamp)
        #expect(writer.writeCount == 2)
        #expect(callbackCount == 1)
    }

    @Test func captureWatchdogWaitsForItsDeadline() {
        var watchdog = CaptureProgressWatchdog(stallInterval: 2)

        let initial = watchdog.hasStalled(writtenFrames: 0, now: 10)
        let beforeDeadline = watchdog.hasStalled(writtenFrames: 0, now: 11.99)
        let atDeadline = watchdog.hasStalled(writtenFrames: 0, now: 12)

        #expect(!initial)
        #expect(!beforeDeadline)
        #expect(atDeadline)
    }

    @Test func captureWatchdogResetsItsDeadlineAfterProgress() {
        var watchdog = CaptureProgressWatchdog(stallInterval: 2)

        let initial = watchdog.hasStalled(writtenFrames: 0, now: 10)
        let progressed = watchdog.hasStalled(writtenFrames: 64, now: 11.5)
        let beforeNewDeadline = watchdog.hasStalled(writtenFrames: 64, now: 13.49)
        let atNewDeadline = watchdog.hasStalled(writtenFrames: 64, now: 13.5)

        #expect(!initial)
        #expect(!progressed)
        #expect(!beforeNewDeadline)
        #expect(atNewDeadline)
    }

    @Test func captureWatchdogTreatsACounterResetAsProgress() {
        var watchdog = CaptureProgressWatchdog(stallInterval: 2)

        let initial = watchdog.hasStalled(writtenFrames: 64, now: 10)
        let reset = watchdog.hasStalled(writtenFrames: 0, now: 20)
        let beforeNewDeadline = watchdog.hasStalled(writtenFrames: 0, now: 21.99)
        let atNewDeadline = watchdog.hasStalled(writtenFrames: 0, now: 22)

        #expect(!initial)
        #expect(!reset)
        #expect(!beforeNewDeadline)
        #expect(atNewDeadline)
    }

    @Test @MainActor func audioRecorderServiceSurfacesAFrameProgressStall() {
        let recorder = AudioRecorderService(sink: FakeAudioSinkWriting(), stallInterval: 2)
        let snapshot = AudioSinkSnapshot(writtenOutputFrames: 0)

        let initial = recorder.pollCaptureProgress(snapshot: snapshot, now: 10)
        let beforeDeadline = recorder.pollCaptureProgress(snapshot: snapshot, now: 11.99)
        let atDeadline = recorder.pollCaptureProgress(snapshot: snapshot, now: 12)
        let duplicate = recorder.pollCaptureProgress(snapshot: snapshot, now: 13)

        #expect(!initial)
        #expect(!beforeDeadline)
        #expect(atDeadline)
        #expect(!duplicate)
        #expect(recorder.captureFailure == .stalled)
        #expect(recorder.routeChangeMessage != nil)
    }

    @Test @MainActor func audioRecorderServiceSurfacesAnInjectedSinkFailure() throws {
        let sink = FakeAudioSinkWriting()
        let recorder = AudioRecorderService(sink: sink)
        let buffer = try Self.makeBuffer()
        sink.failWrites(fromCall: 1)
        #expect(!sink.write(buffer))

        #expect(recorder.pollSinkStatus())
        #expect(recorder.captureFailure == .write)
        #expect(recorder.routeChangeMessage != nil)
        #expect(!recorder.pollSinkStatus())
    }

    @Test @MainActor func audioRecorderServiceSurfacesAnInjectedFinalDrainFailure() {
        let sink = FakeAudioSinkWriting()
        let recorder = AudioRecorderService(sink: sink)
        sink.failOnClose()
        sink.close()

        #expect(recorder.pollSinkStatus())
        #expect(recorder.captureFailure == .finalDrain)
        #expect(recorder.routeChangeMessage != nil)
    }

    @Test @MainActor func audioRecorderServiceAcceptsAnInjectedSink() {
        let sink = FakeAudioSinkWriting()
        let recorder = AudioRecorderService(sink: sink)
        #expect(recorder.state == .idle)
    }
}

private final class ScriptedAudioFileWriter: AudioFileWriting {
    private let failFromWrite: Int?
    private(set) var writeCount = 0

    init(failFromWrite: Int? = nil) {
        self.failFromWrite = failFromWrite
    }

    func write(from buffer: AVAudioPCMBuffer) throws {
        writeCount += 1
        if let failFromWrite, writeCount >= failFromWrite {
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }
}
