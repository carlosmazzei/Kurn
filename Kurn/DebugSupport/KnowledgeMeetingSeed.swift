#if DEBUG
import Foundation
import KurnCore
import SwiftData

/// Synthetic UI fixture through the real canonical commit boundary. No model,
/// provider request or changes to a user's on-disk store are involved.
@MainActor
enum KnowledgeMeetingSeed {
    static func seed(container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let meeting = Meeting(title: "Example portal review", isFavorite: true)
        context.insert(meeting)
        let prefix: [TranscriptSegment] = ProcessInfo.processInfo.arguments.contains("UI-Testing-KnowledgeLongTranscript")
            ? (0..<12).map { TranscriptSegment(speakerLabel: "Speaker 2", startTime: Double($0) * 4, endTime: Double($0 + 1) * 4,
                text: "Synthetic agenda passage \($0 + 1) before the portal update.") } : []
        let start = Double(prefix.count) * 4
        let reviewFixture = ProcessInfo.processInfo.arguments.contains("UI-Testing-KnowledgeReviewFixture")
        let graphFixture = ProcessInfo.processInfo.arguments.contains("UI-Testing-KnowledgeGraphFixture")
        let recording = Recording(meeting: meeting, fileName: "synthetic-knowledge.m4a",
            duration: start + (reviewFixture ? 12 : 4) + (graphFixture ? 4 : 0), transcriptionStatus: .done)
        context.insert(recording)
        let segment = TranscriptSegment(speakerLabel: "Speaker 1", startTime: start, endTime: start + 4,
            text: "The Example portal remains open for review.")
        let extra: [TranscriptSegment] = reviewFixture ? [
            .init(speakerLabel: "Speaker 2", startTime: start + 4, endTime: start + 8, text: "The Example portal is not open for review."),
            .init(speakerLabel: "Speaker 1", startTime: start + 8, endTime: start + 12, text: "Target delivery is in November 2026.")
        ] : []
        let blocker = graphFixture ? [TranscriptSegment(speakerLabel: "Speaker 2", startTime: start + 4 + Double(extra.count) * 4,
            endTime: start + 8 + Double(extra.count) * 4, text: "The Example platform team blocks the Example portal.")] : []
        let segments = prefix + [segment] + extra + blocker
        let transcript = Transcript(recording: recording, segments: segments, language: "en")
        context.insert(transcript)
        recording.transcript = transcript
        let article = WikiArticle(meeting: meeting, bodyMarkdown: "## Example portal\n\nThe team reported that the portal remains open for review.",
            meetingTitleSnapshot: meeting.title, meetingDate: meeting.createdAt, sourceContentHash: "synthetic",
            generatorModelIdentifier: "synthetic-local")
        context.insert(article)
        meeting.wikiArticle = article
        context.insert(GeneratedDocument(title: "Example portal notes",
            bodyMarkdown: "Example portal artifact retained from the library chat.", userPrompt: "Create synthetic notes",
            sourceKind: .transcripts, sourceNames: [meeting.title], sourceMeetingIDs: [meeting.id], generatorModelIdentifier: "synthetic-local"))
        if graphFixture {
            // A named context for the graph's context lanes (K4.3).
            let occasion = KnowledgeContext(kind: .vendorDiscussion, name: "Example vendor sync")
            context.insert(occasion)
            context.insert(SourceContextLink(meetingID: meeting.id, contextID: occasion.id))
        }
        try context.save()
        let auth = KnowledgeExtractionAuthorization(featureEnabled: true,
            policies: [KnowledgeCompilationCoordinator.localPolicy(AppSettings())], sourceClassifications: [.internal])
        let sourceContext = ModelContext(container)
        let snapshot = try KnowledgeStoreRows.readSnapshot(meetingID: meeting.id, scope: "workspace", auth: auth, in: sourceContext)
        let anchor = segment.id.uuidString.lowercased()
        var wire: [String: Any] = ["version": 1,
            "entities": [["ref": "e1", "kind": "project", "name": "Example portal", "aliases": ["Orion workspace"]]],
            "assertions": [["ref": "a1", "subject": "e1", "predicate": "hasStatus", "value": ["type": "enum", "value": "open"],
                "modality": "reported", "polarity": "positive", "claimKind": "internalStatusReport", "authorityStatus": "attributed",
                "confidence": "medium", "attributedToSegmentID": anchor,
                "evidence": [["segmentIDs": [anchor], "quote": segment.text]]]], "events": [],
            "examinedSegmentIDs": segments.map { $0.id.uuidString.lowercased() }]
        if reviewFixture {
            wire["entities"] = [["ref": "e1", "kind": "project", "name": "Example portal", "aliases": ["Orion workspace"]],
                ["ref": "e2", "kind": "project", "name": "Example portal", "aliases": ["Orion delivery"]]]
            if let original = (wire["assertions"] as? [[String: Any]])?.first {
                var duplicate = original
                duplicate["ref"] = "a2"; duplicate["subject"] = "e2"
                var opposing = original
                opposing["ref"] = "a3"; opposing["polarity"] = "negative"
                opposing["attributedToSegmentID"] = extra[0].id.uuidString.lowercased()
                opposing["evidence"] = [["segmentIDs": [extra[0].id.uuidString.lowercased()], "quote": extra[0].text]]
                var dated = original
                dated["ref"] = "a4"; dated["predicate"] = "dueOn"
                dated["value"] = ["type": "date", "value": "2026-11", "precision": "month"]
                dated["attributedToSegmentID"] = extra[1].id.uuidString.lowercased()
                dated["evidence"] = [["segmentIDs": [extra[1].id.uuidString.lowercased()], "quote": extra[1].text]]
                wire["assertions"] = [original, duplicate, opposing, dated]
            }
        }
        if let blocker = blocker.first { addRelationship(to: &wire, segment: blocker) }
        let document = try JSONDecoder().decode(KnowledgeExtraction.self, from: JSONSerialization.data(withJSONObject: wire))
        guard let recordingSource = snapshot.recordings.first, let fingerprint = recordingSource.fingerprint else {
            throw KnowledgeStoreError.sourceMissing
        }
        let result = KnowledgeExtractionService.Result(transcriptFingerprint: fingerprint, strategy: .fullContext,
            passes: [document], examinedSegmentIDs: segments.map { $0.id.uuidString.lowercased() }, targetedPassCount: 0)
        let request = KnowledgeCommitRequest(snapshot: snapshot, extractorVersion: "synthetic-meeting-ui-v1", schemaVersion: 1,
            provider: .appleOnDevice, compilations: [try KnowledgeRecordingCompilation(recordingID: recording.id, result: result)])
        _ = try KnowledgeStoreRows.commit(request, auth: auth, container: container, beforeSave: {})
        try seedPagelessMeeting(auth: auth, sourceContext: sourceContext, container: container)
        if ProcessInfo.processInfo.arguments.contains("UI-Testing-KnowledgeNarrativeFixture") {
            try seedNarrative(meetingID: meeting.id, auth: auth, container: container)
        }
    }

