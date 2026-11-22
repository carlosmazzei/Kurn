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
        #expect(MeetingDetailMode.visible(knowledgeEnabled: false) == [.summary, .transcript, .recordings])
        #expect(MeetingDetailMode.visible(knowledgeEnabled: true) == [.summary, .transcript, .recordings, .knowledge])
        #expect(MeetingDetailMode.allCases.allSatisfy { !$0.title.isEmpty && !$0.systemImage.isEmpty })
    }

    @Test func contributionsKeepUniqueFactCountsAndOriginalQualifiers() throws {
        let data = try read()
        #expect(data.contributions.count == 1)
        #expect(data.assertionCount == 1)
        #expect(data.passageCount == 1)
        #expect(data.contributions[0].entries[0].fact.qualifiers.polarity == .negative)
        #expect(data.contributions[0].entries[0].fact.source.evidence[0].attributedSpeaker == "Speaker 1")
        #expect(!data.summary.isEmpty)
        let wiki = KnowledgeWikiSnapshot(revision: 1, entities: [], facts: data.contributions[0].entries.map(\.fact))
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
        let original = base.contributions[0].entries[0].fact
        let other = UUID()
        let fact = KnowledgeWikiSnapshot.Fact(id: original.id, subjectID: original.subjectID, predicate: .dependsOn, objectID: other,
            qualifiers: original.qualifiers, source: original.source)
        let result = try MeetingKnowledgeRead(meetingID: base.meetingID, wiki: .init(revision: 2,
            entities: [.init(id: fact.subjectID, kind: .project, name: "Example portal"), .init(id: other, kind: .project, name: "Example service")],
            facts: [fact]))
        #expect(result.contributions.count == 2)
        #expect(result.contributions.allSatisfy { $0.entries.count == 1 })
        #expect(result.assertionCount == 1)
        #expect(result.passageCount == 1)
        let first = MeetingKnowledgeClaimPresentation.text(result.contributions[0].entries[0])
        let second = MeetingKnowledgeClaimPresentation.text(result.contributions[1].entries[0])
        #expect(first == second)
        let subject = try #require(first.range(of: "Example portal"))
        let object = try #require(first.range(of: "Example service"))
        #expect(subject.lowerBound < object.lowerBound)
    }

    @Test func passageCountsUseCitationIdentityAndRemainRecordingScoped() throws {
        let base = try read()
        let original = base.contributions[0].entries[0].fact
        let quote = original.source.evidence[0]
        for sameRecording in [true, false] {
            let duplicate = KnowledgeWikiSnapshot.Evidence(id: UUID(), recordingID: sameRecording ? quote.recordingID : UUID(),
                segmentIDs: quote.segmentIDs, quote: quote.quote, startMs: quote.startMs, endMs: quote.endMs,
                attributedSpeaker: quote.attributedSpeaker)
            let fact = KnowledgeWikiSnapshot.Fact(id: UUID(), subjectID: original.subjectID, predicate: original.predicate, value: original.value,
                qualifiers: original.qualifiers, source: .init(meetingID: base.meetingID, recordedAt: original.source.recordedAt, evidence: [duplicate]))
            let result = try MeetingKnowledgeRead(meetingID: base.meetingID, wiki: .init(revision: 2,
                entities: [.init(id: original.subjectID, kind: .project, name: "Example portal")], facts: [original, fact]))
            #expect(result.assertionCount == 2)
            #expect(result.passageCount == (sameRecording ? 1 : 2))
        }
        #expect(MeetingKnowledgeClaimPresentation.valueText(.string("Literal [text]")) == "Literal [text]")
        let month = try #require(KnowledgeTemporalValue(text: "2026-11", precision: .month))
        #expect(MeetingKnowledgeClaimPresentation.valueText(.date(month)) == "2026-11")
        #expect(!MeetingKnowledgeClaimPresentation.valueText(.number(3, unit: "ms")).isEmpty)
        #expect(!MeetingKnowledgeClaimPresentation.valueText(.boolean(false)).isEmpty)
        #expect(!MeetingKnowledgeClaimPresentation.valueText(.enumeration("open")).isEmpty)
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

    @Test func metricPresentationRetainsSmallAndLargeCanonicalValues() {
        let english = Locale(identifier: "en_US_POSIX")
        let portuguese = Locale(identifier: "pt_BR")
        #expect(MeetingKnowledgeClaimPresentation.numberText(0.0001, locale: english) == "0.0001")
        #expect(MeetingKnowledgeClaimPresentation.numberText(0.0001, locale: portuguese) == "0,0001")
        #expect(MeetingKnowledgeClaimPresentation.numberText(3, locale: english) == "3")
        for value in [0.0001, -0.000001, 1e-200, Double.leastNonzeroMagnitude, Double.greatestFiniteMagnitude, 1234567890.1234567] {
            let text = MeetingKnowledgeClaimPresentation.numberText(value, locale: english)
            #expect(Double(text) == value)
            let displayed = MeetingKnowledgeClaimPresentation.valueText(.number(value, unit: "s"))
            let parsed = displayed.replacingOccurrences(of: " s", with: "").replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
            #expect(Double(parsed) == value)
        }
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
