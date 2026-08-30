//
//  LegacyStoreAdoptionTests.swift
//  KurnTests
//
//  H2 (`docs/resilience-megaplan.md`, PR 2 — versioned-schema baseline) calls
//  for committed fixtures proving the oldest supported released store layout
//  survives adoption into the new versioned schema/migration plan without
//  data loss. Every Kurn store shipped before `KurnSchema.swift` existed was
//  opened with a bare, unversioned `Schema([...])` — there is no earlier
//  released layout to fabricate, because this is the very first time the app
//  has declared a schema version at all. So "the oldest supported released
//  layout" and "today's schema" are the same set of eleven entities; what
//  needs proving is only that opening an unversioned store through
//  `KurnModelGraph`'s versioned schema + `KurnSchemaMigrationPlan` does not
//  reset, corrupt, or drop it.
//
//  A real device-produced binary `.store` file would be a stronger fixture,
//  but hand-crafting SwiftData's on-disk (Core Data-backed) format without
//  Xcode is not something that can be done reliably or verified in this
//  environment — a malformed hand-built fixture would fail in ways that are
//  indistinguishable from a real regression. Instead this test builds the
//  legacy store at run time, the same way `KurnApp` built every store before
//  this PR, then reopens the identical file through the new versioned path —
//  which is deterministic, exercises the real SwiftData migration machinery
//  on CI's macOS runner, and needs no binary checked into the repository.
//  If a genuine pre-this-PR device backup ever surfaces, it can be dropped in
//  as an additional fixture without changing this test's shape.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct LegacyStoreAdoptionTests {

    /// Builds a store at `url` using a bare, unversioned schema — exactly how
    /// `KurnApp` constructed its `ModelContainer` before `KurnSchema.swift`
    /// existed — populates one of every model type with representative
    /// relationships and JSON-backed content, then closes it.
    private func writeLegacyStore(at url: URL) throws {
        let legacySchema = Schema(KurnModelGraph.currentModels)
        let configuration = ModelConfiguration(schema: legacySchema, url: url)
        let container = try ModelContainer(for: legacySchema, configurations: [configuration])
        let context = container.mainContext

        let (meeting, tag) = insertMeetingCore(into: context)
        let doneRecording = insertDoneRecording(for: meeting, into: context)
        insertRecoveringRecording(for: meeting, into: context)
        insertDerivedArtifacts(for: meeting, tag: tag, doneRecording: doneRecording, into: context)

        try context.save()
    }

    /// Folder, tag, meeting and speaker — the core rows every other fixture
    /// below hangs off.
    private func insertMeetingCore(into context: ModelContext) -> (meeting: Meeting, tag: Kurn.Tag) {
        let folder = Folder(name: "Legacy Folder", iconName: "folder.fill", colorHex: "#5E5CE6")
        context.insert(folder)

        let tag = Tag(name: "Legacy Tag", colorHex: "#FF9500")
        context.insert(tag)

        let meeting = Meeting(
            title: "Legacy Meeting",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            notes: "Notes written before versioning existed.",
            language: .english,
            isFavorite: true,
            folder: folder
        )
        meeting.tags = [tag]
        context.insert(meeting)

        let speaker = Speaker(
            meeting: meeting,
            label: "Speaker 1",
            name: "Ana",
            color: "#34C759",
            voiceprintData: VectorData.encode([0.1, 0.2, 0.3, 0.4])
        )
        context.insert(speaker)

        return (meeting, tag)
    }

    /// A recording that finished cleanly, carrying highlights and a completed
    /// transcript — the common case.
    private func insertDoneRecording(for meeting: Meeting, into context: ModelContext) -> Recording {
        let doneRecording = Recording(
            meeting: meeting,
            fileName: "legacy-done.m4a",
            duration: 623.5,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_100),
            transcriptionStatus: .done,
            transcriptionMode: .onDevice,
            captureState: .ready,
            fileSize: 4_200_000,
            highlights: [Highlight(timestamp: 12.5)]
        )
        doneRecording.speakerVoiceprints = ["Speaker 1": [0.1, 0.2, 0.3, 0.4]]
        context.insert(doneRecording)

        let transcript = Transcript(
            recording: doneRecording,
            segments: [
                TranscriptSegment(
                    speakerLabel: "Speaker 1",
                    startTime: 0,
                    endTime: 5.2,
                    text: "Let's start the legacy meeting.",
                    confidence: 0.92
                )
            ],
            language: "en",
            createdAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        context.insert(transcript)

        return doneRecording
    }

    /// A second recording still carrying an in-flight checkpoint and an
    /// explicit capture-recovery state — the H1/H4 durability state this
    /// adoption path must not silently drop.
    private func insertRecoveringRecording(for meeting: Meeting, into context: ModelContext) {
        let recoveringRecording = Recording(
            meeting: meeting,
            fileName: "legacy-recovering.m4a",
            duration: 240,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_300),
            transcriptionStatus: .inProgress,
            transcriptionMode: .onDevice,
            captureState: .recoveryNeeded,
            captureRecoveryReason: .writeFailed,
            fileSize: 1_800_000
        )
        recoveringRecording.transcriptionCheckpoint = TranscriptionCheckpoint(
            engineRaw: TranscriptionEngine.appleSpeech.rawValue,
            languageRaw: MeetingLanguage.english.rawValue,
            compacted: false,
            totalChunks: 4,
            completedChunks: 2,
            detectedLanguage: "en",
            providerID: nil,
            spans: [
                TranscriptionCheckpoint.Span(text: "First chunk.", start: 0, end: 30, confidence: 0.8)
            ]
        )
        context.insert(recoveringRecording)
    }

    /// Summary, smart folder, semantic chunk, wiki article and generated
    /// document — the LLM-derived and index artifacts layered on the meeting.
    private func insertDerivedArtifacts(
        for meeting: Meeting,
        tag: Kurn.Tag,
        doneRecording: Recording,
        into context: ModelContext
    ) {
        let summary = Summary(
            meeting: meeting,
            sections: [SummarySection(title: "Overview", body: "A legacy summary.", items: ["Item one"])],
            templateName: "General",
            provider: .openAI,
            model: "gpt-5.4",
            createdAt: Date(timeIntervalSince1970: 1_700_000_400)
        )
        context.insert(summary)

        let smartFolder = SmartFolder(
            name: "Legacy Smart Folder",
            filter: MeetingFilter(tagIDs: [tag.id]),
            createdAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        context.insert(smartFolder)

        let semanticChunk = SemanticChunk(
            meeting: meeting,
            recordingID: doneRecording.id,
            text: "Let's start the legacy meeting.",
            startTime: 0,
            endTime: 5.2,
            speakerLabel: "Speaker 1",
            vector: [0.5, 0.25, 0.125],
            modelIdentifier: "legacy-embedder-v1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_600)
        )
        context.insert(semanticChunk)

        let wikiArticle = WikiArticle(
            meeting: meeting,
            bodyMarkdown: "# Legacy Meeting\n- Decision point at 00:12",
            meetingTitleSnapshot: meeting.title,
            meetingDate: meeting.createdAt,
            sourceContentHash: "legacy-hash-abc123",
            generatorModelIdentifier: "openAI:gpt-5.4:wiki-v1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_700),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_700)
        )
        context.insert(wikiArticle)

        let generatedDocument = GeneratedDocument(
            title: "Legacy Digest",
            bodyMarkdown: "# Legacy Digest\nSynthesized before versioning existed.",
            userPrompt: "Summarize everything about the legacy meeting.",
            sourceKind: .transcripts,
            sourceNames: [meeting.title],
            sourceMeetingIDs: [meeting.id],
            generatorModelIdentifier: "openAI:gpt-5.4",
            createdAt: Date(timeIntervalSince1970: 1_700_000_800)
        )
        context.insert(generatedDocument)
    }

    @Test func unversionedStoreOpensThroughTheVersionedSchemaWithoutDataLoss() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyStoreAdoptionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("legacy.store")

        try writeLegacyStore(at: storeURL)

        // Reopen the identical file through the versioned schema + migration
        // plan every new store now uses — the actual adoption path.
        let versionedConfiguration = ModelConfiguration(schema: KurnModelGraph.schema, url: storeURL)
        let container = try ModelContainer(
            for: KurnModelGraph.schema,
            migrationPlan: KurnModelGraph.migrationPlan,
            configurations: [versionedConfiguration]
        )
        let context = container.mainContext

        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        #expect(meetings.count == 1)
        let meeting = try #require(meetings.first)
        #expect(meeting.title == "Legacy Meeting")
        #expect(meeting.isFavorite == true)
        #expect(meeting.folder?.name == "Legacy Folder")
        #expect(meeting.tags.map(\.name) == ["Legacy Tag"])
        #expect(meeting.language == .english)

        #expect(meeting.speakers.count == 1)
        let speaker = try #require(meeting.speakers.first)
        #expect(speaker.name == "Ana")
        #expect(speaker.voiceprint == [0.1, 0.2, 0.3, 0.4])

        #expect(meeting.recordings.count == 2)
        let doneRecording = try #require(meeting.recordings.first { $0.fileName == "legacy-done.m4a" })
        #expect(doneRecording.transcriptionStatus == .done)
        #expect(doneRecording.captureState == .ready)
        #expect(doneRecording.highlights.map(\.timestamp) == [12.5])
        #expect(doneRecording.speakerVoiceprints["Speaker 1"] == [0.1, 0.2, 0.3, 0.4])
        let transcript = try #require(doneRecording.transcript)
        #expect(transcript.segments.map(\.text) == ["Let's start the legacy meeting."])

        let recoveringRecording = try #require(
            meeting.recordings.first { $0.fileName == "legacy-recovering.m4a" }
        )
        #expect(recoveringRecording.captureState == .recoveryNeeded)
        #expect(recoveringRecording.captureRecoveryReason == .writeFailed)
        let checkpoint = try #require(recoveringRecording.transcriptionCheckpoint)
        #expect(checkpoint.totalChunks == 4)
        #expect(checkpoint.completedChunks == 2)
        #expect(checkpoint.spans.map(\.text) == ["First chunk."])

        #expect(meeting.summaries.count == 1)
        let summary = try #require(meeting.summaries.first)
        #expect(summary.sections.map(\.title) == ["Overview"])
        #expect(summary.provider == .openAI)

        let smartFolders = try context.fetch(FetchDescriptor<SmartFolder>())
        #expect(smartFolders.map(\.name) == ["Legacy Smart Folder"])
        #expect(smartFolders.first?.filter.tagIDs == [tagID(from: meeting)])

        let semanticChunks = try context.fetch(FetchDescriptor<SemanticChunk>())
        #expect(semanticChunks.count == 1)
        #expect(semanticChunks.first?.vector == [0.5, 0.25, 0.125])

        #expect(meeting.wikiArticle?.sourceContentHash == "legacy-hash-abc123")

        let generatedDocuments = try context.fetch(FetchDescriptor<GeneratedDocument>())
        #expect(generatedDocuments.count == 1)
        #expect(generatedDocuments.first?.sourceMeetingIDs == [meeting.id])
    }

    private func tagID(from meeting: Meeting) -> UUID {
        meeting.tags.first?.id ?? UUID()
    }
}
