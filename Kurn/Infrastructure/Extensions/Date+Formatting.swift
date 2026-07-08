//
//  Date+Formatting.swift
//  Kurn
//

import Foundation

extension Date {
    // `DateFormatter` is expensive to create, so cache one per format. They are
    // configured once and never mutated afterwards, which makes reads thread-safe.
    private static let meetingFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let isoDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// Medium date + short time, localized. e.g. "Jun 16, 2025 at 9:30 AM".
    var meetingDisplay: String { Self.meetingFormatter.string(from: self) }

    /// Time only, localized. e.g. "9:30 AM". Used where a full date is too
    /// long, e.g. a chip label distinguishing same-day summaries.
    var shortTime: String { Self.shortTimeFormatter.string(from: self) }

    /// Compact date used in default meeting titles. e.g. "2025-06-16".
    var isoDay: String { Self.isoDayFormatter.string(from: self) }

    /// Timestamp suitable for unique file names. e.g. "20250616-093012".
    var fileTimestamp: String { Self.fileTimestampFormatter.string(from: self) }
}
