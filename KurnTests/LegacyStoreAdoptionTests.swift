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
//  layout" is exactly `KurnSchemaV1`'s eleven entities; what needs proving is
//  only that opening an unversioned store through `KurnModelGraph`'s
//  versioned schema + `KurnSchemaMigrationPlan` does not reset, corrupt, or
//  drop it. `KurnSchemaV2` later added a twelfth, additive entity
//  (`ChatSession`) and `Meeting.chatSessions` — this fixture deliberately
//  still writes the V1 shape, so the reopen below also exercises that
//  migration stage, not a same-shape no-op.
//
//  "The V1 shape" has to mean the *frozen* `KurnSchemaV1.*` classes in
//  `KurnSchemaV1Models.swift`, never the live ones: the live `Meeting` already
//  carries `chatSessions`, so a store written with it is a V2 store wearing a
//  V1 label, and reopening it proves nothing about migrating from 1.0.0. That
//  is exactly the bug this fixture once had. The frozen classes only have
//  stored properties and a raw-value initializer, so the rows below are
//  written the way they sit on disk (`languageRaw`, `highlightsData`, …) using
//  the same encoders the live classes use, and read back through the live
//  classes' typed accessors.
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
        // The eleven-entity `KurnSchemaV1` shape specifically, built from the
        // frozen `KurnSchemaV1.*` classes, not `KurnModelGraph.currentModels`
        // — that now includes `ChatSession` and `Meeting.chatSessions` (added
        // in `KurnSchemaV2`), which a store built before this file existed
        // never had. Using the live graph here would silently stop testing
        // the V1→V2 migration this fixture exists to exercise.
        let legacySchema = Schema(KurnSchemaV1.models)
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
    private func insertMeetingCore(
        into context: ModelContext
    ) -> (meeting: KurnSchemaV1.Meeting, tag: KurnSchemaV1.Tag) {
        let folder = KurnSchemaV1.Folder(name: "Legacy Folder", iconName: "folder.fill", colorHex: "#5E5CE6")
        context.insert(folder)

        let tag = KurnSchemaV1.Tag(name: "Legacy Tag", colorHex: "#FF9500")
        context.insert(tag)

        let meeting = KurnSchemaV1.Meeting(
            title: "Legacy Meeting",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            notes: "Notes written before versioning existed.",
            languageRaw: MeetingLanguage.english.rawValue,
            isFavorite: true,
            folder: folder
        )
        meeting.tags = [tag]
        context.insert(meeting)

        let speaker = KurnSchemaV1.Speaker(
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
    private func insertDoneRecording(
        for meeting: KurnSchemaV1.Meeting,
        into context: ModelContext
    ) -> KurnSchemaV1.Recording {
        let doneRecording = KurnSchemaV1.Recording(
            meeting: meeting,
            fileName: "legacy-done.m4a",
            duration: 623.5,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_100),
            transcriptionStatusRaw: TranscriptionStatus.done.rawValue,
            transcriptionModeRaw: TranscriptionMode.onDevice.rawValue,
            captureStateRaw: RecordingCaptureState.ready.rawValue,
            fileSize: 4_200_000,
            highlightsData: JSONStorage.encode([Highlight(timestamp: 12.5)])
        )
        let speakerVoiceprints: [String: [Float]] = ["Speaker 1": [0.1, 0.2, 0.3, 0.4]]
        doneRecording.speakerVoiceprintsData = JSONStorage.encode(speakerVoiceprints)
        context.insert(doneRecording)

        let segments = [
            TranscriptSegment(
                speakerLabel: "Speaker 1",
                startTime: 0,
                endTime: 5.2,
                text: "Let's start the legacy meeting.",
                confidence: 0.92
            )
        ]
        let transcript = KurnSchemaV1.Transcript(
            recording: doneRecording,
            segmentsData: JSONStorage.encodeAuthoritative(segments) ?? Data(),
            language: "en",
            createdAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        context.insert(transcript)

        return doneRecording
    }

    /// A second recording still carrying an in-flight checkpoint and an
    /// explicit capture-recovery state — the H1/H4 durability state this
    /// adoption path must not silently drop.
    private func insertRecoveringRecording(for meeting: KurnSchemaV1.Meeting, into context: ModelContext) {
        let recoveringRecording = KurnSchemaV1.Recording(
            meeting: meeting,
            fileName: "legacy-recovering.m4a",
            duration: 240,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_300),
            transcriptionStatusRaw: TranscriptionStatus.inProgress.rawValue,
            transcriptionModeRaw: TranscriptionMode.onDevice.rawValue,
            captureStateRaw: RecordingCaptureState.recoveryNeeded.rawValue,
            captureRecoveryReasonRaw: CaptureRecoveryReason.writeFailed.rawValue,
            fileSize: 1_800_000
        )
        let checkpoint = TranscriptionCheckpoint.fixture(
            engine: .appleSpeech,
            language: .english,
            compacted: false,
            totalChunks: 4,
            completedChunks: 2,
            detectedLanguage: "en",
            spans: [
                TranscriptionCheckpoint.Span(text: "First chunk.", start: 0, end: 30, confidence: 0.8)
            ]
        )
        recoveringRecording.transcriptionCheckpointData = JSONStorage.encodeAuthoritative(checkpoint)
        context.insert(recoveringRecording)
    }

    /// Summary, smart folder, semantic chunk, wiki article and generated
    /// document — the LLM-derived and index artifacts layered on the meeting.
    private func insertDerivedArtifacts(
        for meeting: KurnSchemaV1.Meeting,
        tag: KurnSchemaV1.Tag,
        doneRecording: KurnSchemaV1.Recording,
        into context: ModelContext
    ) {
        let sections = [SummarySection(title: "Overview", body: "A legacy summary.", items: ["Item one"])]
        let summary = KurnSchemaV1.Summary(
            meeting: meeting,
            sectionsData: JSONStorage.encodeAuthoritative(sections) ?? Data(),
            templateName: "General",
            providerRaw: AIProvider.openAI.rawValue,
            modelRaw: "gpt-5.4",
            createdAt: Date(timeIntervalSince1970: 1_700_000_400)
        )
        context.insert(summary)

        let smartFolder = KurnSchemaV1.SmartFolder(
            name: "Legacy Smart Folder",
            iconName: "folder.badge.gearshape",
            colorHex: "#FF2D55",
            predicateData: JSONStorage.encode(MeetingFilter(tagIDs: [tag.id])),
            createdAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        context.insert(smartFolder)

        let vector: [Float] = [0.5, 0.25, 0.125]
        let semanticChunk = KurnSchemaV1.SemanticChunk(
            meeting: meeting,
            recordingID: doneRecording.id,
            text: "Let's start the legacy meeting.",
            startTime: 0,
            endTime: 5.2,
            speakerLabel: "Speaker 1",
            vectorData: VectorData.encode(vector),
            dimension: vector.count,
            modelIdentifier: "legacy-embedder-v1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_600)
        )
        context.insert(semanticChunk)

        let wikiArticle = KurnSchemaV1.WikiArticle(
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

        let generatedDocument = KurnSchemaV1.GeneratedDocument(
            title: "Legacy Digest",
            bodyMarkdown: "# Legacy Digest\nSynthesized before versioning existed.",
            userPrompt: "Summarize everything about the legacy meeting.",
            sourceKindRaw: DocumentSourceKind.transcripts.rawValue,
            sourceNamesData: JSONStorage.encode([meeting.title]),
            sourceMeetingIDsData: JSONStorage.encode([meeting.id]),
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

        // The V2 additions are present and usable on the migrated store: the
        // new to-many is empty rather than faulting, and the new entity can
        // be fetched and written against the same file.
        #expect(meeting.chatSessions.isEmpty)
        #expect(try context.fetch(FetchDescriptor<ChatSession>()).isEmpty)
        let chatSession = ChatSession(meeting: meeting, title: "After migration")
        context.insert(chatSession)
        try context.save()
        #expect(meeting.chatSessions.map(\.title) == ["After migration"])
    }

    private func tagID(from meeting: Meeting) -> UUID {
        meeting.tags.first?.id ?? UUID()
    }

    // MARK: - Volume: a whole library, not one fixture meeting

    /// A single reported crash losing "every meeting I had" is exactly what a
    /// one-meeting fixture cannot catch: with only one row of each entity,
    /// there is nothing to silently drop, reorder, or partially write without
    /// the count assertions already failing loudly. This test builds a
    /// library-sized store (`meetingCount` meetings, each with two recordings,
    /// a transcript, a summary, and a semantic chunk — the same shape a real,
    /// well-used library has) from the frozen `KurnSchemaV1` classes, migrates
    /// it through the *real* two-stage plan (V1 → V2 → V3, not a shortcut
    /// straight to V3), and asserts every row and every relationship survived
    /// with the content intact — not just the counts, since a count match can
    /// hide swapped or truncated content.
    @Test func manyMeetingsSurviveTheFullMigrationChainWithoutDataLoss() throws {
        let meetingCount = 60
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyStoreAdoptionTests-volume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("legacy-library.store")

        try writeLegacyLibrary(meetingCount: meetingCount, at: storeURL)

        // The real adoption path: the full versioned schema + migration plan,
        // exactly what `ModelContainerBootstrap.makeStore()` uses in
        // production — never a container opened straight against V3.
        let versionedConfiguration = ModelConfiguration(schema: KurnModelGraph.schema, url: storeURL)
        let container = try ModelContainer(
            for: KurnModelGraph.schema,
            migrationPlan: KurnModelGraph.migrationPlan,
            configurations: [versionedConfiguration]
        )
        let context = container.mainContext

        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        #expect(meetings.count == meetingCount)

        // Every meeting kept its own title (no swap/collision across rows),
        // both of its recordings, and each recording kept its own transcript
        // segment count — the totals a silent partial migration would corrupt
        // first, since row *counts* alone can match while content doesn't.
        let sortedMeetings = meetings.sorted {
            ($0.title.split(separator: " ").last.flatMap { Int($0) } ?? -1)
                < ($1.title.split(separator: " ").last.flatMap { Int($0) } ?? -1)
        }
        for (index, meeting) in sortedMeetings.enumerated() {
            #expect(meeting.title == "Library Meeting \(index)")
            #expect(meeting.recordings.count == 2)
            #expect(meeting.summaries.count == 1)
            #expect(meeting.summaries.first?.sections.first?.title == "Overview \(index)")
            let totalSegments = meeting.recordings.reduce(0) { $0 + ($1.transcript?.segments.count ?? 0) }
            #expect(totalSegments == 2 * segmentsPerRecording)
            // Every migrated meeting must expose the V3 relationship, ready to
            // use, not merely present — an empty collection that faults on
            // access would look identical to data loss from the UI.
            #expect(meeting.recordings.allSatisfy { $0.photos.isEmpty })
        }

        let totalRecordings = try context.fetchCount(FetchDescriptor<Recording>())
        #expect(totalRecordings == meetingCount * 2)
        let totalSemanticChunks = try context.fetchCount(FetchDescriptor<SemanticChunk>())
        #expect(totalSemanticChunks == meetingCount)

        // The migrated store must be fully writable, not just readable: add a
        // V3-only row (a photo, the entity this migration introduced) against
        // an existing, migrated recording and persist it.
        let targetRecording = try #require(sortedMeetings.first?.recordings.first)
        let photo = MeetingPhoto(recording: targetRecording, fileName: "post-migration.jpg", capturedAt: 3.5)
        context.insert(photo)
        try context.save()
        #expect(targetRecording.photos.map(\.fileName) == ["post-migration.jpg"])
    }

    private var segmentsPerRecording: Int { 3 }

    /// Builds `meetingCount` independent meetings, each with two recordings
    /// (one done, one still transcribing), a transcript per recording, one
    /// summary, and one semantic chunk — using the frozen `KurnSchemaV1`
    /// classes so this exercises the same V1 → V2 → V3 chain the single-
    /// meeting fixture above does, just at library scale.
    private func writeLegacyLibrary(meetingCount: Int, at url: URL) throws {
        let legacySchema = Schema(KurnSchemaV1.models)
        let configuration = ModelConfiguration(schema: legacySchema, url: url)
        let container = try ModelContainer(for: legacySchema, configurations: [configuration])
        let context = container.mainContext

        let sharedFolder = KurnSchemaV1.Folder(name: "Library Folder", iconName: "folder.fill", colorHex: "#5E5CE6")
        context.insert(sharedFolder)

        for index in 0..<meetingCount {
            let meeting = KurnSchemaV1.Meeting(
                title: "Library Meeting \(index)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3_600),
                notes: "Notes for meeting \(index).",
                languageRaw: MeetingLanguage.english.rawValue,
                isFavorite: index.isMultiple(of: 5),
                folder: sharedFolder
            )
            context.insert(meeting)

            for recordingIndex in 0..<2 {
                let isDone = recordingIndex == 0
                let recording = KurnSchemaV1.Recording(
                    meeting: meeting,
                    fileName: "library-\(index)-\(recordingIndex).m4a",
                    duration: 300 + Double(index),
                    recordedAt: Date(timeIntervalSince1970: 1_700_000_100 + Double(index) * 3_600),
                    transcriptionStatusRaw: (isDone ? TranscriptionStatus.done : .inProgress).rawValue,
                    transcriptionModeRaw: TranscriptionMode.onDevice.rawValue,
                    captureStateRaw: RecordingCaptureState.ready.rawValue,
                    fileSize: 1_000_000 + Int64(index)
                )
                context.insert(recording)

                let segments = (0..<segmentsPerRecording).map { segmentIndex in
                    TranscriptSegment(
                        speakerLabel: "Speaker 1",
                        startTime: Double(segmentIndex) * 5,
                        endTime: Double(segmentIndex) * 5 + 4,
                        text: "Meeting \(index) recording \(recordingIndex) segment \(segmentIndex).",
                        confidence: 0.9
                    )
                }
                let transcript = KurnSchemaV1.Transcript(
                    recording: recording,
                    segmentsData: JSONStorage.encodeAuthoritative(segments) ?? Data(),
                    language: "en"
                )
                context.insert(transcript)
            }

            let sections = [SummarySection(title: "Overview \(index)", body: "Summary body \(index).", items: [])]
            let summary = KurnSchemaV1.Summary(
                meeting: meeting,
                sectionsData: JSONStorage.encodeAuthoritative(sections) ?? Data(),
                providerRaw: AIProvider.openAI.rawValue,
                modelRaw: "gpt-5.4"
            )
            context.insert(summary)

            let vector: [Float] = [Float(index), 0.5, 0.25]
            let semanticChunk = KurnSchemaV1.SemanticChunk(
                meeting: meeting,
                recordingID: UUID(),
                text: "Passage for meeting \(index).",
                startTime: 0,
                endTime: 4,
                speakerLabel: "Speaker 1",
                vectorData: VectorData.encode(vector),
                dimension: vector.count,
                modelIdentifier: "legacy-embedder-v1"
            )
            context.insert(semanticChunk)
        }

        try context.save()
    }
}
