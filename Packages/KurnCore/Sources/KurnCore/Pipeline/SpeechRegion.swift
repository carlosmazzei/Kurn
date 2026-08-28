//
//  SpeechRegion.swift
//  KurnCore
//
//  A region of detected speech within a clip, `[start, end)` in seconds.
//

import Foundation

public struct SpeechRegion: Sendable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}
