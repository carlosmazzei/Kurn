//
//  SchemaV6MigrationTests.swift
//  KurnTests
//
//  V7 (1.6.0) adds the Knowledge Engine's canonical layer. A store written by
//  the frozen V6 graph — every V6 entity, the canonical harness rows included —
//  must open through the migration plan with nothing lost, start with an empty
//  knowledge layer (no meeting gets a context row: no link means `unknown`),
//  accept every knowledge model, and reopen with them intact.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct SchemaV6MigrationTests {
    private struct Seeded {
        let meetingID: UUID
        let sessionID: UUID
    }

    @Test func realV6DiskUpgradeKeepsEveryEntityAndAcceptsKnowledge() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeV7-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("v6.store")
        let seeded = try writeV6(url)

        let assertionID = try withOpen(url) { context in
            let meeting = try #require(try context.fetch(FetchDescriptor<Meeting>()).first)
            #expect(meeting.id == seeded.meetingID && meeting.title == "Before knowledge" && meeting.isFavorite)
            #expect(meeting.recordings.first?.transcript != nil)
            #expect(meeting.speakers.first?.name == "Ana" && meeting.summaries.count == 1)
            #expect(meeting.semanticChunks.count == 1 && meeting.wikiArticle?.bodyMarkdown == "# Notes")
            #expect(meeting.attachments.first?.displayName == "Agenda")
            #expect(meeting.recordings.first?.photos.count == 1)
            #expect(meeting.folder?.name == "Clients" && meeting.tags.map(\.name) == ["Q3"])
            #expect(try context.fetchCount(FetchDescriptor<SmartFolder>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<GeneratedDocument>()) == 1)

            let session = try #require(try context.fetch(FetchDescriptor<ChatSession>()).first)
            #expect(session.id == seeded.sessionID && session.canonicalVersion == 1 && session.canonicalRevision == 3)
            #expect(session.harnessEntries.count == 1 && session.harnessRevisions.count == 1 && session.harnessRecords.count == 1)
            #expect(session.harnessEntries.first?.kindRaw == "agent.message.v1")

            for type in KnowledgeTestRows.modelTypes {
                #expect(try KnowledgeTestRows.count(type, in: context) == 0, "\(type) should start empty")
            }
            let assertion = KnowledgeTestRows.insertOneOfEach(meetingID: meeting.id, in: context)
            try context.save()
            return assertion.id
        }

        try withOpen(url) { context in
            for type in KnowledgeTestRows.modelTypes {
                #expect(try KnowledgeTestRows.count(type, in: context) == 1, "\(type) did not survive a reopen")
            }
            let assertion = try #require(try context.fetch(FetchDescriptor<KnowledgeAssertion>()).first)
            #expect(assertion.id == assertionID && assertion.sourceMeetingID == seeded.meetingID)
            #expect(assertion.predicateRaw == "owns" && assertion.predicateRegistryVersion == KnowledgePredicate.registryVersion)
            #expect(assertion.validFromText == "2026-11" && assertion.validFromPrecisionRaw == "month")
            #expect(assertion.retractedAt == nil && assertion.reviewStateRaw == "machineExtracted")
            let job = try #require(try context.fetch(FetchDescriptor<KnowledgeJob>()).first)
            #expect(job.stateRaw == "pending" && job.attempts == 0 && job.kindRaw == "extraction")
            let revision = try #require(try context.fetch(FetchDescriptor<KnowledgeRevision>()).first)
            #expect(revision.projectionPending && revision.number == 1)
            let review = try #require(try context.fetch(FetchDescriptor<KnowledgeReview>()).first)
            #expect(review.stateRaw == "open" && review.resolvedAt == nil)
            let occasion = try #require(try context.fetch(FetchDescriptor<KnowledgeContext>()).first)
            #expect(occasion.classificationRaw == KnowledgeClassification.`internal`.rawValue)
            let evidence = try #require(try context.fetch(FetchDescriptor<KnowledgeEvidence>()).first)
            #expect(evidence.isAvailable && evidence.assertionID == assertionID)
        }
    }

    @Test func theSameWorkAndTheSameRevisionNumberCanOnlyBeStoredOnce() throws {
        let schema = KurnModelGraph.schema
        func isUnique(_ entity: String, _ attribute: String) -> Bool {
            let found = schema.entities.first { $0.name == entity }?.attributes.first { $0.name == attribute }
            return found?.options.contains(.unique) == true
        }
        #expect(isUnique("KnowledgeJob", "idempotencyKey"))
        #expect(isUnique("KnowledgeRevision", "number"))
        for name in ["KnowledgeEntity", "KnowledgeAssertion", "KnowledgeEvidence", "KnowledgeEvent", "KnowledgeRelation",
                     "KnowledgeJob", "KnowledgeRevision", "KnowledgeReview", "KnowledgeContext", "SourceContextLink"] {
            #expect(isUnique(name, "id"), "\(name).id must be unique")
        }
    }

    @Test func frozenV6KeepsHarnessStorageAndOnlyV7HasKnowledge() throws {
        #expect(KurnModelGraph.currentSchemaVersion == Schema.Version(1, 6, 0))
        let v6 = Schema(versionedSchema: KurnSchemaV6.self)
        let v6Names = Set(v6.entities.map(\.name))
        #expect(v6Names.contains("HarnessSessionEntry") && v6Names.contains("ChatSession"))
        #expect(!v6Names.contains { $0.hasPrefix("Knowledge") } && !v6Names.contains("SourceContextLink"))
        let v6Chat = try #require(v6.entities.first { $0.name == "ChatSession" })
        #expect(v6Chat.attributes.contains { $0.name == "canonicalRevision" })

        let added = Set(KurnModelGraph.schema.entities.map(\.name)).subtracting(v6Names)
        #expect(added == [
            "KnowledgeEntity", "KnowledgeAssertion", "KnowledgeEvidence", "KnowledgeEvent", "KnowledgeRelation",
            "KnowledgeJob", "KnowledgeRevision", "KnowledgeReview", "KnowledgeContext", "SourceContextLink"
        ])
        // No existing entity gains a relationship into the knowledge layer.
        for entity in KurnModelGraph.schema.entities where v6Names.contains(entity.name) {
            #expect(!entity.relationships.contains { added.contains($0.destination) }, "\(entity.name) points into knowledge")
        }
    }

    // MARK: - Fixture

    private func withOpen<T>(_ url: URL, _ body: (ModelContext) throws -> T) throws -> T {
        let container = try ModelContainer(
            for: KurnModelGraph.schema, migrationPlan: KurnModelGraph.migrationPlan,
            configurations: [ModelConfiguration(schema: KurnModelGraph.schema, url: url)]
        )
        return try withExtendedLifetime(container) { try body(container.mainContext) }
    }

    private func writeV6(_ url: URL) throws -> Seeded {
        let schema = Schema(versionedSchema: KurnSchemaV6.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        return try withExtendedLifetime(container) {
            let context = container.mainContext
            let meeting = seedMeeting(context)
            let session = seedHarness(context)
            try context.save()
            return Seeded(meetingID: meeting.id, sessionID: session.id)
        }
    }

    private func seedHarness(_ context: ModelContext) -> KurnSchemaV6.ChatSession {
        let session = KurnSchemaV6.ChatSession(meeting: nil, title: "V6 chat", turnsData: Data("[]".utf8))
        session.canonicalVersion = 1
        session.canonicalLeafID = "e1"
        session.canonicalOrdinal = 1
        session.canonicalRevision = 3
        session.legacyTurnsData = Data("[]".utf8)
        context.insert(session)
        let entry = KurnSchemaV6.HarnessSessionEntry(
            session: session, entryID: "e1", parentEntryID: nil, ordinal: 1,
            kindRaw: "agent.message.v1", createdAtUTC: "2026-11-15T00:00:00Z", payloadData: Data("{}".utf8)
        )
        let revision = KurnSchemaV6.HarnessArtifactRevision(
            session: session, artifactID: UUID(), version: 1, payloadData: Data("{}".utf8)
        )
        let record = KurnSchemaV6.HarnessSessionRecord(
            session: session, recordID: "r1", kindRaw: "draft", payloadData: Data("{}".utf8)
        )
        context.insert(entry)
        context.insert(revision)
        context.insert(record)
        entry.session = session
        revision.session = session
        record.session = session
        return session
    }

    private func seedMeeting(_ context: ModelContext) -> KurnSchemaV6.Meeting {
        let created = Date(timeIntervalSince1970: 1_760_000_000)
        let folder = KurnSchemaV6.Folder(name: "Clients", iconName: "folder.fill", colorHex: "#5E5CE6", createdAt: created)
        let tag = KurnSchemaV6.Tag(name: "Q3", colorHex: "#FF9500", createdAt: created)
        let meeting = KurnSchemaV6.Meeting(
            title: "Before knowledge", createdAt: created, notes: "Written at 1.5.0.",
            languageRaw: MeetingLanguage.english.rawValue, isFavorite: true, archivedAt: nil, folder: folder
        )
        meeting.tags = [tag]
        context.insert(folder)
        context.insert(tag)
        context.insert(meeting)

        let recording = KurnSchemaV6.Recording(
            meeting: meeting, fileName: "v6.m4a", duration: 90, recordedAt: created,
            transcriptionStatusRaw: TranscriptionStatus.done.rawValue,
            transcriptionModeRaw: TranscriptionMode.onDevice.rawValue,
            captureStateRaw: RecordingCaptureState.ready.rawValue, captureRecoveryReasonRaw: nil,
            fileSize: 1_000, highlightsData: JSONStorage.encode([Highlight(timestamp: 4)])
        )
        context.insert(recording)
        let segments = [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 4, text: "Hello all.")]
        context.insert(KurnSchemaV6.Transcript(
            recording: recording, segmentsData: JSONStorage.encodeAuthoritative(segments) ?? Data(),
            language: "en", pipelineReportData: nil, createdAt: created
        ))
        context.insert(KurnSchemaV6.MeetingPhoto(
            recording: recording, fileName: "v6.jpg", capturedAt: 2, createdAt: created,
            recognizedText: "Roadmap", photoDescription: nil, descriptionProviderID: nil
        ))
        context.insert(KurnSchemaV6.Speaker(meeting: meeting, label: "Speaker 1", name: "Ana", color: "#34C759"))
        context.insert(KurnSchemaV6.Summary(
            meeting: meeting,
            sectionsData: JSONStorage.encodeAuthoritative([SummarySection(title: "Overview", body: "Hi")]) ?? Data(),
            templateName: "General", providerRaw: AIProvider.openAI.rawValue, modelRaw: "gpt-5.4",
            createdAt: created, updatedAt: created
        ))
        context.insert(KurnSchemaV6.SmartFolder(
            name: "Favorites", iconName: "star", colorHex: "#FFCC00",
            predicateData: JSONStorage.encode(MeetingFilter()), createdAt: created
        ))
        context.insert(KurnSchemaV6.SemanticChunk(
            meeting: meeting, recordingID: recording.id, text: "Hello all.", startTime: 0, endTime: 4,
            speakerLabel: "Speaker 1", vectorData: VectorData.encode([0.5, 0.5]), dimension: 2,
            modelIdentifier: "embedder-v1", createdAt: created
        ))
        context.insert(KurnSchemaV6.WikiArticle(
            meeting: meeting, bodyMarkdown: "# Notes", meetingTitleSnapshot: meeting.title, meetingDate: created,
            sourceContentHash: "v6-hash", generatorModelIdentifier: "openAI:gpt-5.4:wiki-v1",
            createdAt: created, updatedAt: created
        ))
        context.insert(KurnSchemaV6.MeetingAttachment(meeting: meeting, fileName: "v6.pdf", displayName: "Agenda", extractedText: "Budget"))
        context.insert(KurnSchemaV6.GeneratedDocument(
            title: "Independent", bodyMarkdown: "# Saved", userPrompt: "Prompt",
            sourceKindRaw: DocumentSourceKind.transcripts.rawValue, sourceNamesData: JSONStorage.encode(["Source"]),
            sourceMeetingIDsData: JSONStorage.encode([UUID]()), generatorModelIdentifier: "old-model"
        ))
        return meeting
    }
}
