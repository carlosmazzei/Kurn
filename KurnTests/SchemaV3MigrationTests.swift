//
//  SchemaV3MigrationTests.swift
//  KurnTests
//
//  A store written at `KurnSchemaV3` (1.2.0) — the shape every install had
//  before meetings could carry attached documents — opened through the
//  current versioned schema and migration plan. The store is built at run
//  time from the frozen `KurnSchemaV3.*` classes, one row of every entity,
//  for the same reason `LegacyStoreAdoptionTests` builds its V1 fixture that
//  way: a hand-crafted binary store cannot be produced or checked without
//  Xcode, and the live classes already carry `Meeting.attachments`, so a
//  store written with them would be a V4 store and test nothing.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct SchemaV3MigrationTests {

    private func writeV3Store(at url: URL) throws {
        let schema = Schema(versionedSchema: KurnSchemaV3.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let context = container.mainContext
        let created = Date(timeIntervalSince1970: 1_750_000_000)

        let folder = KurnSchemaV3.Folder(name: "Clients", iconName: "folder.fill", colorHex: "#5E5CE6", createdAt: created)
        let tag = KurnSchemaV3.Tag(name: "Q3", colorHex: "#FF9500", createdAt: created)
        let meeting = KurnSchemaV3.Meeting(
            title: "Before attachments",
            createdAt: created,
            notes: "Written at 1.2.0.",
            languageRaw: MeetingLanguage.portuguese.rawValue,
            isFavorite: true,
            archivedAt: nil,
            folder: folder
        )
        meeting.tags = [tag]
        context.insert(folder)
        context.insert(tag)
        context.insert(meeting)

        let recording = KurnSchemaV3.Recording(
            meeting: meeting,
            fileName: "v3.m4a",
            duration: 90,
            recordedAt: created,
            transcriptionStatusRaw: TranscriptionStatus.done.rawValue,
            transcriptionModeRaw: TranscriptionMode.onDevice.rawValue,
            captureStateRaw: RecordingCaptureState.ready.rawValue,
            captureRecoveryReasonRaw: nil,
            fileSize: 1_000,
            highlightsData: JSONStorage.encode([Highlight(timestamp: 4)])
        )
        context.insert(recording)
        let segments = [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 4, text: "Olá a todos.")]
        context.insert(KurnSchemaV3.Transcript(
            recording: recording,
            segmentsData: JSONStorage.encodeAuthoritative(segments) ?? Data(),
            language: "pt",
            pipelineReportData: nil,
            createdAt: created
        ))
        context.insert(KurnSchemaV3.MeetingPhoto(
            recording: recording,
            fileName: "v3.jpg",
            capturedAt: 2,
            createdAt: created,
            recognizedText: "Roadmap",
            photoDescription: nil,
            descriptionProviderID: nil
        ))
        context.insert(KurnSchemaV3.Speaker(meeting: meeting, label: "Speaker 1", name: "Ana", color: "#34C759"))
        context.insert(KurnSchemaV3.Summary(
            meeting: meeting,
            sectionsData: JSONStorage.encodeAuthoritative([SummarySection(title: "Overview", body: "Hi")]) ?? Data(),
            templateName: "General",
            providerRaw: AIProvider.openAI.rawValue,
            modelRaw: "gpt-5.4",
            createdAt: created,
            updatedAt: created
        ))
        context.insert(KurnSchemaV3.SmartFolder(
            name: "Favorites",
            iconName: "star",
            colorHex: "#FFCC00",
            predicateData: JSONStorage.encode(MeetingFilter()),
            createdAt: created
        ))
        context.insert(KurnSchemaV3.SemanticChunk(
            meeting: meeting,
            recordingID: recording.id,
            text: "Olá a todos.",
            startTime: 0,
            endTime: 4,
            speakerLabel: "Speaker 1",
            vectorData: VectorData.encode([0.5, 0.5]),
            dimension: 2,
            modelIdentifier: "embedder-v1",
            createdAt: created
        ))
        context.insert(KurnSchemaV3.WikiArticle(
            meeting: meeting,
            bodyMarkdown: "# Notes",
            meetingTitleSnapshot: meeting.title,
            meetingDate: created,
            sourceContentHash: "v3-hash",
            generatorModelIdentifier: "openAI:gpt-5.4:wiki-v1",
            createdAt: created,
            updatedAt: created
        ))
        context.insert(KurnSchemaV3.GeneratedDocument(
            title: "Digest",
            bodyMarkdown: "# Digest",
            userPrompt: "Summarize",
            sourceKindRaw: DocumentSourceKind.transcripts.rawValue,
            sourceNamesData: JSONStorage.encode([meeting.title]),
            sourceMeetingIDsData: JSONStorage.encode([meeting.id]),
            generatorModelIdentifier: "openAI:gpt-5.4",
            createdAt: created
        ))
        context.insert(KurnSchemaV3.ChatSession(
            meeting: meeting,
            title: "Questions",
            createdAt: created,
            updatedAt: nil,
            turnsData: Data()
        ))
        try context.save()
    }

    @Test func aV3StoreMigratesToTheCurrentSchemaWithoutDataLoss() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaV3MigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("v3.store")

        try writeV3Store(at: storeURL)

        let container = try ModelContainer(
            for: KurnModelGraph.schema,
            migrationPlan: KurnModelGraph.migrationPlan,
            configurations: [ModelConfiguration(schema: KurnModelGraph.schema, url: storeURL)]
        )
        let context = container.mainContext

        let meeting = try #require(try context.fetch(FetchDescriptor<Meeting>()).first)
        #expect(meeting.title == "Before attachments")
        #expect(meeting.language == .portuguese)
        #expect(meeting.folder?.name == "Clients")
        #expect(meeting.tags.map(\.name) == ["Q3"])
        #expect(meeting.speakers.map(\.name) == ["Ana"])
        #expect(meeting.summaries.map(\.templateName) == ["General"])
        #expect(meeting.semanticChunks.count == 1)
        #expect(meeting.wikiArticle?.sourceContentHash == "v3-hash")
        #expect(meeting.chatSessions.map(\.title) == ["Questions"])
        let recording = try #require(meeting.recordings.first)
        #expect(recording.transcript?.segments.map(\.text) == ["Olá a todos."])
        #expect(recording.photos.map(\.recognizedText) == ["Roadmap"])
        #expect(try context.fetch(FetchDescriptor<SmartFolder>()).map(\.name) == ["Favorites"])
        #expect(try context.fetch(FetchDescriptor<GeneratedDocument>()).map(\.title) == ["Digest"])

        // The V4 addition is present and usable on the migrated store.
        #expect(meeting.attachments.isEmpty)
        let attachment = MeetingAttachment(
            meeting: meeting, fileName: "after.pdf", displayName: "Agenda.pdf", pageCount: 2, extractedText: "Budget"
        )
        context.insert(attachment)
        try context.save()
        #expect(meeting.attachments.map(\.displayName) == ["Agenda.pdf"])
        #expect(meeting.assembledContextText().contains("=== 📄 Document: Agenda.pdf ===\nBudget"))
    }

    @Test func theCurrentSchemaIsV4AndAddsOnlyTheAttachmentEntity() {
        #expect(KurnModelGraph.currentSchemaVersion == Schema.Version(1, 3, 0))
        let frozen = Set(Schema(KurnSchemaV3.models).entities.map(\.name))
        let current = Set(KurnModelGraph.schema.entities.map(\.name))
        #expect(current.subtracting(frozen) == ["MeetingAttachment"])
        let liveIdentifiers = Set(KurnSchemaV4.models.map { ObjectIdentifier($0) })
        #expect(KurnSchemaV3.models.allSatisfy { !liveIdentifiers.contains(ObjectIdentifier($0)) })
    }
}
