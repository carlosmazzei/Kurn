//
//  FakeAudioCaptureEngine.swift
//  KurnTests
//
//  A scripted `AudioCaptureEngine`: no microphone, no `AVAudioSession`. Tests
//  set the input format the "hardware" reports, make session configuration or
//  `start()` fail, stop the engine behind the recorder's back (what the system
//  does around lock/unlock) and emit the events a live capture receives.
//

import AVFoundation
import Foundation
@testable import Kurn

final class FakeAudioCaptureEngine: AudioCaptureEngine, @unchecked Sendable {
    enum Call: Equatable {
        case configureSession
        case reactivateSession
        case deactivateSession
        case openOutputFile
        case installTap
        case removeTap
        case disableVoiceProcessing
        case prepare
        case start
        case stop
    }

    struct SessionFailure: Error {}
    struct StartFailure: Error {}

    private let lock = NSLock()
    private var running = false
    private var formats: [AVAudioFormat?]
    private var sessionGate: CheckedContinuation<Void, Never>?
    private var holdingSession = false
    private var tapInstalled = false
    private var sessionFailure: Error?
    private var startFailures = 0
    private var eventHandler: (@Sendable (AudioCaptureEvent) -> Void)?
    private var recordedCalls: [Call] = []

    static let builtInMic = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    static let bluetoothHFP = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    /// `inputFormats` is consumed head-first on every `inputFormat` read; the
    /// last element repeats forever. `nil` is a route that has not negotiated
    /// a format yet.
    init(inputFormats: [AVAudioFormat?] = [FakeAudioCaptureEngine.builtInMic]) {
        formats = inputFormats
    }

    // MARK: Scripting

    func failSessionConfiguration(with error: Error = SessionFailure()) {
        lock.withLock { sessionFailure = error }
    }

    /// The next `count` calls to `start()` throw.
    func failNextStarts(_ count: Int) {
        lock.withLock { startFailures = count }
    }

    /// Replace the format sequence, e.g. after a route change.
    func setInputFormats(_ next: [AVAudioFormat?]) {
        lock.withLock { formats = next }
    }

    /// Make `configureSession` suspend until `releaseSessionConfiguration()`,
    /// so a test can act while `start` is in flight.
    func holdSessionConfiguration() {
        lock.withLock { holdingSession = true }
    }

    func releaseSessionConfiguration() {
        let gate = lock.withLock {
            holdingSession = false
            defer { sessionGate = nil }
            return sessionGate
        }
        gate?.resume()
    }

    /// What the system does to a running engine on a configuration change:
    /// it stops without telling anyone.
    func stopBehindTheRecordersBack() {
        lock.withLock { running = false }
    }

    func emit(_ event: AudioCaptureEvent) {
        let handler = lock.withLock { eventHandler }
        handler?(event)
    }

    var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    func count(_ call: Call) -> Int {
        calls.filter { $0 == call }.count
    }

    var isTapInstalled: Bool {
        lock.withLock { tapInstalled }
    }

    // MARK: AudioCaptureEngine

    var onEvent: (@Sendable (AudioCaptureEvent) -> Void)? {
        get { lock.withLock { eventHandler } }
        set { lock.withLock { eventHandler = newValue } }
    }

    var isRunning: Bool {
        lock.withLock { running }
    }

    var inputFormat: AVAudioFormat? {
        lock.withLock {
            if formats.count > 1 { return formats.removeFirst() }
            return formats[0]
        }
    }

    func configureSession(pickup: MicPickup, forceBuiltIn: Bool, preferredInputUID: String?) async throws {
        let (failure, hold) = lock.withLock {
            recordedCalls.append(.configureSession)
            return (sessionFailure, holdingSession)
        }
        if hold {
            await withCheckedContinuation { continuation in
                let alreadyReleased = lock.withLock {
                    if holdingSession {
                        sessionGate = continuation
                        return false
                    }
                    return true
                }
                if alreadyReleased { continuation.resume() }
            }
        }
        if let failure { throw failure }
    }

    func reactivateSession() {
        lock.withLock { recordedCalls.append(.reactivateSession) }
    }

    func deactivateSession() {
        lock.withLock { recordedCalls.append(.deactivateSession) }
    }

    func openOutputFile(at url: URL, bitRate: Int) throws -> any AudioFileWriting {
        lock.withLock { recordedCalls.append(.openOutputFile) }
        return DiscardingAudioFileWriter()
    }

    func installTap(format: AVAudioFormat, sink: any AudioSinkWriting) {
        lock.withLock {
            recordedCalls.append(.installTap)
            tapInstalled = true
        }
    }

    func removeTap() {
        lock.withLock {
            recordedCalls.append(.removeTap)
            tapInstalled = false
        }
    }

    func disableVoiceProcessing() {
        lock.withLock { recordedCalls.append(.disableVoiceProcessing) }
    }

    func prepare() {
        lock.withLock { recordedCalls.append(.prepare) }
    }

    func start() throws {
        try lock.withLock {
            recordedCalls.append(.start)
            if startFailures > 0 {
                startFailures -= 1
                throw StartFailure()
            }
            running = true
        }
    }

    func stop() {
        lock.withLock {
            recordedCalls.append(.stop)
            running = false
        }
    }
}

private final class DiscardingAudioFileWriter: AudioFileWriting {
    func write(from buffer: AVAudioPCMBuffer) throws {}
}
