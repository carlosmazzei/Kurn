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
    }

    var meetingTitle: String
}
