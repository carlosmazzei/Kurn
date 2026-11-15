//
//  KnowledgeTemporalValue.swift
//  KurnCore
//
//  A point in time at the precision it was actually stated with (spec §6):
//  "in October" is a month, not the 1st of October. Text forms are ISO 8601 —
//  `yyyy-MM-dd'T'HH:mm:ss'Z'` for an instant, `yyyy-MM-dd` for a day,
//  `yyyy-MM` for a month — and nothing finer than the stated precision is
//  ever invented.
//

import Foundation

public enum KnowledgeTemporalPrecision: String, Codable, Sendable, CaseIterable {
    case instant, day, month, unknown
}

public struct KnowledgeTemporalValue: Hashable, Sendable {
    public let precision: KnowledgeTemporalPrecision
    public let year: Int
    public let month: Int
    /// Present for `.day` and `.instant`.
    public let day: Int?
    /// Seconds since midnight UTC, present for `.instant`.
    public let secondOfDay: Int?

    /// Parses `text` written at `precision`. Returns nil for a malformed or
    /// impossible value (2026-02-30), or for `.unknown`, which has no text.
    public init?(text: String, precision: KnowledgeTemporalPrecision) {
        let parts: [Int]
        switch precision {
        case .unknown:
            return nil
        case .month:
            guard let values = Self.numbers(text, pattern: #"^(\d{4})-(\d{2})$"#) else { return nil }
            parts = values
        case .day:
            guard let values = Self.numbers(text, pattern: #"^(\d{4})-(\d{2})-(\d{2})$"#) else { return nil }
            parts = values
        case .instant:
            guard let values = Self.numbers(text, pattern: #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$"#)
            else { return nil }
            parts = values
        }
        let year = parts[0], month = parts[1]
        guard (1...12).contains(month) else { return nil }
        var day: Int?
        if parts.count >= 3 {
            guard (1...Self.daysIn(month: month, year: year)).contains(parts[2]) else { return nil }
            day = parts[2]
        }
        var second: Int?
        if parts.count == 6 {
            let (hour, minute, sec) = (parts[3], parts[4], parts[5])
            guard hour < 24, minute < 60, sec < 60 else { return nil }
            second = hour * 3600 + minute * 60 + sec
        }
        self.precision = precision
        self.year = year
        self.month = month
        self.day = day
        self.secondOfDay = second
    }

    /// The canonical text form, the inverse of `init(text:precision:)`.
    public var text: String {
        let base = Self.pad(year, 4) + "-" + Self.pad(month, 2)
        guard let day else { return base }
        let dayText = base + "-" + Self.pad(day, 2)
        guard let secondOfDay else { return dayText }
        let clock = [secondOfDay / 3600, secondOfDay / 60 % 60, secondOfDay % 60].map { Self.pad($0, 2) }
        return dayText + "T" + clock.joined(separator: ":") + "Z"
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private static func numbers(_ text: String, pattern: String) -> [Int]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).flatMap { Int(text[$0]) }
        }
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }
}
