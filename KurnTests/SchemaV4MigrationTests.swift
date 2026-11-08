import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct SchemaV4MigrationTests {

    private func writeV4Store(at url: URL) throws {
        let schema = Schema(versionedSchema: KurnSchemaV4.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let context = container.mainContext
        let created = Date(timeIntervalSince1970: 1_750_000_000)

        let folder = KurnSchemaV4.Folder(name: "Clients", iconName: "folder.fill", colorHex: "#5E5CE6", createdAt: created)
        let tag = KurnSchemaV4.Tag(name: "Q3", colorHex: "#FF9500", createdAt: created)
        let meeting = KurnSchemaV4.Meeting(
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

        let recording = KurnSchemaV4.Recording(
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
        context.insert(KurnSchemaV4.Transcript(
            recording: recording,
            segmentsData: JSONStorage.encodeAuthoritative(segments) ?? Data(),
            language: "pt",
            pipelineReportData: nil,
            createdAt: created
        ))
        context.insert(KurnSchemaV4.MeetingPhoto(
            recording: recording,
            fileName: "v3.jpg",
            capturedAt: 2,
            createdAt: created,
            recognizedText: "Roadmap",
            photoDescription: nil,
            descriptionProviderID: nil
        ))
        context.insert(KurnSchemaV4.Speaker(meeting: meeting, label: "Speaker 1", name: "Ana", color: "#34C759"))
        context.insert(KurnSchemaV4.Summary(
            meeting: meeting,
            sectionsData: JSONStorage.encodeAuthoritative([SummarySection(title: "Overview", body: "Hi")]) ?? Data(),
            templateName: "General",
            providerRaw: AIProvider.openAI.rawValue,
            modelRaw: "gpt-5.4",
            createdAt: created,
            updatedAt: created
        ))
        context.insert(KurnSchemaV4.SmartFolder(
            name: "Favorites",
            iconName: "star",
            colorHex: "#FFCC00",
            predicateData: JSONStorage.encode(MeetingFilter()),
            createdAt: created
        ))
        context.insert(KurnSchemaV4.SemanticChunk(
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
        context.insert(KurnSchemaV4.WikiArticle(
            meeting: meeting,
            bodyMarkdown: "# Notes",
            meetingTitleSnapshot: meeting.title,
            meetingDate: created,
            sourceContentHash: "v3-hash",
            generatorModelIdentifier: "openAI:gpt-5.4:wiki-v1",
            createdAt: created,
            updatedAt: created
        ))
        context.insert(KurnSchemaV4.GeneratedDocument(
            title: "Digest",
            bodyMarkdown: "# Digest",
            userPrompt: "Summarize",
            sourceKindRaw: DocumentSourceKind.transcripts.rawValue,
            sourceNamesData: JSONStorage.encode([meeting.title]),
            sourceMeetingIDsData: JSONStorage.encode([meeting.id]),
            generatorModelIdentifier: "openAI:gpt-5.4",
            createdAt: created
        ))
        context.insert(KurnSchemaV4.ChatSession(
            meeting: meeting,
            title: "Questions",
            createdAt: created,
            updatedAt: nil,
            turnsData: JSONStorage.encodeAuthoritative([PersistedChatTurn(id: UUID(), role: .user, text: "Legacy question", usage: nil, costUSD: nil, elapsedSeconds: nil)]) ?? Data()
        ))
        context.insert(KurnSchemaV4.MeetingAttachment(meeting: meeting, fileName: "v4.pdf", displayName: "Agenda", extractedText: "Budget"))
        try context.save()
    }
    @Test func v4MigratesAndV5HarnessStateSurvivesReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SchemaV4-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("v4.store")
        try writeV4Store(at: url)
        let artifact = ChatDocumentArtifact(title: "Minutes", markdown: "# Decisions", version: 3)
        let sessionID = try migrateAndWriteHarnessState(at: url, artifact: artifact)

        let container = try openCurrentStore(at: url)
        let context = container.mainContext
        let session = try #require(try context.fetch(FetchDescriptor<ChatSession>()).first)
        let restored = try session.harnessSnapshot()
        #expect(session.id == sessionID)
        #expect(restored.artifacts == [artifact])
        #expect(restored.scope?.parts == [.transcript, .summary])
        #expect(session.turns.first?.steps?.first?.toolName == "create_document")
        let document = try #require(try context.fetch(FetchDescriptor<GeneratedDocument>()).first)
        #expect(document.sourceChatSessionID == sessionID)
        #expect(document.sourceArtifactID == artifact.id)
        #expect(document.sourceArtifactVersion == 3)
        let vm = MeetingChatViewModel()
        vm.configure(meeting: session.meeting, modelContext: context)
        vm.load(session: session)
        #expect(vm.artifacts == [artifact])
        #expect(vm.scope.parts == [.transcript, .summary])
        #expect(vm.turns.first?.steps.first?.toolName == "create_document")
    }

    private func openCurrentStore(at url: URL) throws -> ModelContainer {
        try ModelContainer(for: KurnModelGraph.schema, migrationPlan: KurnModelGraph.migrationPlan,
                           configurations: [ModelConfiguration(schema: KurnModelGraph.schema, url: url)])
    }

    private func migrateAndWriteHarnessState(at url: URL, artifact: ChatDocumentArtifact) throws -> UUID {
        let container = try openCurrentStore(at: url)
        let context = container.mainContext
        let meeting = try #require(try context.fetch(FetchDescriptor<Meeting>()).first)
        #expect(meeting.title == "Before harness chat")
        #expect(meeting.folder?.name == "Clients")
        #expect(meeting.tags.map(\.name) == ["Q3"])
        #expect(meeting.speakers.count == 1)
        #expect(meeting.summaries.count == 1)
        #expect(meeting.semanticChunks.count == 1)
        #expect(meeting.wikiArticle != nil)
        #expect(meeting.recordings.first?.photos.count == 1)
        #expect(meeting.attachments.map(\.displayName) == ["Agenda"])
        let session = try #require(meeting.chatSessions.first)
        #expect(session.scopeData == nil)
        #expect(session.artifactsData == nil)
        #expect(session.turns.first?.text == "Legacy question")
        #expect(session.turns.first?.steps == nil)
        let document = try #require(try context.fetch(FetchDescriptor<GeneratedDocument>()).first)
        #expect(document.title == "Digest")
        #expect(document.sourceChatSessionID == nil)
        #expect(document.sourceArtifactID == nil)
        #expect(document.sourceArtifactVersion == nil)
        let scope = ChatSourceScope(kind: .meetings, selectedIDs: [meeting.id], parts: [.transcript, .summary])
        session.scopeData = JSONStorage.encodeAuthoritative(scope)
        session.artifactsData = JSONStorage.encodeAuthoritative([artifact])
        var step = AgentRunStep(kind: .tool, status: .finished)
        step.toolName = "create_document"
        var turns = session.turns
        turns[0].steps = [step]
        session.turns = turns
        document.sourceChatSessionID = session.id
        document.sourceArtifactID = artifact.id
        document.sourceArtifactVersion = artifact.version
        try context.save()
        return session.id
    }

    @Test func v5KeepsEntityNamesAndFreezesV4WithoutLeakingNewProperties() throws {
        #expect(KurnModelGraph.currentSchemaVersion == Schema.Version(1, 4, 0))
        let v4 = Schema(versionedSchema: KurnSchemaV4.self)
        #expect(Set(v4.entities.map(\.name)) == Set(KurnModelGraph.schema.entities.map(\.name)))
        let oldChat = try #require(v4.entities.first { $0.name == "ChatSession" })
        #expect(!oldChat.attributes.contains { $0.name == "scopeData" || $0.name == "artifactsData" })
        let current = try #require(KurnModelGraph.schema.entities.first { $0.name == "ChatSession" })
        #expect(current.attributes.contains { $0.name == "scopeData" })
        #expect(current.attributes.contains { $0.name == "artifactsData" })
    }

    @Test func oldTurnsWithoutStepsStillDecode() throws {
        let id = UUID()
        let data = Data("""
        [{"id":"\(id.uuidString)","role":"assistant","text":"Old reply","citations":[]}]
        """.utf8)
        let turns = try JSONDecoder().decode([PersistedChatTurn].self, from: data)
        #expect(turns.first?.id == id)
        #expect(turns.first?.text == "Old reply")
        #expect(turns.first?.steps == nil)
        #expect(turns.first?.artifacts == nil)
    }
}
