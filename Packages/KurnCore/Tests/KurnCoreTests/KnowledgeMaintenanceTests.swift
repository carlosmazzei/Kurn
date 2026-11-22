import Foundation
import Testing
@testable import KurnCore

struct KnowledgeMaintenanceTests {
    private let entity = UUID()
    private let assertion = UUID()
    private let evidence = UUID()
    private let recording = UUID()

    private func input() -> KnowledgeMaintenanceInput {
        var input = KnowledgeMaintenanceInput(revision: 7)
        input.entities = [.init(id: entity, isOrphan: false)]
        input.assertionIDs = [assertion]
        input.evidenceIDs = [evidence]
        var page = KnowledgeMaintenanceInput.Page(entityID: entity, revision: 7)
        page.entityLinks = [entity]
        page.evidenceLinks = [evidence]
        page.assertionIDs = [assertion]
        page.narrativeAssertionIDs = [assertion]
        input.pages = [page]
        input.projection = .current
        input.coverage = [.init(recordingID: recording, totalSegments: 3, examinedSegments: 3, state: .current)]
        return input
    }

    @Test func cleanReportIsDeterministicAndRoundTripsTheMaintenanceSchema() throws {
        let first = try KnowledgeMaintenanceLinter.inspect(input())
        #expect(first.version == 1)
        #expect(first.revision == 7)
        #expect(first.isClean)
        #expect(first.coverage[0].examinedSegments == 3)
        #expect(try KnowledgeMaintenanceReport.decode(first.canonicalData()) == first)
        #expect(try first.canonicalData() == KnowledgeMaintenanceLinter.inspect(input()).canonicalData())
        var empty = KnowledgeMaintenanceInput(revision: 0)
        #expect(try KnowledgeMaintenanceLinter.inspect(empty).isClean)
        empty.isComplete = false
        #expect(try !KnowledgeMaintenanceLinter.inspect(empty).isClean)
    }

    @Test func brokenLinksNeverDiscloseUnknownOrExcludedTargets() throws {
        var input = input()
        let hidden = UUID()
        input.pages[0].entityLinks.insert(hidden)
        input.pages[0].evidenceLinks.insert(hidden)
        input.pages[0].assertionIDs.insert(hidden)
        input.pages[0].narrativeAssertionIDs.insert(hidden)
        input.pages[0].matchesCanonical = false
        let report = try KnowledgeMaintenanceLinter.inspect(input)
        #expect(Set(report.findings.map(\.code)) == [.brokenEntityLink, .brokenEvidenceLink, .invalidProjection, .invalidNarrative])
        #expect(report.findings.allSatisfy { $0.subjects == [.init(.entity, entity)] })
        let data = try report.canonicalData()
        #expect(!String(decoding: data, as: UTF8.self).lowercased().contains(hidden.uuidString.lowercased()))
        #expect(try KnowledgeMaintenanceReport.decode(data) == report)
        input.pages = [.init(entityID: hidden, revision: 7)]
        let unknownPage = try KnowledgeMaintenanceLinter.inspect(input)
        #expect(unknownPage.findings.map(\.code) == [.invalidProjection])
        #expect(unknownPage.findings[0].subjects.isEmpty)
    }

    @Test func staleProjectionsDoNotInspectTheirOldIdentifiers() throws {
        var input = input()
        input.pages[0].entityLinks = [UUID()]
        input.pages[0].evidenceLinks = [UUID()]
        input.projection = .stale
        #expect(try KnowledgeMaintenanceLinter.inspect(input).findings.map(\.code) == [.staleProjection])
        input.projection = .missing
        #expect(try KnowledgeMaintenanceLinter.inspect(input).findings.map(\.code) == [.projectionMissing])
        input.projection = .unreadable
        #expect(try KnowledgeMaintenanceLinter.inspect(input).findings.map(\.code) == [.artifactUnreadable])
        input.projection = .current
        input.pages[0] = .init(entityID: entity, revision: 6)
        #expect(try KnowledgeMaintenanceLinter.inspect(input).findings.map(\.code) == [.staleProjection])
    }

