//
//  KurnSchemaV1.swift
//  Kurn
//
//  Snapshot of the on-disk model layout immediately before the `Folder` entity
//  was introduced (post-PR-2a). Holding it here lets `KurnMigrationPlan` map
//  any V1 store to the current V2 layout via a lightweight migration. Once
//  there are no devices running the pre-Folder build the world can let V1 go,
//  but it is cheap to keep and avoids data loss on unexpected downgrades.
//
//  These types are intentionally **nested** inside the enum and never used by
//  app code. Top-level `Meeting`, `Recording`, `Transcript`, `Speaker`,
//  `Summary` (in `Models/`) represent V2.
//

import Foundation
import SwiftData

enum KurnSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Meeting.self, Recording.self, Transcript.self, Speaker.self, Summary.self]
    }

    // MARK: - Meeting (V1)
    //
    // Pre-Folder. Carries the lightweight-additive `isFavorite` and
    // `archivedAt` added in PR 2a so the V1 → V2 mapping for those fields is
    // a no-op; only `folder` is genuinely new in V2.

    @Model
    final class Meeting {
        @Attribute(.unique) var id: UUID
        var title: String
        var createdAt: Date
        var notes: String
        var languageRaw: String
        var isFavorite: Bool = false
        var archivedAt: Date?

        @Relationship(deleteRule: .cascade, inverse: \Recording.meeting)
        var recordings: [Recording]
        @Relationship(deleteRule: .cascade, inverse: \Speaker.meeting)
        var speakers: [Speaker]
        @Relationship(deleteRule: .cascade, inverse: \Summary.meeting)
        var summary: Summary?

        init(
            id: UUID = UUID(),
            title: String,
            createdAt: Date = Date(),
            notes: String = "",
            languageRaw: String = "",
            isFavorite: Bool = false,
            archivedAt: Date? = nil
        ) {
            self.id = id
            self.title = title
            self.createdAt = createdAt
            self.notes = notes
            self.languageRaw = languageRaw
            self.isFavorite = isFavorite
            self.archivedAt = archivedAt
            self.recordings = []
            self.speakers = []
            self.summary = nil
        }
    }

    // MARK: - Recording (V1, unchanged from V2)

    @Model
    final class Recording {
        @Attribute(.unique) var id: UUID
        var meeting: Meeting?
        var fileName: String
        var duration: TimeInterval
        var recordedAt: Date
        var transcriptionStatusRaw: String
        var transcriptionModeRaw: String

        @Relationship(deleteRule: .cascade, inverse: \Transcript.recording)
        var transcript: Transcript?

        init(
            id: UUID = UUID(),
            meeting: Meeting? = nil,
            fileName: String,
            duration: TimeInterval,
            recordedAt: Date = Date(),
            transcriptionStatusRaw: String = "",
            transcriptionModeRaw: String = ""
        ) {
            self.id = id
            self.meeting = meeting
            self.fileName = fileName
            self.duration = duration
            self.recordedAt = recordedAt
            self.transcriptionStatusRaw = transcriptionStatusRaw
            self.transcriptionModeRaw = transcriptionModeRaw
        }
    }

    // MARK: - Transcript (V1, unchanged from V2)

    @Model
    final class Transcript {
        @Attribute(.unique) var id: UUID
        var recording: Recording?
        var segmentsData: Data
        var language: String
        var createdAt: Date

        init(
            id: UUID = UUID(),
            recording: Recording? = nil,
            segmentsData: Data = Data(),
            language: String = "",
            createdAt: Date = Date()
        ) {
            self.id = id
            self.recording = recording
            self.segmentsData = segmentsData
            self.language = language
            self.createdAt = createdAt
        }
    }

    // MARK: - Speaker (V1, unchanged from V2)

    @Model
    final class Speaker {
        @Attribute(.unique) var id: UUID
        var meeting: Meeting?
        var label: String
        var name: String
        var color: String

        init(
            id: UUID = UUID(),
            meeting: Meeting? = nil,
            label: String,
            name: String = "",
            color: String
        ) {
            self.id = id
            self.meeting = meeting
            self.label = label
            self.name = name
            self.color = color
        }
    }

    // MARK: - Summary (V1, unchanged from V2)

    @Model
    final class Summary {
        @Attribute(.unique) var id: UUID
        var meeting: Meeting?
        private var sectionsData: Data = Data()
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
            providerRaw: String = "",
            modelRaw: String? = nil,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.meeting = meeting
            self.sectionsData = sectionsData
            self.templateName = templateName
            self.providerRaw = providerRaw
            self.modelRaw = modelRaw
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }
}
