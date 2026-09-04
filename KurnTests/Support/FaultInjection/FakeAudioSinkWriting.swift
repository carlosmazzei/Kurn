//
//  FakeAudioSinkWriting.swift
//  KurnTests
//
//  An `AudioSinkWriting` double that records frame progress and can report a
//  failure from a specific write or during close, so tests can drive both the
//  live-capture and final-drain failure paths deterministically.
//

import AVFoundation
import Foundation
@testable import Kurn

final class FakeAudioSinkWriting: AudioSinkWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var writeCount = 0
    private var failFromCall: Int?
    private var shouldFailOnClose = false
    private var currentSnapshot = AudioSinkSnapshot()
    private var targetFormat: AVAudioFormat?
    private var converterReplacements = 0
    private var pausedValue = true
    private var opens = 0
    private var closes = 0

    var openCount: Int { lock.withLock { opens } }
    var closeCount: Int { lock.withLock { closes } }

    /// Every `write(_:)` call from this point on (1-based) returns `false`.
    func failWrites(fromCall call: Int) {
        lock.withLock {
            failFromCall = call
        }
    }

    var writesAttempted: Int {
        lock.withLock { writeCount }
    }

    func failOnClose() {
        lock.withLock {
            shouldFailOnClose = true
        }
    }

    func open(
        _ file: any AudioFileWriting,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        onBuffer: ((AVAudioPCMBuffer) -> Void)?
    ) {
        lock.withLock {
            writeCount = 0
            currentSnapshot = AudioSinkSnapshot()
            self.targetFormat = targetFormat
            pausedValue = false
            opens += 1
        }
    }

    func replaceConverter(_ converter: AVAudioConverter) {
        lock.withLock { converterReplacements += 1 }
    }

    var currentTargetFormat: AVAudioFormat? {
        lock.withLock { targetFormat }
    }

    var convertersReplaced: Int {
        lock.withLock { converterReplacements }
    }

    func setPaused(_ value: Bool) {
        lock.withLock { pausedValue = value }
    }

    var isPaused: Bool {
        lock.withLock { pausedValue }
    }

    func close() {
        lock.withLock {
            closes += 1
            if shouldFailOnClose, currentSnapshot.firstFailure == nil {
                currentSnapshot.firstFailure = .finalDrain
            }
        }
    }

    var currentLevel: Float { 0 }

    var snapshot: AudioSinkSnapshot {
        lock.withLock { currentSnapshot }
    }

    @discardableResult
    func write(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.withLock {
            writeCount += 1
            currentSnapshot.attemptedInputFrames += Int64(buffer.frameLength)
            if let failFromCall, writeCount >= failFromCall {
                if currentSnapshot.firstFailure == nil {
                    currentSnapshot.firstFailure = .write
                }
                return false
            }
            currentSnapshot.writtenOutputFrames += Int64(buffer.frameLength)
            currentSnapshot.lastSuccessfulWriteAt = Date()
            return true
        }
    }
}
