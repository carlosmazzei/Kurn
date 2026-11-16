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
        let recording = Recording(meeting: meeting, fileName: "synthetic-knowledge.m4a", duration: start + 4, transcriptionStatus: .done)
        context.insert(recording)
        let segment = TranscriptSegment(speakerLabel: "Speaker 1", startTime: start, endTime: start + 4,
            text: "The Example portal remains open for review.")
        let segments = prefix + [segment]
        let transcript = Transcript(recording: recording, segments: segments, language: "en")
        context.insert(transcript)
        recording.transcript = transcript
        let article = WikiArticle(meeting: meeting, bodyMarkdown: "## Example portal\n\nThe team reported that the portal remains open for review.",
            meetingTitleSnapshot: meeting.title, meetingDate: meeting.createdAt, sourceContentHash: "synthetic",
            generatorModelIdentifier: "synthetic-local")
        context.insert(article)
        meeting.wikiArticle = article
        try context.save()
        let auth = KnowledgeExtractionAuthorization(featureEnabled: true,
            policies: [.defaultDeny(id: KnowledgeCompilationCoordinator.localPolicyID)], sourceClassifications: [.internal])
        let sourceContext = ModelContext(container)
        let snapshot = try KnowledgeStoreRows.readSnapshot(meetingID: meeting.id, scope: "workspace", auth: auth, in: sourceContext)
        let anchor = segment.id.uuidString.lowercased()
        let wire: [String: Any] = ["version": 1,
            "entities": [["ref": "e1", "kind": "project", "name": "Example portal", "aliases": []]],
            "assertions": [["ref": "a1", "subject": "e1", "predicate": "hasStatus", "value": ["type": "enum", "value": "open"],
                "modality": "reported", "polarity": "positive", "claimKind": "internalStatusReport", "authorityStatus": "attributed",
                "confidence": "medium", "attributedToSegmentID": anchor,
                "evidence": [["segmentIDs": [anchor], "quote": segment.text]]]], "events": [],
            "examinedSegmentIDs": segments.map { $0.id.uuidString.lowercased() }]
        let document = try JSONDecoder().decode(KnowledgeExtraction.self, from: JSONSerialization.data(withJSONObject: wire))
        guard let recordingSource = snapshot.recordings.first, let fingerprint = recordingSource.fingerprint else {
            throw KnowledgeStoreError.sourceMissing
        }
        let result = KnowledgeExtractionService.Result(transcriptFingerprint: fingerprint, strategy: .fullContext,
            passes: [document], examinedSegmentIDs: segments.map { $0.id.uuidString.lowercased() }, targetedPassCount: 0)
        let request = KnowledgeCommitRequest(snapshot: snapshot, extractorVersion: "synthetic-meeting-ui-v1", schemaVersion: 1,
            provider: .appleOnDevice, compilations: [try KnowledgeRecordingCompilation(recordingID: recording.id, result: result)])
        _ = try KnowledgeStoreRows.commit(request, auth: auth, container: container, beforeSave: {})
    }
}
#endif
