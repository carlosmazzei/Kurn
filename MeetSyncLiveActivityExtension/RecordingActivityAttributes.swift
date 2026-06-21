//
//  RecordingActivityAttributes.swift
//  MeetSyncLiveActivityExtension
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
