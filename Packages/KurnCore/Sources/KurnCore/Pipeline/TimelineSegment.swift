//
//  TimelineSegment.swift
//  KurnCore
//
//  One contiguous speech run in a VAD-compacted file and where it came from.
//

import Foundation

public struct TimelineSegment: Sendable, Equatable {
    public var compactedStart: TimeInterval
    public var originalStart: TimeInterval
    public var duration: TimeInterval

    public init(compactedStart: TimeInterval, originalStart: TimeInterval, duration: TimeInterval) {
        self.compactedStart = compactedStart
        self.originalStart = originalStart
        self.duration = duration
    }
}
