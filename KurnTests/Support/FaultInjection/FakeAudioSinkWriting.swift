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
    private(set) var paused = true
    private(set) var closed = false

    /// Every `write(_:)` call from this point on (1-based) returns `false`.
    func failWrites(fromCall n: Int) {
        lock.lock(); defer { lock.unlock() }
        failFromCall = n
    }

    var writesAttempted: Int {
        lock.lock(); defer { lock.unlock() }
        return writeCount
    }

    func open(
        _ file: AVAudioFile,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        onBuffer: ((AVAudioPCMBuffer) -> Void)?
    ) {
        lock.lock(); defer { lock.unlock() }
        paused = false
    }

    func replaceConverter(_ converter: AVAudioConverter) {}

    var currentTargetFormat: AVAudioFormat? { nil }

    func setPaused(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        paused = value
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        paused = true
    }

    var currentLevel: Float { 0 }

    @discardableResult
    func write(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        writeCount += 1
        if let failFromCall, writeCount >= failFromCall { return false }
        return true
    }
}
