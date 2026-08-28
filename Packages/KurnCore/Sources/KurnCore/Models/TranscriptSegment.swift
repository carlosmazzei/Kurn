//
//  TranscriptSegment.swift
//  KurnCore
//
//  One speaker-attributed span of speech. Stored inside `Transcript` as JSON
//  `Data` because SwiftData does not persist arbitrary `Codable` arrays of
//  structs directly.
//

import Foundation

public struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var speakerLabel: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
    public var confidence: Float?

    public init(
        id: UUID = UUID(),
        speakerLabel: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        confidence: Float? = nil
    ) {
        self.id = id
        self.speakerLabel = speakerLabel
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.confidence = confidence
    }

    public var duration: TimeInterval { max(0, endTime - startTime) }
}
