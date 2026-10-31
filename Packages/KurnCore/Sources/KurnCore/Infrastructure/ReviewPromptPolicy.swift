//
//  ReviewPromptPolicy.swift
//  KurnCore
//
//  When the app may ask for an App Store rating. The system prompt itself
//  (`RequestReviewAction`) is shown at most three times a year by iOS and may
//  be shown never, so the only decision the app owns is *when it is worth
//  asking* — and asking at the wrong moment (on launch, after a failure, in
//  the middle of a recording) is what turns a rating prompt into a one-star
//  review. The rule here: only right after the user got something they came
//  for, only once they have done that a few times, at most once per app
//  version, and never twice within `minimumInterval`.
//
//  Pure value logic so it is tested on Linux; the app-side
//  `ReviewPromptCoordinator` persists the state and presents the prompt.
//

import Foundation

/// What has happened so far, persisted between launches.
public struct ReviewPromptState: Codable, Sendable, Equatable {
    /// Completed moments of value (a transcript finished, a summary written).
    public var successfulMoments: Int
    /// `CFBundleShortVersionString` of the version that last asked.
    public var lastPromptedVersion: String?
    public var lastPromptedAt: Date?

    public init(successfulMoments: Int = 0, lastPromptedVersion: String? = nil, lastPromptedAt: Date? = nil) {
        self.successfulMoments = successfulMoments
        self.lastPromptedVersion = lastPromptedVersion
        self.lastPromptedAt = lastPromptedAt
    }
}

public struct ReviewPromptPolicy: Sendable, Equatable {
    /// Moments of value required before the first request, and again since
    /// the previous one before the next.
    public let minimumMoments: Int
    /// Smallest gap between two requests, whatever the version.
    public let minimumInterval: TimeInterval

    public static let standard = ReviewPromptPolicy(
        minimumMoments: 3,
        minimumInterval: 120 * 24 * 60 * 60
    )

    public init(minimumMoments: Int, minimumInterval: TimeInterval) {
        self.minimumMoments = max(1, minimumMoments)
        self.minimumInterval = max(0, minimumInterval)
    }

    /// Whether a request is due now for `currentVersion`.
    public func shouldRequest(state: ReviewPromptState, currentVersion: String, now: Date) -> Bool {
        guard state.successfulMoments >= minimumMoments else { return false }
        guard !currentVersion.isEmpty, state.lastPromptedVersion != currentVersion else { return false }
        if let last = state.lastPromptedAt, now.timeIntervalSince(last) < minimumInterval {
            return false
        }
        return true
    }

    /// The state after one more moment of value.
    public func recordingMoment(_ state: ReviewPromptState) -> ReviewPromptState {
        var next = state
        next.successfulMoments = state.successfulMoments == Int.max ? Int.max : state.successfulMoments + 1
        return next
    }

    /// The state after a request was made. The moment count restarts, so the
    /// next request again waits for `minimumMoments` fresh successes.
    public func recordingRequest(_ state: ReviewPromptState, version: String, at now: Date) -> ReviewPromptState {
        ReviewPromptState(successfulMoments: 0, lastPromptedVersion: version, lastPromptedAt: now)
    }
}
