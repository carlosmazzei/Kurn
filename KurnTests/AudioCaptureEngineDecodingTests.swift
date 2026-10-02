//
//  AudioCaptureEngineDecodingTests.swift
//  KurnTests
//
//  What the production capture engine decides without a microphone: which
//  `AVAudioSession` notifications become which `AudioCaptureEvent`, and the
//  recording file's format and bit-rate fallback. `FakeAudioCaptureEngine`
//  drives the recorder's state machine; these pin the live engine's half.
//

import AVFoundation
import Foundation
import Testing
@testable import Kurn

struct AudioCaptureEventDecodingTests {

    @Test func interruptionBeganAndEnded() {
        let began: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
        ]
        #expect(AudioCaptureEvent.interruption(userInfo: began) == .interruptionBegan)

        let resume: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
        ]
        #expect(AudioCaptureEvent.interruption(userInfo: resume) == .interruptionEnded(shouldResume: true))
    }

    @Test func endedWithoutOptionsNeverResumes() {
        let ended: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
        ]
        #expect(AudioCaptureEvent.interruption(userInfo: ended) == .interruptionEnded(shouldResume: false))
    }

    @Test func malformedInterruptionsAreIgnored() {
        #expect(AudioCaptureEvent.interruption(userInfo: nil) == nil)
        #expect(AudioCaptureEvent.interruption(userInfo: [AVAudioSessionInterruptionTypeKey: "began"]) == nil)
        #expect(AudioCaptureEvent.interruption(userInfo: [AVAudioSessionInterruptionTypeKey: UInt(99)]) == nil)
    }

    @Test func onlyALostInputMattersOnARouteChange() {
        let lost: [AnyHashable: Any] = [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        ]
        #expect(AudioCaptureEvent.routeChange(userInfo: lost) == .inputRouteLost)

        let added: [AnyHashable: Any] = [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
        ]
        #expect(AudioCaptureEvent.routeChange(userInfo: added) == nil)
        #expect(AudioCaptureEvent.routeChange(userInfo: nil) == nil)
    }
}

struct CaptureOutputFileTests {

    private struct EncoderRejected: Error {}

    @Test func settingsAreMonoAACAtTheStorageRate() {
        let settings = CaptureOutputFile.settings(bitRate: 48_000)
        #expect(settings[AVFormatIDKey] as? Int == Int(kAudioFormatMPEG4AAC))
        #expect(settings[AVSampleRateKey] as? Double == AudioRecorderService.storageSampleRate)
        #expect(settings[AVNumberOfChannelsKey] as? Int == 1)
        #expect(settings[AVEncoderBitRateKey] as? Int == 48_000)
        #expect(CaptureOutputFile.settings(bitRate: nil)[AVEncoderBitRateKey] == nil)
    }

    @Test func opensARealFile() throws {
        let url = AudioFixtures.tempURL(ext: "m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try CaptureOutputFile.open(at: url, bitRate: 48_000)
        #expect(file is AVAudioFile)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aRejectedBitRateIsRetriedWithoutOne() throws {
        let url = AudioFixtures.tempURL(ext: "m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        var requested: [Int?] = []
        _ = try CaptureOutputFile.open(at: url, bitRate: 48_000) { url, settings in
            requested.append(settings[AVEncoderBitRateKey] as? Int)
            if settings[AVEncoderBitRateKey] != nil { throw EncoderRejected() }
            return try AVAudioFile(forWriting: url, settings: settings)
        }
        #expect(requested == [48_000, nil])
    }

    @Test func aSecondFailureIsThrown() {
        var attempts = 0
        #expect(throws: EncoderRejected.self) {
            _ = try CaptureOutputFile.open(at: AudioFixtures.tempURL(), bitRate: 48_000) { _, _ in
                attempts += 1
                throw EncoderRejected()
            }
        }
        #expect(attempts == 2)
    }
}
