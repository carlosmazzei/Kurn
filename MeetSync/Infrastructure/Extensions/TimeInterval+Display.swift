//
//  TimeInterval+Display.swift
//  MeetSync
//

import Foundation

extension TimeInterval {
    /// "mm:ss" for short clips, "h:mm:ss" once past an hour.
    var clockDisplay: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
