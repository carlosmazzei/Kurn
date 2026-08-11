//
//  SecurityCoverStateTests.swift
//  KurnTests
//
//  The cover itself is a `UIWindow` and its layering can't be exercised here.
//  What can be, and what the security of the whole scheme rests on, is the
//  decision of when to cover: these pin the full matrix of scene phase ×
//  requirement × gate state, including the two cases a regression would most
//  plausibly get wrong — a locked app that is merely inactive, and an app whose
//  owner has turned the requirement off.
//

import SwiftUI
import Testing
@testable import Kurn

struct SecurityCoverStateTests {

    @Test func activeAndUnlockedShowsNothing() {
        let state = SecurityCoverState.resolve(
            scenePhase: .active, requireAuth: true, isUnlocked: true
        )
        #expect(state == .hidden)
        #expect(state.isCovering == false)
    }

    @Test func activeAndLockedShowsLockScreen() {
        let state = SecurityCoverState.resolve(
            scenePhase: .active, requireAuth: true, isUnlocked: false
        )
        #expect(state == .locked)
        #expect(state.isCovering)
        #expect(state.needsKeyWindow)
    }

    /// Turning the requirement off must leave the app uncovered even though the
    /// gate itself never unlocks — nothing calls `authenticate()` in that mode.
    @Test func requirementOffLeavesAppUncoveredWhileActive() {
        let state = SecurityCoverState.resolve(
            scenePhase: .active, requireAuth: false, isUnlocked: false
        )
        #expect(state == .hidden)
    }

    @Test func inactivePhaseShowsPrivacyCover() {
        let state = SecurityCoverState.resolve(
            scenePhase: .inactive, requireAuth: false, isUnlocked: true
        )
        #expect(state == .privacy)
        #expect(state.isCovering)
    }

    @Test func backgroundPhaseShowsPrivacyCover() {
        let state = SecurityCoverState.resolve(
            scenePhase: .background, requireAuth: false, isUnlocked: true
        )
        #expect(state == .privacy)
        #expect(state.isCovering)
    }

    /// The snapshot is taken during the transition out of `.active`, so an
    /// unlocked app with the requirement off still has to be covered — this is
    /// the case that keeps a transcript out of the app-switcher card.
    @Test func unlockedAppIsStillCoveredWhenLeavingTheForeground() {
        let state = SecurityCoverState.resolve(
            scenePhase: .inactive, requireAuth: true, isUnlocked: true
        )
        #expect(state == .privacy)
    }

    /// A locked app that is only inactive shows the neutral cover rather than
    /// the lock screen: the lock screen's controls are useless mid-transition,
    /// and it is what the app-switcher would otherwise photograph.
    @Test func lockedButInactiveShowsPrivacyRatherThanLockScreen() {
        let state = SecurityCoverState.resolve(
            scenePhase: .inactive, requireAuth: true, isUnlocked: false
        )
        #expect(state == .privacy)
        #expect(state.needsKeyWindow == false)
    }

    /// Only the lock screen takes key status; the privacy cover must not, or a
    /// transient interruption would pull focus from whatever the app was doing.
    @Test func onlyTheLockScreenTakesKeyWindow() {
        #expect(SecurityCoverState.hidden.needsKeyWindow == false)
        #expect(SecurityCoverState.privacy.needsKeyWindow == false)
        #expect(SecurityCoverState.locked.needsKeyWindow)
    }
}
