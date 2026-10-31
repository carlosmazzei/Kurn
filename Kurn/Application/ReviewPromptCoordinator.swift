//
//  ReviewPromptCoordinator.swift
//  Kurn
//
//  Decides, app-wide, when to ask for an App Store rating; the view-side
//  `reviewPromptPresenter()` modifier only shows the system prompt.
//
//  Ratings drive both App Store search ranking and how many people install
//  from a search result, and an app that never asks collects ratings only
//  from people unhappy enough to go looking for the button. So a completed
//  transcript or summary is reported here as a moment of value, and once
//  `ReviewPromptPolicy` says one is due, `requestToken` changes for the
//  presenter to act on. A moment that lands while the prompt would be
//  unwelcome — a recording in progress, the app not frontmost (a background
//  transcription), an unattended UI test run — still counts, but does not
//  ask: the next foreground success will.
//
//  The state is a small JSON blob in `UserDefaults`, like `UsageStats`. It is
//  a counter and a version string, nothing about any meeting.
//

import Foundation
import KurnCore
import Observation
import UIKit

@MainActor
@Observable
final class ReviewPromptCoordinator {
    static let defaultsKey = "settings.reviewPrompt"

    /// Changes each time a request becomes due. The presenter reacts to the
    /// change rather than to a Boolean so a value restored at launch is never
    /// mistaken for a fresh moment.
    private(set) var requestToken = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let policy: ReviewPromptPolicy
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let isSuppressed: () -> Bool
    @ObservationIgnored private var isRequestPending = false

    init(
        defaults: UserDefaults = .standard,
        policy: ReviewPromptPolicy = .standard,
        appVersion: String = ReviewPromptCoordinator.bundleVersion,
        now: @escaping () -> Date = Date.init,
        isSuppressed: @escaping () -> Bool = ReviewPromptCoordinator.liveSuppression
    ) {
        self.defaults = defaults
        self.policy = policy
        self.appVersion = appVersion
        self.now = now
        self.isSuppressed = isSuppressed
    }

    /// The persisted state; unreadable data counts as a fresh start, which at
    /// worst delays a request — it can never cause an extra one, because iOS
    /// enforces its own yearly cap regardless.
    var state: ReviewPromptState {
        get {
            guard let data = defaults.data(forKey: Self.defaultsKey),
                  let decoded = try? JSONDecoder().decode(ReviewPromptState.self, from: data)
            else { return ReviewPromptState() }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.defaultsKey)
            }
        }
    }

    /// Report that the user just got something they came for.
    func noteSuccessfulMoment() {
        let next = policy.recordingMoment(state)
        state = next
        guard !isSuppressed(), policy.shouldRequest(state: next, currentVersion: appVersion, now: now()) else {
            return
        }
        isRequestPending = true
        requestToken &+= 1
    }

    /// Called by the presenter when `requestToken` changes. Returns whether
    /// to show the prompt now, and records the request when it does.
    func consumePendingRequest() -> Bool {
        guard isRequestPending else { return false }
        isRequestPending = false
        guard !isSuppressed(), policy.shouldRequest(state: state, currentVersion: appVersion, now: now()) else {
            return false
        }
        state = policy.recordingRequest(state, version: appVersion, at: now())
        return true
    }

    static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Unattended UI test runs, a live capture, or the app not frontmost.
    static func liveSuppression() -> Bool {
        isUnattendedRun(arguments: ProcessInfo.processInfo.arguments)
            || RecordingCommandRouter.shared.hasActiveSession
            || UIApplication.shared.applicationState != .active
    }

    /// Every UI-test launch argument the app knows starts with `UI-Testing`.
    static func isUnattendedRun(arguments: [String]) -> Bool {
        arguments.contains { $0.hasPrefix("UI-Testing") }
    }
}
