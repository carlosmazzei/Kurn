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

    // POSIX locale keeps the shape stable ("GMT-3", 24-hour clock) in every UI language.
    private static let titleStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm O"
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

    /// "Today" / "Yesterday" / the short localized date — the relative day a
    /// list row was recorded at.
    var relativeDay: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            return NSLocalizedString("meetings.day.today", comment: "Today")
        }
        if calendar.isDateInYesterday(self) {
            return NSLocalizedString("meetings.day.yesterday", comment: "Yesterday")
        }
        return formatted(date: .abbreviated, time: .omitted)
    }

    /// Compact date used in default meeting titles. e.g. "2025-06-16".
    var isoDay: String { Self.isoDayFormatter.string(from: self) }

    /// Date, time and time zone used in default meeting titles.
    /// e.g. "2025-06-16 09:30 GMT-3".
    var titleStamp: String { Self.titleStampFormatter.string(from: self) }

    /// Regex matching the `titleStamp` shape ("2025-06-16 09:30 GMT-3"),
    /// derived from `titleStampFormatter`'s pattern so recognition and
    /// rendering can never drift: numeric fields become `\d{<width>}` and
    /// the zone field `O` becomes the `GMT…` forms it can emit ("GMT",
    /// "GMT-3", "GMT+5:30"). Used by `Meeting.isDefaultTitle` to recognize
    /// a generated title rendered in a different time zone than today's.
    static let titleStampPattern: String = {
        let format = titleStampFormatter.dateFormat ?? ""
        var pattern = ""
        var index = format.startIndex
        while index < format.endIndex {
            let character = format[index]
            if character.isLetter {
                var end = index
                while end < format.endIndex, format[end] == character {
                    end = format.index(after: end)
                }
                let field = String(format[index..<end])
                switch field {
                case "O", "OOOO":
                    pattern += #"GMT(?:[+-]\d{1,2}(?::\d{2})?)?"#
                default:
                    // y, M, d, H, m and friends all render as fixed-width digits.
                    pattern += "\\d{\(field.count)}"
                }
                index = end
            } else {
                pattern += NSRegularExpression.escapedPattern(for: String(character))
                index = format.index(after: index)
            }
        }
        return pattern
    }()

    /// Timestamp suitable for unique file names. e.g. "20250616-093012".
    var fileTimestamp: String { Self.fileTimestampFormatter.string(from: self) }
}
