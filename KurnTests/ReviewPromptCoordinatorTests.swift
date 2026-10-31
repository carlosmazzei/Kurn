//
//  ReviewPromptCoordinatorTests.swift
//  KurnTests
//
//  The rating request follows `ReviewPromptPolicy`; these pin the app-side
//  half: the state survives in `UserDefaults`, a due request changes
//  `requestToken` exactly once, and a suppressed moment (recording, app in
//  the background, UI test run) counts without asking.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

@MainActor
struct ReviewPromptCoordinatorTests {
    /// A main-actor switch the suppression closure reads: the closure is
    /// `@MainActor` (and so `@Sendable`), which cannot capture a local `var`.
    @MainActor
    private final class Switch {
        var isOn: Bool
        init(_ isOn: Bool) { self.isOn = isOn }
    }

    private let defaults: UserDefaults
    private let policy = ReviewPromptPolicy(minimumMoments: 2, minimumInterval: 60)
    private let start = Date(timeIntervalSince1970: 2_000_000)

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "ReviewPromptCoordinatorTests.\(UUID().uuidString)"))
    }

    private func makeCoordinator(
        version: String = "1.0.0",
        now: Date? = nil,
        suppressed: @escaping @MainActor () -> Bool = { false }
    ) -> ReviewPromptCoordinator {
        let fixed = now ?? start
        return ReviewPromptCoordinator(
            defaults: defaults, policy: policy, appVersion: version,
            now: { fixed }, isSuppressed: suppressed
        )
    }

    @Test func asksOnceAfterEnoughMomentsAndRecordsTheRequest() {
        let coordinator = makeCoordinator()
        coordinator.noteSuccessfulMoment()
        #expect(coordinator.requestToken == 0)
        #expect(!coordinator.consumePendingRequest())

        coordinator.noteSuccessfulMoment()
        #expect(coordinator.requestToken == 1)
        #expect(coordinator.consumePendingRequest())
        #expect(!coordinator.consumePendingRequest())

        let state = coordinator.state
        #expect(state.lastPromptedVersion == "1.0.0")
        #expect(state.lastPromptedAt == start)
        #expect(state.successfulMoments == 0)
    }

    @Test func stateIsSharedThroughDefaultsAcrossInstances() {
        makeCoordinator().noteSuccessfulMoment()
        let relaunched = makeCoordinator()
        #expect(relaunched.state.successfulMoments == 1)
        relaunched.noteSuccessfulMoment()
        #expect(relaunched.requestToken == 1)
    }

    @Test func aSuppressedMomentCountsButDoesNotAsk() {
        let suppressed = Switch(true)
        let coordinator = makeCoordinator(suppressed: { suppressed.isOn })
        coordinator.noteSuccessfulMoment()
        coordinator.noteSuccessfulMoment()
        #expect(coordinator.requestToken == 0)
        #expect(coordinator.state.successfulMoments == 2)

        suppressed.isOn = false
        coordinator.noteSuccessfulMoment()
        #expect(coordinator.requestToken == 1)
        suppressed.isOn = true
        #expect(!coordinator.consumePendingRequest())
        #expect(coordinator.state.lastPromptedVersion == nil)
    }

    @Test func theSameVersionNeverAsksTwice() {
        let coordinator = makeCoordinator()
        coordinator.noteSuccessfulMoment()
        coordinator.noteSuccessfulMoment()
        #expect(coordinator.consumePendingRequest())
        for _ in 0..<5 { coordinator.noteSuccessfulMoment() }
        #expect(coordinator.requestToken == 1)

        let nextVersion = makeCoordinator(version: "1.1.0", now: start.addingTimeInterval(61))
        nextVersion.noteSuccessfulMoment()
        #expect(nextVersion.requestToken == 1)
        #expect(nextVersion.consumePendingRequest())
    }

    @Test func unreadableStateStartsFresh() {
        defaults.set(Data("not json".utf8), forKey: ReviewPromptCoordinator.defaultsKey)
        #expect(makeCoordinator().state == ReviewPromptState())
    }

    @Test func unattendedRunsAreRecognizedByTheirLaunchArgument() {
        #expect(ReviewPromptCoordinator.isUnattendedRun(arguments: ["Kurn", "UI-Testing-Screenshots"]))
        #expect(!ReviewPromptCoordinator.isUnattendedRun(arguments: ["Kurn"]))
        // A unit-test host is never frontmost-and-interactive in a way that
        // should ask for a rating; the live check must not crash either way.
        _ = ReviewPromptCoordinator.liveSuppression()
        #expect(ReviewPromptCoordinator.bundleVersion.isEmpty == false)
    }
}
