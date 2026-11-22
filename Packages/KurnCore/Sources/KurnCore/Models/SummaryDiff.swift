//
//  SummaryDiff.swift
//  KurnCore
//
//  Line-level comparison of two generated summaries, run entirely on device:
//  each side is flattened to its content lines (bullet items plus the body
//  split into lines), normalized (case, punctuation and whitespace folded),
//  and a line is reported "only in X" when no normalized equal exists
//  anywhere in the other summary. Sections that lose every line are dropped.
//

import Foundation

/// The outcome of `SummaryDiff.compare`: the lines unique to each summary,
/// still grouped under the section titles they came from.
public struct SummaryComparison: Equatable, Sendable {
    /// One titled section's remaining (unique) lines.
    public struct Side: Equatable, Sendable {
        public let title: String
        public let lines: [String]

        public init(title: String, lines: [String]) {
            self.title = title
            self.lines = lines
        }
    }

    public let onlyInFirst: [Side]
    public let onlyInSecond: [Side]

    public init(onlyInFirst: [Side], onlyInSecond: [Side]) {
        self.onlyInFirst = onlyInFirst
        self.onlyInSecond = onlyInSecond
    }

    /// True when both sides are empty — the summaries agree line for line.
    public var isEmpty: Bool { onlyInFirst.isEmpty && onlyInSecond.isEmpty }
}

public enum SummaryDiff {
    /// One summary section as compare input: a heading and its content lines
    /// (bullet items and body lines, in reading order).
    public typealias SectionInput = (title: String, lines: [String])

    public static func compare(first: [SectionInput], second: [SectionInput]) -> SummaryComparison {
        let firstNormalized = Set(flatten(first).map(normalize))
        let secondNormalized = Set(flatten(second).map(normalize))
        return SummaryComparison(
            onlyInFirst: uniqueSections(in: first, against: secondNormalized),
            onlyInSecond: uniqueSections(in: second, against: firstNormalized)
        )
    }

    /// Every content line of `sections`, in order — matching is done across
    /// the whole summary, not section by section, so a line that moved
    /// between sections is still "in both".
    private static func flatten(_ sections: [SectionInput]) -> [String] {
        sections.flatMap(\.lines)
    }

    private static func uniqueSections(in sections: [SectionInput], against other: Set<String>) -> [SummaryComparison.Side] {
        sections.compactMap { section in
            let unique = section.lines.filter { !other.contains(normalize($0)) }
            return unique.isEmpty ? nil : SummaryComparison.Side(title: section.title, lines: unique)
        }
    }

    /// Two lines count as the same when they differ only in case,
    /// punctuation or whitespace — a model rewording "Ship X." as "ship x"
    /// is not a difference worth showing.
    static func normalize(_ line: String) -> String {
        line
            .lowercased()
            .components(separatedBy: .punctuationCharacters).joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
