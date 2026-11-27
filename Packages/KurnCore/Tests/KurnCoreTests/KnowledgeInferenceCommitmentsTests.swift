import Foundation
import Testing
@testable import KurnCore

/// K7.4: owner → action → due joins two stated claims and lists both as premises.
struct KnowledgeInferenceCommitmentsTests {
    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    private static func fact(_ number: Int, _ subject: Int, _ predicate: KnowledgePredicate, object: Int? = nil,
                             due: String? = nil, polarity: KnowledgePolarity = .positive,
                             modality: KnowledgeModality = .agreed) -> KnowledgeWikiSnapshot.Fact {
        let qualifiers = KnowledgeWikiSnapshot.Qualifiers(
            modality: modality, polarity: polarity, claimKind: .commitment, authority: .attributed,
            confidence: .high, review: .machineExtracted)
        let value = due.flatMap { KnowledgeTemporalValue(text: $0, precision: .day) }.map(KnowledgeTypedValue.date)
        return KnowledgeWikiSnapshot.Fact(
            id: id(number), subjectID: id(subject), predicate: predicate, objectID: object.map(id), value: value,
            qualifiers: qualifiers, source: .init(meetingID: id(900), recordedAt: Date(timeIntervalSince1970: 0), evidence: []))
    }

    @Test func anAssignedActionWithADueDateNamesItsOwnerAndTheDate() {
        let result = KnowledgeInference.deriveCommitments(from: [
            Self.fact(101, 1, .assignedTo, object: 2), Self.fact(102, 1, .dueOn, due: "2026-12-01")
        ])
        #expect(result.commitments.count == 1)
        let commitment = result.commitments.first
        #expect(commitment?.ownerID == Self.id(2) && commitment?.actionID == Self.id(1))
        #expect(commitment?.due.text == "2026-12-01")
        #expect(commitment?.premiseFactIDs == [Self.id(101), Self.id(102)])
        #expect(commitment?.modality == .inferred)
    }

    @Test func ownsReadsTheOtherWayRound() {
        let result = KnowledgeInference.deriveCommitments(from: [
            Self.fact(101, 2, .owns, object: 1), Self.fact(102, 1, .dueOn, due: "2026-12-01")
        ])
        #expect(result.commitments.first?.ownerID == Self.id(2))
        #expect(result.commitments.first?.actionID == Self.id(1))
    }

    @Test func weakClaimsAreNotPremises() {
        let due = Self.fact(102, 1, .dueOn, due: "2026-12-01")
        let weakOwners: [KnowledgeWikiSnapshot.Fact] = [
            Self.fact(101, 1, .assignedTo, object: 2, polarity: .negative),
            Self.fact(101, 1, .assignedTo, object: 2, modality: .proposed),
            Self.fact(101, 1, .assignedTo, object: 2, modality: .inferred)
        ]
        for owner in weakOwners { #expect(KnowledgeInference.deriveCommitments(from: [owner, due]).commitments.isEmpty) }
        let owner = Self.fact(101, 1, .assignedTo, object: 2)
        let weakDue = Self.fact(102, 1, .dueOn, due: "2026-12-01", modality: .hypothetical)
        #expect(KnowledgeInference.deriveCommitments(from: [owner, weakDue]).commitments.isEmpty)
    }

    @Test func aMovedDeadlineGivesEveryDateNotAChosenOne() {
        let result = KnowledgeInference.deriveCommitments(from: [
            Self.fact(101, 1, .assignedTo, object: 2),
            Self.fact(103, 1, .dueOn, due: "2026-12-15"), Self.fact(102, 1, .dueOn, due: "2026-12-01")
        ])
        #expect(result.commitments.map(\.due.text) == ["2026-12-01", "2026-12-15"])
    }

    @Test func anActionWithoutAnOwnerOrADateDerivesNothing() {
        #expect(KnowledgeInference.deriveCommitments(from: [Self.fact(101, 1, .assignedTo, object: 2)]).commitments.isEmpty)
        #expect(KnowledgeInference.deriveCommitments(from: [Self.fact(102, 1, .dueOn, due: "2026-12-01")]).commitments.isEmpty)
    }

    @Test func theOutputIsTheSameInAnyOrder() {
        let facts = [Self.fact(101, 1, .assignedTo, object: 2), Self.fact(102, 1, .dueOn, due: "2026-12-01"),
                     Self.fact(103, 3, .owns, object: 4), Self.fact(104, 4, .dueOn, due: "2026-11-30")]
        #expect(KnowledgeInference.deriveCommitments(from: facts) == KnowledgeInference.deriveCommitments(from: facts.reversed()))
    }

    @Test func aCrowdedActionIsMarkedTruncatedAtTheBound() {
        var facts: [KnowledgeWikiSnapshot.Fact] = []
        for owner in 0..<21 { facts.append(Self.fact(1000 + owner, 1, .assignedTo, object: 100 + owner)) }
        for day in 1...20 { facts.append(Self.fact(2000 + day, 1, .dueOn, due: String(format: "2026-12-%02d", day))) }
        let result = KnowledgeInference.deriveCommitments(from: facts)
        #expect(result.isTruncated)
        #expect(result.commitments.count == KnowledgeInference.maximumEdges)
    }

    @Test func aClaimRepeatedOnTwoPagesCountsOnce() {
        let owner = Self.fact(101, 1, .assignedTo, object: 2)
        let due = Self.fact(102, 1, .dueOn, due: "2026-12-01")
        let result = KnowledgeInference.deriveCommitments(from: [owner, due, owner, due])
        #expect(result.commitments.count == 1)
    }

    @Test func selfOwnershipAndNonDateDueValuesDeriveNothing() {
        let selfOwned = [Self.fact(101, 1, .assignedTo, object: 1), Self.fact(103, 1, .owns, object: 1),
                         Self.fact(102, 1, .dueOn, due: "2026-12-01")]
        #expect(KnowledgeInference.deriveCommitments(from: selfOwned).commitments.isEmpty)
        // A due claim without a date value is not a date.
        let noDate = [Self.fact(101, 1, .assignedTo, object: 2), Self.fact(102, 1, .dueOn)]
        #expect(KnowledgeInference.deriveCommitments(from: noDate).commitments.isEmpty)
    }
}