    @Test func orphanAndIdentityCandidatesAreStableReviewOnlyFindings() throws {
        var input = input()
        let other = UUID()
        let hidden = UUID()
        input.entities.append(.init(id: other, isOrphan: true))
        input.candidates = [.init(entity, other), .init(other, entity), .init(entity, entity), .init(entity, hidden)]
        let report = try KnowledgeMaintenanceLinter.inspect(input)
        #expect(report.findings.count == 2)
        #expect(Set(report.findings.map(\.code)) == [.orphanEntity, .duplicateCandidate])
        #expect(report.findings.first { $0.code == .duplicateCandidate }?.recommendation == .reviewIdentity)
        input.entities.reverse()
        input.candidates.reverse()
        #expect(try KnowledgeMaintenanceLinter.inspect(input) == report)
        #expect(!String(decoding: try report.canonicalData(), as: UTF8.self).lowercased().contains(hidden.uuidString.lowercased()))
    }

    @Test func coverageStatesAndPartialExaminationAreExplicit() throws {
        var input = input()
        input.coverage = KnowledgeMaintenanceCoverage.State.allCases.map {
            .init(recordingID: UUID(), totalSegments: 4, examinedSegments: $0 == .current ? 2 : 0, state: $0)
        }
        let report = try KnowledgeMaintenanceLinter.inspect(input)
        #expect(Set(report.findings.map(\.code)) == [.coverageGap, .compilationMissing, .sourceChanged, .policyChanged, .transcriptMissing, .artifactUnreadable])
        #expect(report.coverage.reduce(0) { $0 + $1.examinedSegments } == 2)
        #expect(report.coverage.reduce(0) { $0 + $1.totalSegments } == 24)
        input.coverage.reverse()
        #expect(try KnowledgeMaintenanceLinter.inspect(input) == report)
    }

    @Test func malformedAndOversizedInputsCannotProduceHealthyPartialReports() throws {
        var invalids: [KnowledgeMaintenanceInput] = []
        var negative = input(); negative.revision = -1; invalids.append(negative)
        var duplicate = input(); duplicate.entities += duplicate.entities; invalids.append(duplicate)
        var pages = input(); pages.pages += pages.pages; invalids.append(pages)
        var coverage = input(); coverage.coverage += coverage.coverage; invalids.append(coverage)
        var invalidCount = input()
        invalidCount.coverage = [.init(recordingID: recording, totalSegments: 1, examinedSegments: 2, state: .current)]
        invalids.append(invalidCount)
        for invalid in invalids {
            #expect(throws: KnowledgeMaintenanceError.invalidInput) { try KnowledgeMaintenanceLinter.inspect(invalid) }
        }
        var huge = input()
        huge.entities = Array(repeating: .init(id: entity, isOrphan: false), count: 2_049)
        #expect(throws: KnowledgeMaintenanceError.limitExceeded) { try KnowledgeMaintenanceLinter.inspect(huge) }
    }

    @Test func reportVersionsAndRecommendationsUseClosedVocabularies() throws {
        let clean = try KnowledgeMaintenanceLinter.inspect(input())
        var raw = try #require(JSONSerialization.jsonObject(with: clean.canonicalData()) as? [String: Any])
        raw["version"] = 99
        #expect(throws: KnowledgeMaintenanceError.unsupportedReport) { try KnowledgeMaintenanceReport.decode(JSONSerialization.data(withJSONObject: raw)) }
        raw["version"] = 1
        raw["revision"] = -1
        #expect(throws: KnowledgeMaintenanceError.invalidInput) { try KnowledgeMaintenanceReport.decode(JSONSerialization.data(withJSONObject: raw)) }
        for code in KnowledgeMaintenanceFinding.Code.allCases {
            let finding = KnowledgeMaintenanceFinding(code: code, subjects: [.init(.entity, entity), .init(.entity, entity), .init(.assertion, assertion)])
            #expect(finding.subjects.count == 2)
            #expect(finding.id.contains(code.rawValue))
            #expect(!finding.recommendation.rawValue.isEmpty)
            let encoded = try JSONEncoder().encode(finding)
            #expect(try JSONDecoder().decode(KnowledgeMaintenanceFinding.self, from: encoded) == finding)
            var fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(fields["id"] as? String == finding.id)
            #expect(fields["recommendation"] as? String == finding.recommendation.rawValue)
            fields["id"] = "forged-id"
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(KnowledgeMaintenanceFinding.self, from: JSONSerialization.data(withJSONObject: fields))
            }
        }
    }
}
