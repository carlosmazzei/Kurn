//
//  FakeAudioSinkWriting.swift
//  KurnTests
//
//  An `AudioSinkWriting` double that records every `write` call and can be
//  told to report failure starting at a specific call number, so a test can
//  prove the seam is real and observable — the render-thread write path had
//  no injection point at all before it.
//

import AVFoundation
@testable import Kurn

final class FakeAudioSinkWriting: AudioSinkWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var writeCount = 0
    private var failFromCall: Int?

    /// Every `write(_:)` call from this point on (1-based) returns `false`.
    func failWrites(fromCall call: Int) {
        lock.withLock {
            failFromCall = call
        }
    }

    var writesAttempted: Int {
        lock.withLock { writeCount }
    }

    func open(
        _ file: AVAudioFile,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        onBuffer: ((AVAudioPCMBuffer) -> Void)?
    ) {}

    func replaceConverter(_ converter: AVAudioConverter) {}

    var currentTargetFormat: AVAudioFormat? { nil }

    func setPaused(_ value: Bool) {}

    func close() {}

    var currentLevel: Float { 0 }

    @discardableResult
    func write(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.withLock {
            writeCount += 1
            guard let failFromCall else { return true }
            return writeCount < failFromCall
        }
    }
}
