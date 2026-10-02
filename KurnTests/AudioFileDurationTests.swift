//
//  AudioFileDurationTests.swift
//  KurnTests
//
//  The whole-clip fallback the on-device VAD and diarizers return when they
//  cannot produce real output: the file's own duration, or zero — never a
//  failure — when the file cannot be read.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct AudioFileDurationTests {

    @Test func measuresTheFileDuration() throws {
        let url = try AudioFixtures.wav(segments: [(220, 1.5), (0, 0.5)])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(abs(AudioFileDuration.seconds(of: url) - 2.0) < 0.01)
    }

    @Test func unreadableFileMeasuresZero() throws {
        let missing = AudioFixtures.tempURL(ext: "wav")
        #expect(AudioFileDuration.seconds(of: missing) == 0)

        let garbage = AudioFixtures.tempURL(ext: "m4a")
        try Data("not audio".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }
        #expect(AudioFileDuration.seconds(of: garbage) == 0)
    }

    @Test func fallbacksSpanTheWholeClip() throws {
        let url = try AudioFixtures.wav(segments: [(220, 1.0)])
        defer { try? FileManager.default.removeItem(at: url) }

        let turn = AudioFileDuration.wholeClipTurn(for: url)
        #expect(turn.speakerLabel == "Speaker 1")
        #expect(turn.start == 0)
        #expect(abs(turn.end - 1.0) < 0.01)

        let region = AudioFileDuration.wholeClipRegion(for: url)
        #expect(region.start == 0)
        #expect(abs(region.end - 1.0) < 0.01)
    }

    @Test func fallbacksForAnUnreadableFileAreEmptyNotNegative() {
        let missing = AudioFixtures.tempURL(ext: "wav")
        #expect(AudioFileDuration.wholeClipTurn(for: missing).end == 0)
        #expect(AudioFileDuration.wholeClipRegion(for: missing).end == 0)
    }
}
