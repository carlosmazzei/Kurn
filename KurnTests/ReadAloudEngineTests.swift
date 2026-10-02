//
//  ReadAloudEngineTests.swift
//  KurnTests
//
//  The two read-aloud engines driven without a network or a listener:
//  `CloudSpeechEngine` against a scripted provider (which chunk is fetched,
//  failures surfaced as `AppError`, stale fetches dropped after a stop —
//  never a real `AVAudioPlayer`, which hangs the CI simulator).
//
//  `SystemSpeechEngine` has no suite here on purpose: constructing an
//  `AVSpeechSynthesizer` or listing the installed voices calls into the
//  speech daemon, which on the CI simulator deadlocks and aborts the whole
//  test process ("Initialize: RPC timeout. Apparently deadlocked"). Its pure
//  helpers are covered in `SpeechSynthesisTests`.
//

import AVFoundation
import Foundation
import KurnCore
import Testing
@testable import Kurn

/// Answers each chunk with a short silent WAV, or with the scripted failure.
private final class ScriptedSpeechProvider: SpeechSynthesisProvider, @unchecked Sendable {
    let provider = AIProvider.openAI
    let maxCharactersPerRequest = 4_096

    private let lock = NSLock()
    private var _requests: [String] = []
    private let failure: Error?
    private let payload: Data
    private let delayNanoseconds: UInt64

    init(failure: Error? = nil, payload: Data? = nil, delayNanoseconds: UInt64 = 0) {
        self.failure = failure
        self.payload = payload ?? PCMWaveFile.wrap(pcm: Data(count: 2 * 1_200), sampleRate: 24_000)
        self.delayNanoseconds = delayNanoseconds
    }

    var requests: [String] { lock.withLock { _requests } }

    func synthesize(_ text: String, languageCode: String?) async throws -> Data {
        lock.withLock { _requests.append(text) }
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        if let failure { throw failure }
        return payload
    }
}

/// Polls until `condition` holds. The deadline is generous on purpose: the
/// main actor is shared with every other suite running in parallel, and on
/// a loaded CI simulator a hop that normally takes milliseconds has taken
/// well over five seconds. A passing test returns as soon as it holds.
@MainActor
private func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

@MainActor
@Suite(.serialized)
struct CloudSpeechEngineTests {

    private struct Offline: Error {}

    /// The provider fails, so the engine never builds an `AVAudioPlayer`:
    /// on the CI simulator that call touches the audio session, blocked for
    /// minutes, and took the test process down with it. Playback itself is
    /// left to the device matrix.
    @Test func startingFetchesTheRequestedChunkFirst() async {
        let provider = ScriptedSpeechProvider(failure: Offline())
        let engine = CloudSpeechEngine(provider: provider, languageCode: "pt", rate: 1)
        var failure: AppError?
        engine.onFailed = { failure = $0 }
        engine.pause()
        engine.start(["primeiro", "segundo"], at: 0)
        #expect(await waitUntil { failure != nil })
        #expect(provider.requests == ["primeiro"])
        engine.resume()
        engine.stop()
    }

    @Test func startingPastTheEndFinishesImmediately() {
        let engine = CloudSpeechEngine(provider: ScriptedSpeechProvider(), languageCode: nil, rate: 1)
        var finished = false
        engine.onFinished = { finished = true }
        engine.start(["só um"], at: 3)
        #expect(finished)
    }

    @Test func providerAppErrorsAreSurfacedAsIs() async {
        let engine = CloudSpeechEngine(
            provider: ScriptedSpeechProvider(failure: AppError.noAPIKey(provider: "OpenAI")),
            languageCode: nil,
            rate: 1
        )
        var failure: AppError?
        engine.onFailed = { failure = $0 }
        engine.start(["texto"], at: 0)
        #expect(await waitUntil { failure != nil })
        #expect(failure?.logCode == AppError.noAPIKey(provider: "").logCode)
    }

    @Test func otherFailuresBecomeSpeechSynthesisErrors() async {
        let engine = CloudSpeechEngine(provider: ScriptedSpeechProvider(failure: Offline()), languageCode: nil, rate: 1)
        var failure: AppError?
        engine.onFailed = { failure = $0 }
        engine.start(["texto"], at: 0)
        #expect(await waitUntil { failure != nil })
        #expect(failure?.logCode == AppError.speechSynthesisFailed("").logCode)
    }

    @Test func aFetchThatLandsAfterStopIsDropped() async throws {
        // Fails even if the stop loses the race, so no player is ever built.
        let provider = ScriptedSpeechProvider(failure: Offline(), delayNanoseconds: 200_000_000)
        let engine = CloudSpeechEngine(provider: provider, languageCode: nil, rate: 1)
        var started: [Int] = []
        var failure: AppError?
        engine.onChunkStarted = { started.append($0) }
        engine.onFailed = { failure = $0 }
        engine.start(["texto"], at: 0)
        #expect(await waitUntil { provider.requests.count == 1 })
        engine.stop()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(started.isEmpty)
        #expect(failure == nil)
    }
}
