//
//  KnowledgeProcessingPolicyTests.swift
//  KurnCoreTests
//
//  Pins the Knowledge Engine's egress boundary: nothing leaves the device by
//  default, the strictest policy and classification win, corporate
//  authorization is checked before consent, and no filter widens access.
//

import Foundation
import Testing
@testable import KurnCore

struct KnowledgeProcessingPolicyTests {
    private let provider = "corporate-llm"

    private func remoteWorkspace(
        ceiling: KnowledgeClassification? = .confidential,
        operations: Set<KnowledgeOperation> = KnowledgeProcessingPolicy.onDeviceOperations,
        exportAllowed: Bool = false
    ) -> KnowledgeProcessingPolicy {
        KnowledgeProcessingPolicy(
            allowedRemoteProviderIDs: [provider],
            allowedOperations: operations,
            maxRemoteClassification: ceiling,
            exportAllowed: exportAllowed
        )
    }

    private func remoteRequest(
        _ operation: KnowledgeOperation = .extraction,
        sources: [KnowledgeClassification] = [.internal],
        consented: Bool = true,
        providerID: String? = nil
    ) -> KnowledgeProcessingRequest {
        KnowledgeProcessingRequest(
            operation: operation,
            destination: .remote(providerID: providerID ?? provider),
            sourceClassifications: sources,
            userConsentedToRemote: consented
        )
    }

    private func decide(_ request: KnowledgeProcessingRequest, _ policies: [KnowledgeProcessingPolicy]) -> KnowledgePolicyDecision {
        KnowledgePolicyEvaluator.evaluate(request, under: policies, featureEnabled: true)
    }

    private func local(_ operation: KnowledgeOperation, _ sources: [KnowledgeClassification]) -> KnowledgeProcessingRequest {
        KnowledgeProcessingRequest(operation: operation, destination: .onDevice, sourceClassifications: sources)
    }

    @Test func disabledFeatureRefusesEverything() {
        let request = local(.extraction, [.unrestricted])
        #expect(KnowledgePolicyEvaluator.evaluate(request, under: [.defaultDeny()], featureEnabled: false) == .denied(.featureDisabled))
    }

    @Test func noPolicyIsARefusalNotAnAllowance() {
        let request = local(.extraction, [.unrestricted])
        #expect(decide(request, []) == .denied(.noPolicy))
    }

    @Test func workWithNoSourceIsRefused() {
        let request = local(.answerSynthesis, [])
        #expect(decide(request, [.defaultDeny()]) == .denied(.noSources))
    }

    @Test func defaultAllowsOnDeviceWorkAtAnyClassification() {
        for operation in KnowledgeProcessingPolicy.onDeviceOperations {
            let request = local(operation, [.restricted])
            #expect(decide(request, [.defaultDeny()]) == .allowed)
        }
    }

    @Test func defaultDeniesEveryRemoteDestinationEvenWithConsent() {
        for operation in KnowledgeOperation.allCases where operation != .export {
            let decision = decide(remoteRequest(operation, sources: [.unrestricted]), [.defaultDeny()])
            #expect(decision == .denied(.destinationNotAuthorized))
        }
    }

    @Test func defaultDeniesExport() {
        let request = local(.export, [.unrestricted])
        #expect(decide(request, [.defaultDeny()]) == .denied(.operationNotAllowed))
    }

    @Test func exportNeedsBothTheOperationAndTheExportFlag() {
        let request = local(.export, [.internal])
        let operationOnly = remoteWorkspace(operations: Set(KnowledgeOperation.allCases), exportAllowed: false)
        let both = remoteWorkspace(operations: Set(KnowledgeOperation.allCases), exportAllowed: true)
        #expect(decide(request, [operationOnly]) == .denied(.exportNotAllowed))
        #expect(decide(request, [both]) == .allowed)
    }

    @Test func authorizedRemoteNeedsConsent() {
        let workspace = remoteWorkspace()
        #expect(decide(remoteRequest(consented: true), [workspace]) == .allowed)
        #expect(decide(remoteRequest(consented: false), [workspace]) == .denied(.consentMissing))
    }

    @Test func consentNeverSubstitutesForCorporateAuthorization() {
        let workspace = remoteWorkspace()
        let otherProvider = remoteRequest(consented: true, providerID: "public-llm")
        #expect(decide(otherProvider, [workspace]) == .denied(.destinationNotAuthorized))
        // Without consent the corporate refusal is still the one reported.
        let unconsented = remoteRequest(sources: [.restricted], consented: false)
        #expect(decide(unconsented, [workspace]) == .denied(.classificationTooHigh))
    }

