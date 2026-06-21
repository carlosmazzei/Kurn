//
//  Date+Formatting.swift
//  Kurn
//

import Foundation

extension Date {
    /// Medium date + short time, localized. e.g. "Jun 16, 2025 at 9:30 AM".
    var meetingDisplay: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }

    /// Compact date used in default meeting titles. e.g. "2025-06-16".
    var isoDay: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: self)
    }

    /// Timestamp suitable for unique file names. e.g. "20250616-093012".
    var fileTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: self)
    }
}
