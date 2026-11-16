import Foundation
import KurnCore
import Testing
@testable import Kurn

@MainActor
struct KnowledgeReviewViewModelTests {
    private enum Failure: Error { case save }
    private func fixture(meeting: UUID = UUID(), revision: Int = 1, policy: String = "local-v1", allowsMutation: Bool = true) -> KnowledgeReviewRead {
        .init(snapshot: .init(scope: "workspace", revision: revision, policyRevisionKey: policy,
            sources: [.init(meetingID: meeting, fingerprint: "source-v1")]),
            candidates: [], merges: [], warnings: [], evidenceUnavailable: false, isTruncated: false, allowsMutation: allowsMutation)
    }

    @Test func publishesOnlyFreshMatchingScopeAndPolicy() async {
        let read = fixture()
        let model = KnowledgeReviewViewModel()
        await model.load(meetingIDs: read.meetingIDs, isEnabled: { true }, reader: { read })
        #expect(model.state == .loaded(read))
        #expect(model.presentation(meetingIDs: [UUID()]) == .unavailable)
        let changed = fixture(meeting: read.meetingIDs.first!, policy: "revoked-v2")
        var calls = 0
        await model.load(meetingIDs: read.meetingIDs, isEnabled: { true }, reader: { calls += 1; return calls == 1 ? read : changed })
        #expect(model.state == .unavailable)
        await model.load(meetingIDs: [UUID()], isEnabled: { true }, reader: { read })
        #expect(model.state == .unavailable)
    }

    @Test func failedDecisionRefetchesAndExposesRecoverableNotice() async {
        let read = fixture()
        let model = KnowledgeReviewViewModel()
        await model.load(meetingIDs: read.meetingIDs, isEnabled: { true }, reader: { read })
        var writes = 0
        await model.perform(.dismiss(UUID()), meetingIDs: read.meetingIDs, isEnabled: { true }, reader: { read }, writer: { _, proof in
            #expect(proof == read.snapshot); writes += 1; throw Failure.save
        })
        #expect(writes == 1 && model.decisionFailed && !model.isWorking)
        #expect(model.state == .loaded(read))
    }

    @Test func staleReadAndReadOnlyPolicyNeverDispatchAMutation() async {
        let read = fixture()
        let model = KnowledgeReviewViewModel()
        await model.load(meetingIDs: read.meetingIDs, isEnabled: { true }, reader: { read })
        let changed = fixture(meeting: read.meetingIDs.first!, revision: 2)
        await model.perform(.merge(UUID()), meetingIDs: read.meetingIDs, isEnabled: { true }, reader: { changed }, writer: { _, _ in Issue.record("Stale write") })
        #expect(model.state == .loaded(changed))
        let denied = fixture(meeting: read.meetingIDs.first!, allowsMutation: false)
        await model.load(meetingIDs: denied.meetingIDs, isEnabled: { true }, reader: { denied })
        await model.perform(.merge(UUID()), meetingIDs: denied.meetingIDs, isEnabled: { true }, reader: { denied }, writer: { _, _ in Issue.record("Denied write") })
    }

    @Test func lateDecisionCannotRestoreContentAfterInvalidation() async {
        let read = fixture()
        let model = KnowledgeReviewViewModel()
        await model.load(meetingIDs: read.meetingIDs, isEnabled: { true }, reader: { read })
        await model.perform(.merge(UUID()), meetingIDs: read.meetingIDs, isEnabled: { true }, reader: { read }, writer: { _, _ in model.invalidate() })
        #expect(model.state == .idle && !model.isWorking && !model.decisionFailed)
        await model.load(meetingIDs: read.meetingIDs, isEnabled: { false }, reader: { Issue.record("Disabled read"); return read })
        #expect(model.state == .idle)
    }
}
