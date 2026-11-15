import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct SchemaV5MigrationTests {
    private func writeV5(_ url: URL, sessionID: UUID, turnID: UUID, artifact: ChatDocumentArtifact) throws -> Data {
        let schema = Schema(versionedSchema: KurnSchemaV5.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        return try withExtendedLifetime(container) {
            let context = container.mainContext
            seedFrozenGraph(context)
            let turns = [PersistedChatTurn(id: turnID, role: .user, text: "Saved before V6", usage: nil, costUSD: nil, elapsedSeconds: nil)]
            let raw = try HarnessPresentationCodec.encode(turns)
            let session = KurnSchemaV5.ChatSession(id: sessionID, meeting: nil, title: "V5", turnsData: raw)
            session.scopeData = JSONStorage.encodeAuthoritative(ChatSourceScope(kind: .library, parts: [.transcript, .summary]))
            session.artifactsData = JSONStorage.encodeAuthoritative([artifact])
            context.insert(session)
            let document = KurnSchemaV5.GeneratedDocument(title: "Independent", bodyMarkdown: "# Saved", userPrompt: "Prompt",
                sourceKindRaw: DocumentSourceKind.transcripts.rawValue, sourceNamesData: JSONStorage.encode(["Source"]),
                sourceMeetingIDsData: JSONStorage.encode([UUID]()), generatorModelIdentifier: "old-model")
            document.sourceChatSessionID = sessionID; document.sourceArtifactID = artifact.id; document.sourceArtifactVersion = artifact.version
            context.insert(document)
            try context.save()
            return raw
        }
    }

    private func seedFrozenGraph(_ context: ModelContext) {
        let created = Date(timeIntervalSince1970: 1_750_000_000)

        let folder = KurnSchemaV5.Folder(name: "Clients", iconName: "folder.fill", colorHex: "#5E5CE6", createdAt: created)
        let tag = KurnSchemaV5.Tag(name: "Q3", colorHex: "#FF9500", createdAt: created)
        let meeting = KurnSchemaV5.Meeting(
            title: "Before harness chat",
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

        let recording = KurnSchemaV5.Recording(
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
        context.insert(KurnSchemaV5.Transcript(
            recording: recording,
            segmentsData: JSONStorage.encodeAuthoritative(segments) ?? Data(),
            language: "pt",
            pipelineReportData: nil,
            createdAt: created
        ))
        context.insert(KurnSchemaV5.MeetingPhoto(
            recording: recording,
            fileName: "v3.jpg",
            capturedAt: 2,
            createdAt: created,
            recognizedText: "Roadmap",
            photoDescription: nil,
            descriptionProviderID: nil
        ))
        context.insert(KurnSchemaV5.Speaker(meeting: meeting, label: "Speaker 1", name: "Ana", color: "#34C759"))
        context.insert(KurnSchemaV5.Summary(
            meeting: meeting,
            sectionsData: JSONStorage.encodeAuthoritative([SummarySection(title: "Overview", body: "Hi")]) ?? Data(),
            templateName: "General",
            providerRaw: AIProvider.openAI.rawValue,
            modelRaw: "gpt-5.4",
            createdAt: created,
            updatedAt: created
        ))
        context.insert(KurnSchemaV5.SmartFolder(
            name: "Favorites",
            iconName: "star",
            colorHex: "#FFCC00",
            predicateData: JSONStorage.encode(MeetingFilter()),
            createdAt: created
        ))
        context.insert(KurnSchemaV5.SemanticChunk(
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
        context.insert(KurnSchemaV5.WikiArticle(
            meeting: meeting,
            bodyMarkdown: "# Notes",
            meetingTitleSnapshot: meeting.title,
            meetingDate: created,
            sourceContentHash: "v3-hash",
            generatorModelIdentifier: "openAI:gpt-5.4:wiki-v1",
            createdAt: created,
            updatedAt: created
        ))
        context.insert(KurnSchemaV5.MeetingAttachment(meeting: meeting, fileName: "v4.pdf", displayName: "Agenda", extractedText: "Budget"))
    }

    private func open(_ url: URL) throws -> ModelContainer {
        try ModelContainer(for: KurnModelGraph.schema, migrationPlan: KurnModelGraph.migrationPlan,
            configurations: [ModelConfiguration(schema: KurnModelGraph.schema, url: url)])
    }

    @Test func realV5DiskUpgradeConversionAndRepeatedReopenPreserveIdentityScopeArtifactsAndBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HarnessV6-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("v5.store")
        let sessionID = UUID(); let turnID = UUID()
        let artifact = ChatDocumentArtifact(title: "Minutes", markdown: "# Decisions", version: 4)
        let original = try writeV5(url, sessionID: sessionID, turnID: turnID, artifact: artifact)
        try convert(url, sessionID: sessionID)
        let container = try open(url)
        try withExtendedLifetime(container) {
            let session = try #require(try container.mainContext.fetch(FetchDescriptor<ChatSession>()).first)
            #expect(session.id == sessionID && session.legacyTurnsData == original)
            let store = SwiftDataAgentSessionStore(context: container.mainContext)
            let before = try store.snapshot(session)
            try store.migrate(session)
            #expect(try store.snapshot(session).entries == before.entries)
            let value = try session.harnessSnapshot()
            #expect(value.turns.first?.id == turnID && value.turns.first?.text == "Saved before V6")
            #expect(value.scope?.parts == [.transcript, .summary] && value.artifacts == [artifact])
            let document = try #require(try container.mainContext.fetch(FetchDescriptor<GeneratedDocument>()).first)
            #expect(document.sourceChatSessionID == sessionID && document.sourceArtifactVersion == 4 && document.bodyMarkdown == "# Saved")
        }
    }

    private func convert(_ url: URL, sessionID: UUID) throws {
        let container = try open(url)
        try withExtendedLifetime(container) {
            let context = container.mainContext
            let session = try #require(try context.fetch(FetchDescriptor<ChatSession>()).first)
            #expect(session.id == sessionID && session.canonicalVersion == nil)
            try SwiftDataAgentSessionStore(context: context).migrate(session)
        }
    }

    @Test func frozenV5RemainsIndependentAndOnlyV6ContainsCanonicalStorage() throws {
        let old = Schema(versionedSchema: KurnSchemaV5.self)
        let oldChat = try #require(old.entities.first { $0.name == "ChatSession" })
        #expect(oldChat.attributes.contains { $0.name == "scopeData" })
        #expect(!oldChat.attributes.contains { $0.name == "canonicalVersion" || $0.name == "legacyTurnsData" })
        #expect(!old.entities.contains { $0.name == "HarnessSessionEntry" })
        #expect(Set(KurnModelGraph.schema.entities.map(\.name)).isSuperset(of: old.entities.map(\.name)))
        #expect(KurnModelGraph.currentSchemaVersion == Schema.Version(1, 5, 0))
    }
}
