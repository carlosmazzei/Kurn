//
//  ReviewPromptPolicyTests.swift
//  KurnCoreTests
//
//  Pins when the app may ask for a rating: never before enough successes,
//  never twice in one version, never inside the minimum interval.
//

import Foundation
import Testing
@testable import KurnCore

struct ReviewPromptPolicyTests {
    private let policy = ReviewPromptPolicy(minimumMoments: 3, minimumInterval: 100)
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func freshInstallDoesNotAsk() {
        #expect(!policy.shouldRequest(state: ReviewPromptState(), currentVersion: "1.0.0", now: now))
    }

    @Test func asksOnceEnoughMomentsAccumulate() {
        var state = ReviewPromptState()
        for _ in 0..<2 { state = policy.recordingMoment(state) }
        #expect(!policy.shouldRequest(state: state, currentVersion: "1.0.0", now: now))
        state = policy.recordingMoment(state)
        #expect(state.successfulMoments == 3)
        #expect(policy.shouldRequest(state: state, currentVersion: "1.0.0", now: now))
    }

    @Test func neverAsksTwiceInTheSameVersion() {
        let asked = policy.recordingRequest(ReviewPromptState(successfulMoments: 3), version: "1.0.0", at: now)
        #expect(asked.successfulMoments == 0)
        let later = ReviewPromptState(
            successfulMoments: 10, lastPromptedVersion: "1.0.0", lastPromptedAt: asked.lastPromptedAt
        )
        #expect(!policy.shouldRequest(state: later, currentVersion: "1.0.0", now: now.addingTimeInterval(1_000)))
    }

    @Test func aNewVersionWaitsForTheInterval() {
        let state = ReviewPromptState(successfulMoments: 5, lastPromptedVersion: "1.0.0", lastPromptedAt: now)
        #expect(!policy.shouldRequest(state: state, currentVersion: "1.1.0", now: now.addingTimeInterval(99)))
        #expect(policy.shouldRequest(state: state, currentVersion: "1.1.0", now: now.addingTimeInterval(100)))
    }

    @Test func anEmptyVersionNeverAsks() {
        #expect(!policy.shouldRequest(state: ReviewPromptState(successfulMoments: 9), currentVersion: "", now: now))
    }

    @Test func boundsAreClampedAndCountersSaturate() {
        let loose = ReviewPromptPolicy(minimumMoments: 0, minimumInterval: -5)
        #expect(loose.minimumMoments == 1)
        #expect(loose.minimumInterval == 0)
        let saturated = loose.recordingMoment(ReviewPromptState(successfulMoments: Int.max))
        #expect(saturated.successfulMoments == Int.max)
        #expect(ReviewPromptPolicy.standard.minimumMoments == 3)
    }

    @Test func stateRoundTripsThroughJSON() throws {
        let state = ReviewPromptState(successfulMoments: 2, lastPromptedVersion: "1.2.3", lastPromptedAt: now)
        let decoded = try JSONDecoder().decode(ReviewPromptState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }
}
