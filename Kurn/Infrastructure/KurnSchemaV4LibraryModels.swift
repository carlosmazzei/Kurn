// Frozen V4 (1.3.0) storage shape.
import Foundation
import SwiftData

extension KurnSchemaV4 {
    @Model
    final class SmartFolder {
        @Attribute(.unique) var id: UUID
        var name: String
        var iconName: String
        var colorHex: String
        var predicateData: Data = Data()
        var createdAt: Date

        init(
            id: UUID = UUID(),
            name: String,
            iconName: String,
            colorHex: String,
            predicateData: Data,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            self.iconName = iconName
            self.colorHex = colorHex
            self.predicateData = predicateData
            self.createdAt = createdAt
        }
    }

    @Model
    final class SemanticChunk {
        @Attribute(.unique) var id: UUID
        var meeting: Meeting?
        var recordingID: UUID
        var text: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        var speakerLabel: String
        var vectorData: Data
        var dimension: Int
        var modelIdentifier: String
        var createdAt: Date

        init(
            id: UUID = UUID(),
            meeting: Meeting? = nil,
            recordingID: UUID,
            text: String,
            startTime: TimeInterval,
            endTime: TimeInterval,
            speakerLabel: String,
            vectorData: Data,
            dimension: Int,
            modelIdentifier: String,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.meeting = meeting
            self.recordingID = recordingID
            self.text = text
            self.startTime = startTime
            self.endTime = endTime
            self.speakerLabel = speakerLabel
            self.vectorData = vectorData
            self.dimension = dimension
            self.modelIdentifier = modelIdentifier
            self.createdAt = createdAt
        }
    }

    @Model
    final class WikiArticle {
        @Attribute(.unique) var id: UUID
        var meeting: Meeting?
        var bodyMarkdown: String
        var meetingTitleSnapshot: String
        var meetingDate: Date
        var sourceContentHash: String
        var generatorModelIdentifier: String
        var createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            meeting: Meeting? = nil,
            bodyMarkdown: String,
            meetingTitleSnapshot: String,
            meetingDate: Date,
            sourceContentHash: String,
            generatorModelIdentifier: String,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.meeting = meeting
            self.bodyMarkdown = bodyMarkdown
            self.meetingTitleSnapshot = meetingTitleSnapshot
            self.meetingDate = meetingDate
            self.sourceContentHash = sourceContentHash
            self.generatorModelIdentifier = generatorModelIdentifier
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    @Model
    final class GeneratedDocument {
        @Attribute(.unique) var id: UUID
        var title: String
        var bodyMarkdown: String
        var userPrompt: String
        var sourceKindRaw: String
        var sourceNamesData: Data
        var sourceMeetingIDsData: Data
        var generatorModelIdentifier: String
        var createdAt: Date

        init(
            id: UUID = UUID(),
            title: String,
            bodyMarkdown: String,
            userPrompt: String,
            sourceKindRaw: String,
            sourceNamesData: Data,
            sourceMeetingIDsData: Data,
            generatorModelIdentifier: String,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.title = title
            self.bodyMarkdown = bodyMarkdown
            self.userPrompt = userPrompt
            self.sourceKindRaw = sourceKindRaw
            self.sourceNamesData = sourceNamesData
            self.sourceMeetingIDsData = sourceMeetingIDsData
            self.generatorModelIdentifier = generatorModelIdentifier
            self.createdAt = createdAt
        }
    }

    @Model
    final class ChatSession {
        @Attribute(.unique) var id: UUID
        var title: String
        var createdAt: Date
        var updatedAt: Date
        var meeting: Meeting?
        var turnsData: Data

        init(
            id: UUID = UUID(),
            meeting: Meeting?,
            title: String,
            createdAt: Date = Date(),
            updatedAt: Date? = nil,
            turnsData: Data = Data()
        ) {
            self.id = id
            self.title = title
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
            self.meeting = meeting
            self.turnsData = turnsData
        }
    }

    @Model
    final class MeetingPhoto {
        @Attribute(.unique) var id: UUID
        var recording: Recording?
        var fileName: String
        var capturedAt: TimeInterval
        var createdAt: Date
        var recognizedText: String?
        var photoDescription: String?
        var descriptionProviderID: String?

        init(
            id: UUID = UUID(),
            recording: Recording? = nil,
            fileName: String,
            capturedAt: TimeInterval,
            createdAt: Date = Date(),
            recognizedText: String? = nil,
            photoDescription: String? = nil,
            descriptionProviderID: String? = nil
        ) {
            self.id = id
            self.recording = recording
            self.fileName = fileName
            self.capturedAt = capturedAt
            self.createdAt = createdAt
            self.recognizedText = recognizedText
            self.photoDescription = photoDescription
            self.descriptionProviderID = descriptionProviderID
        }
    }

    @Model
    final class MeetingAttachment {
        @Attribute(.unique) var id: UUID
        var meeting: Meeting?
        var fileName: String
        var displayName: String
        var fileSize: Int64
        var pageCount: Int
        var extractedText: String?
        var createdAt: Date

        init(
            id: UUID = UUID(),
            meeting: Meeting? = nil,
            fileName: String,
            displayName: String,
            fileSize: Int64 = 0,
            pageCount: Int = 0,
            extractedText: String? = nil,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.meeting = meeting
            self.fileName = fileName
            self.displayName = displayName
            self.fileSize = fileSize
            self.pageCount = pageCount
            self.extractedText = extractedText
            self.createdAt = createdAt
        }
    }
}