    @Test func theMostRestrictedSourceDecidesTheClassification() {
        let workspace = remoteWorkspace(ceiling: .internal)
        #expect(decide(remoteRequest(sources: [.unrestricted, .internal]), [workspace]) == .allowed)
        let mixed = remoteRequest(sources: [.unrestricted, .confidential, .internal])
        #expect(decide(mixed, [workspace]) == .denied(.classificationTooHigh))
        #expect(KnowledgeClassification.inherited(from: [.internal, .restricted, .unrestricted]) == .restricted)
        #expect(KnowledgeClassification.inherited(from: []) == nil)
    }

    @Test func aWorkspaceWithoutACeilingKeepsEverythingLocal() {
        let workspace = remoteWorkspace(ceiling: nil)
        #expect(decide(remoteRequest(sources: [.unrestricted]), [workspace]) == .denied(.classificationTooHigh))
    }

    @Test func aStricterSourcePolicyNarrowsTheWorkspace() {
        let workspace = remoteWorkspace(ceiling: .confidential)
        let source = KnowledgeProcessingPolicy(
            allowedRemoteProviderIDs: [provider],
            allowedOperations: [.extraction],
            maxRemoteClassification: .internal
        )
        #expect(decide(remoteRequest(.extraction), [workspace, source]) == .allowed)
        #expect(decide(remoteRequest(.embedding), [workspace, source]) == .denied(.operationNotAllowed))
        let confidential = remoteRequest(.extraction, sources: [.confidential])
        #expect(decide(confidential, [workspace]) == .allowed)
        #expect(decide(confidential, [workspace, source]) == .denied(.classificationTooHigh))
    }

    @Test func aLocalOnlyContextBlocksRemoteWorkTheWorkspaceAllows() {
        let workspace = remoteWorkspace()
        let localContext = KnowledgeProcessingPolicy.defaultDeny()
        #expect(decide(remoteRequest(), [workspace, localContext]) == .denied(.destinationNotAuthorized))
    }

    @Test func intersectionIsNeverWiderThanEitherSide() {
        let wide = KnowledgeProcessingPolicy(
            allowedRemoteProviderIDs: ["a", "b"],
            allowedOperations: Set(KnowledgeOperation.allCases),
            maxRemoteClassification: .restricted,
            exportAllowed: true
        )
        let narrow = KnowledgeProcessingPolicy(
            allowedRemoteProviderIDs: ["b", "c"],
            allowedOperations: [.extraction, .export],
            maxRemoteClassification: .internal,
            exportAllowed: false
        )
        for combined in [wide.intersection(narrow), narrow.intersection(wide)] {
            #expect(combined.allowedRemoteProviderIDs == ["b"])
            #expect(combined.allowedOperations == [.extraction, .export])
            #expect(combined.maxRemoteClassification == .internal)
            #expect(!combined.exportAllowed)
        }
        #expect(wide.intersection(.defaultDeny()).maxRemoteClassification == nil)
    }

    @Test func revisionKeyChangesWithAnyRevisionAndIgnoresOrder() {
        let first = KnowledgeProcessingPolicy(revision: 1)
        let second = KnowledgeProcessingPolicy(revision: 4)
        let key = KnowledgePolicyEvaluator.revisionKey([first, second])
        #expect(key == KnowledgePolicyEvaluator.revisionKey([second, first]))
        var bumped = second
        bumped.revision = 5
        #expect(key != KnowledgePolicyEvaluator.revisionKey([first, bumped]))
        #expect(KnowledgePolicyEvaluator.revisionKey([]) == "")
    }

    @Test func denialCodesAreStableSnakeCase() {
        for denial in KnowledgePolicyDenial.allCases {
            #expect(denial.rawValue.allSatisfy { $0.isLowercase || $0 == "_" })
        }
        #expect(KnowledgePolicyDenial.classificationTooHigh.rawValue == "classification_too_high")
    }

    @Test func policyRoundTripsThroughJSON() throws {
        let policy = remoteWorkspace(exportAllowed: true)
        let data = try JSONEncoder().encode(policy)
        #expect(try JSONDecoder().decode(KnowledgeProcessingPolicy.self, from: data) == policy)
        let destination = KnowledgeDestination.remote(providerID: provider)
        #expect(try JSONDecoder().decode(KnowledgeDestination.self, from: JSONEncoder().encode(destination)) == destination)
    }
}
