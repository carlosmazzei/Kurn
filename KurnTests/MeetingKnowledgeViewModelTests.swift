import Foundation
import KurnCore
import Testing
@testable import Kurn

@MainActor
struct MeetingKnowledgeViewModelTests {
    private func read(meetingID: UUID = UUID()) throws -> MeetingKnowledgeRead {
        let entityID = UUID()
        let fact = KnowledgeWikiSnapshot.Fact(id: UUID(), subjectID: entityID, predicate: .hasStatus, value: .enumeration("open"),
            qualifiers: .init(modality: .reported, polarity: .negative, claimKind: .internalStatusReport,
                authority: .attributed, confidence: .low, review: .machineExtracted),
            source: .init(meetingID: meetingID, recordedAt: Date(), evidence: [.init(id: UUID(), recordingID: UUID(),
                segmentIDs: ["anchor"], quote: "Example is not open.", startMs: 0, endMs: 1_000, attributedSpeaker: "Speaker 1")]))
        return try MeetingKnowledgeRead(meetingID: meetingID, wiki: .init(revision: 1,
            entities: [.init(id: entityID, kind: .project, name: "Example portal")], facts: [fact]))
    }

    @Test func modeVisibilityFollowsIndependentKnowledgeFlag() {
        #expect(MeetingDetailMode.visible(knowledgeEnabled: false) == [.recordings, .transcript, .summary, .chat])
        #expect(MeetingDetailMode.visible(knowledgeEnabled: true) == [.recordings, .transcript, .summary, .knowledge, .chat])
        #expect(MeetingDetailMode.allCases.allSatisfy { !$0.title.isEmpty && !$0.systemImage.isEmpty })
    }

    @Test func contributionsKeepUniqueFactCountsAndOriginalQualifiers() throws {
        let data = try read()
        #expect(data.contributions.count == 1)
        #expect(data.assertionCount == 1)
        #expect(data.evidenceCount == 1)
        #expect(data.contributions[0].facts[0].qualifiers.polarity == .negative)
        #expect(data.contributions[0].facts[0].source.evidence[0].attributedSpeaker == "Speaker 1")
        #expect(!data.summary.isEmpty)
        let wiki = KnowledgeWikiSnapshot(revision: 1, entities: [], facts: data.contributions[0].facts)
        #expect(throws: KnowledgeWikiStoreError.scopeDenied) { try MeetingKnowledgeRead(meetingID: UUID(), wiki: wiki) }
    }

    @Test func disabledAndFailedReadsNeverKeepOldNamesOrCounts() async throws {
        let model = MeetingKnowledgeViewModel()
        let data = try read()
        await model.load(meetingID: data.meetingID, isEnabled: { true }, reader: { data })
        #expect(model.state == .loaded(data))
        await model.load(meetingID: data.meetingID, isEnabled: { false }, reader: { Issue.record("Disabled reader executed"); return data })
        #expect(model.state == .idle)
        await model.load(meetingID: data.meetingID, isEnabled: { true }, reader: { throw KnowledgeWikiStoreError.scopeDenied })
        #expect(model.state == .unavailable)
        #expect(!model.header(for: data.meetingID).isEmpty)
        model.invalidate()
        #expect(model.state == .idle)
    }

    @Test func relationalContributionsDoNotDoubleCountClaimsOrPassages() throws {
        let base = try read()
        let original = base.contributions[0].facts[0]
        let other = UUID()
        let fact = KnowledgeWikiSnapshot.Fact(id: original.id, subjectID: original.subjectID, predicate: .dependsOn, objectID: other,
            qualifiers: original.qualifiers, source: original.source)
        let result = try MeetingKnowledgeRead(meetingID: base.meetingID, wiki: .init(revision: 2,
            entities: [.init(id: fact.subjectID, kind: .project, name: "Example portal"), .init(id: other, kind: .project, name: "Example service")],
            facts: [fact]))
        #expect(result.contributions.count == 2)
        #expect(result.contributions.allSatisfy { $0.facts.count == 1 })
        #expect(result.assertionCount == 1)
        #expect(result.evidenceCount == 1)
    }

    @Test func invalidatedOrSupersededReadsCannotResurfaceContributions() async throws {
        let model = MeetingKnowledgeViewModel()
        let first = try read()
        let second = try read()
        await model.load(meetingID: first.meetingID, isEnabled: { true }, reader: {
            model.invalidate()
            return first
        })
        #expect(model.state == .idle)
        await model.load(meetingID: first.meetingID, isEnabled: { true }, reader: {
            await model.load(meetingID: second.meetingID, isEnabled: { true }, reader: { second })
            return first
        })
        #expect(model.state == .loaded(second))
        #expect(model.presentation(for: first.meetingID) == .idle)
    }

    @Test func revocationAndForeignMeetingResultsAreRefusedAfterAwait() async throws {
        let model = MeetingKnowledgeViewModel()
        let data = try read()
        var enabled = true
        await model.load(meetingID: data.meetingID, isEnabled: { enabled }, reader: { enabled = false; return data })
        #expect(model.state == .idle)
        await model.load(meetingID: UUID(), isEnabled: { true }, reader: { data })
        #expect(model.state == .unavailable)
    }

    @Test func cancelledLoadsClearTheirPresentation() async throws {
        let model = MeetingKnowledgeViewModel()
        let data = try read()
        await model.load(meetingID: data.meetingID, isEnabled: { true }, reader: { throw CancellationError() })
        #expect(model.state == .idle)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load(meetingID: data.meetingID, isEnabled: { true }, reader: { data })
        }
        await task.value
        #expect(model.state == .idle)
    }
}
