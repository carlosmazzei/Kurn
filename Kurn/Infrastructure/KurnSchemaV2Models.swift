//
//  KurnSchemaV2Models.swift
//  Kurn
//
//  Frozen copies of `KurnSchemaV2` (1.1.0)'s twelve `@Model` types exactly as
//  they were stored when V2 was the app's current schema — the same reason
//  `KurnSchemaV1Models.swift` exists for 1.0.0. Only the stored properties
//  matter here; computed accessors, extensions, and rich initializers live on
//  the live classes `KurnSchemaV3.models` points at. See that file's header
//  for the rules on why these must never be edited in place.
//

import Foundation
import SwiftData

extension KurnSchemaV2 {
    @Model
    final class Meeting {
        @Attribute(.unique) var id: UUID
        var title: String
        var createdAt: Date
        var notes: String
        var aiTitle: String?
        var languageRaw: String
        var isFavorite: Bool = false
        var archivedAt: Date?
        var folder: Folder?
        var tags: [Tag] = []

        @Relationship(deleteRule: .cascade, inverse: \Recording.meeting)
        var recordings: [Recording]

        @Relationship(deleteRule: .cascade, inverse: \Speaker.meeting)
        var speakers: [Speaker]

        @Relationship(deleteRule: .cascade, inverse: \Summary.owningMeeting)
        var summaries: [Summary]

        @Relationship(deleteRule: .cascade, inverse: \SemanticChunk.meeting)
        var semanticChunks: [SemanticChunk]

        @Relationship(deleteRule: .cascade, inverse: \WikiArticle.meeting)
        var wikiArticle: WikiArticle?

        @Relationship(deleteRule: .cascade, inverse: \ChatSession.meeting)
        var chatSessions: [ChatSession]

        var summaryMapCheckpointData: Data?

        init(
            id: UUID = UUID(),
            title: String,
            createdAt: Date = Date(),
            notes: String = "",
            languageRaw: String,
            isFavorite: Bool = false,
            archivedAt: Date? = nil,
            folder: Folder? = nil
        ) {
            self.id = id
            self.title = title
            self.createdAt = createdAt
            self.notes = notes
            self.languageRaw = languageRaw
            self.isFavorite = isFavorite
            self.archivedAt = archivedAt
            self.folder = folder
            self.recordings = []
            self.speakers = []
            self.summaries = []
            self.semanticChunks = []
            self.wikiArticle = nil
            self.chatSessions = []
        }
    }

    @Model
    final class Recording {
        @Attribute(.unique) var id: UUID
        var meeting: Meeting?
        var fileName: String
        var duration: TimeInterval
        var recordedAt: Date
        var transcriptionStatusRaw: String
        var transcriptionModeRaw: String
        var captureStateRaw: String = RecordingCaptureState.ready.rawValue
        var captureRecoveryReasonRaw: String?
        var transcriptionCheckpointData: Data?
        var automaticResumeAttempts: Int = 0
        var fileSize: Int64 = 0
        var enhancedAudioVersion: Int = 0
        var enhancedFileSize: Int64 = 0
        var highlightsData: Data = Data()
        var speakerVoiceprintsData: Data = Data()

        @Relationship(deleteRule: .cascade, inverse: \Transcript.recording)
        var transcript: Transcript?

        init(
            id: UUID = UUID(),
            meeting: Meeting? = nil,
            fileName: String,
            duration: TimeInterval,
            recordedAt: Date = Date(),
            transcriptionStatusRaw: String,
            transcriptionModeRaw: String,
            captureStateRaw: String = RecordingCaptureState.ready.rawValue,
            captureRecoveryReasonRaw: String? = nil,
            fileSize: Int64 = 0,
            highlightsData: Data = Data()
        ) {
            self.id = id
            self.meeting = meeting
            self.fileName = fileName
            self.duration = duration
            self.recordedAt = recordedAt
            self.transcriptionStatusRaw = transcriptionStatusRaw
            self.transcriptionModeRaw = transcriptionModeRaw
            self.captureStateRaw = captureStateRaw
            self.captureRecoveryReasonRaw = captureRecoveryReasonRaw
            self.fileSize = fileSize
            self.highlightsData = highlightsData
        }
    }

    @Model
    final class Transcript {
        @Attribute(.unique) var id: UUID
        var recording: Recording?
        var segmentsData: Data
        var language: String
        var pipelineReportData: Data?
        var createdAt: Date

        init(
            id: UUID = UUID(),
            recording: Recording? = nil,
            segmentsData: Data,
            language: String = "",
            pipelineReportData: Data? = nil,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.recording = recording
            self.segmentsData = segmentsData
            self.language = language
            self.pipelineReportData = pipelineReportData
            self.createdAt = createdAt
        }
    }

    @Model
    final class Speaker {
        @Attribute(.unique) var id: UUID
        var meeting: Meeting?
        var label: String
        var name: String
        var color: String
        var voiceprintData: Data?

        init(
            id: UUID = UUID(),
            meeting: Meeting? = nil,
            label: String,
            name: String = "",
            color: String,
            voiceprintData: Data? = nil
        ) {
            self.id = id
            self.meeting = meeting
            self.label = label
            self.name = name
            self.color = color
            self.voiceprintData = voiceprintData
        }
    }

    @Model
    final class Summary {
        @Attribute(.unique) var id: UUID
        var owningMeeting: Meeting?
        var sectionsData: Data = Data()
        var templateName: String?
        var providerRaw: String
        var modelRaw: String?
        var createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            meeting: Meeting? = nil,
            sectionsData: Data = Data(),
            templateName: String? = nil,
            providerRaw: String,
            modelRaw: String? = nil,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.owningMeeting = meeting
            self.sectionsData = sectionsData
            self.templateName = templateName
            self.providerRaw = providerRaw
            self.modelRaw = modelRaw
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    @Model
    final class Folder {
        @Attribute(.unique) var id: UUID
        var name: String
        var iconName: String
        var colorHex: String
        var createdAt: Date
        var parent: Folder?

        @Relationship(deleteRule: .nullify, inverse: \Folder.parent)
        var children: [Folder] = []

        @Relationship(deleteRule: .nullify, inverse: \Meeting.folder)
        var meetings: [Meeting] = []

        init(
            id: UUID = UUID(),
            name: String,
            iconName: String,
            colorHex: String,
            createdAt: Date = Date(),
            parent: Folder? = nil
        ) {
            self.id = id
            self.name = name
            self.iconName = iconName
            self.colorHex = colorHex
            self.createdAt = createdAt
            self.parent = parent
        }
    }

    @Model
    final class Tag {
        @Attribute(.unique) var id: UUID
        var name: String
        var colorHex: String
        var createdAt: Date

        @Relationship(deleteRule: .nullify, inverse: \Meeting.tags)
        var meetings: [Meeting] = []

        init(
            id: UUID = UUID(),
            name: String,
            colorHex: String,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            self.colorHex = colorHex
            self.createdAt = createdAt
        }
    }

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
}
