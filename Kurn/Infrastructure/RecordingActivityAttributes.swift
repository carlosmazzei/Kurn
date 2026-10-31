//
//  RecordingActivityAttributes.swift
//  Kurn
//
//  Shared between the Kurn app target and KurnLiveActivityExtension so the two
//  sides of the Live Activity always agree on the same Codable shape —
//  ActivityKit requires an exact match to decode/render updates.
//

import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isPaused: Bool
        var elapsed: TimeInterval
        var referenceDate: Date
        var highlightCount: Int
    }

    var meetingTitle: String
}

extension RecordingActivityAttributes.ContentState {
    /// What the Live Activity shows once pause is toggled at `now`: pausing
    /// folds the running time into `elapsed` and freezes it; resuming restarts
    /// the timer from there. The Live Activity's own buttons apply it before
    /// the system can suspend the app, rather than waiting for the recorder's
    /// asynchronous update (see `RecordingControlIntent`).
    func togglingPause(at now: Date = Date()) -> Self {
        let elapsedNow = isPaused ? elapsed : elapsed + max(0, now.timeIntervalSince(referenceDate))
        return Self(isPaused: !isPaused, elapsed: elapsedNow, referenceDate: now, highlightCount: highlightCount)
    }
}