    /// A second meeting with compiled contributions but no wiki page: its
    /// Wiki tab reaches `.loaded` with `wikiArticle == nil`, which is what
    /// the "No page yet" empty state (and its Generate button) needs.
    private static func seedPagelessMeeting(auth: KnowledgeExtractionAuthorization,
                                            sourceContext: ModelContext, container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let meeting = Meeting(title: "Example pageless review")
        context.insert(meeting)
        let recording = Recording(meeting: meeting, fileName: "synthetic-pageless.m4a",
            duration: 4, transcriptionStatus: .done)
        context.insert(recording)
        let segment = TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 4,
            text: "The Example rollout moved to December.")
        let transcript = Transcript(recording: recording, segments: [segment], language: "en")
        context.insert(transcript)
        recording.transcript = transcript
        try context.save()
        let snapshot = try KnowledgeStoreRows.readSnapshot(meetingID: meeting.id, scope: "workspace", auth: auth, in: sourceContext)
        let anchor = segment.id.uuidString.lowercased()
        let wire: [String: Any] = ["version": 1,
            "entities": [["ref": "e1", "kind": "project", "name": "Example rollout", "aliases": ["Orion rollout"]]],
            "assertions": [["ref": "a1", "subject": "e1", "predicate": "hasStatus", "value": ["type": "enum", "value": "open"],
                "modality": "reported", "polarity": "positive", "claimKind": "internalStatusReport", "authorityStatus": "attributed",
                "confidence": "medium", "attributedToSegmentID": anchor,
                "evidence": [["segmentIDs": [anchor], "quote": segment.text]]]], "events": [],
            "examinedSegmentIDs": [anchor]]
        let document = try JSONDecoder().decode(KnowledgeExtraction.self, from: JSONSerialization.data(withJSONObject: wire))
        guard let recordingSource = snapshot.recordings.first, let fingerprint = recordingSource.fingerprint else {
            throw KnowledgeStoreError.sourceMissing
        }
        let result = KnowledgeExtractionService.Result(transcriptFingerprint: fingerprint, strategy: .fullContext,
            passes: [document], examinedSegmentIDs: [anchor], targetedPassCount: 0)
        let request = KnowledgeCommitRequest(snapshot: snapshot, extractorVersion: "synthetic-meeting-ui-v1", schemaVersion: 1,
            provider: .appleOnDevice, compilations: [try KnowledgeRecordingCompilation(recordingID: recording.id, result: result)])
        _ = try KnowledgeStoreRows.commit(request, auth: auth, container: container, beforeSave: {})
    }

    private static func seedNarrative(meetingID: UUID, auth: KnowledgeExtractionAuthorization, container: ModelContainer) throws {
        let wikiAuth = KnowledgeWikiAuthorization(featureEnabled: true, meetingIDs: [meetingID],
            policies: auth.policies, sourceClassifications: auth.sourceClassifications)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let sources = try KnowledgeWikiSourceRows.sources(meetingIDs: [meetingID], scope: "workspace", auth: wikiAuth, in: context)
        let snapshot = try KnowledgeWikiSourceRows.snapshot(sources: sources, in: context)
        guard let entity = snapshot.wiki.entities.first(where: { $0.name == "Example portal" }),
              let fact = snapshot.wiki.facts.first(where: { $0.subjectID == entity.id }) else { return }
        let narrative = KnowledgeWikiNarrative(entityID: entity.id, paragraphs: [
            .init(text: "The Example portal remains open for review by the team.", assertionIDs: [fact.id])
        ])
        _ = try KnowledgeWikiProjectionRows.publish(snapshot, narratives: [narrative], auth: wikiAuth, container: container, beforeSave: {})
    }

    /// The graph fixture: a second entity related to the portal, so the
    /// explorer has an edge to draw (K4.3).
    private static func addRelationship(to wire: inout [String: Any], segment: TranscriptSegment) {
        let anchor = segment.id.uuidString.lowercased()
        let team: [String: Any] = ["ref": "e3", "kind": "team", "name": "Example platform team", "aliases": [String]()]
        wire["entities"] = (wire["entities"] as? [[String: Any]] ?? []) + [team]
        wire["assertions"] = (wire["assertions"] as? [[String: Any]] ?? []) + [[
            "ref": "a5", "subject": "e3", "predicate": "blocks", "object": "e1",
            "modality": "reported", "polarity": "positive", "claimKind": "internalStatusReport", "authorityStatus": "attributed",
            "confidence": "medium", "attributedToSegmentID": anchor,
            "evidence": [["segmentIDs": [anchor], "quote": segment.text]]]]
    }
}
#endif
