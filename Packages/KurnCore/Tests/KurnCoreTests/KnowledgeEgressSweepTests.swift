//
//  KnowledgeEgressSweepTests.swift
//  KurnCoreTests
//
//  K6.1: every operation, classification, consent, provider and policy shape,
//  checked against the egress invariants rather than a few chosen examples.
//

import Foundation
import Testing
@testable import KurnCore

struct KnowledgeEgressSweepTests {
    private let provider = "corporate-llm"
    private let ceilings: [KnowledgeClassification?] = [nil] + KnowledgeClassification.allCases

    private var policies: [KnowledgeProcessingPolicy] {
        ceilings.flatMap { ceiling in
            [false, true].flatMap { export in
                [KnowledgeProcessingPolicy.onDeviceOperations, Set(KnowledgeOperation.allCases), [.answerSynthesis]].map {
                    KnowledgeProcessingPolicy(allowedRemoteProviderIDs: [provider], allowedOperations: $0,
                                              maxRemoteClassification: ceiling, exportAllowed: export)
                }
            }
        }
    }

    private var requests: [KnowledgeProcessingRequest] {
        KnowledgeOperation.allCases.flatMap { operation in
            KnowledgeClassification.allCases.flatMap { classification in
                [true, false].flatMap { consented in
                    [provider, "other-llm"].map {
                        KnowledgeProcessingRequest(operation: operation, destination: .remote(providerID: $0),
                                                   sourceClassifications: [.unrestricted, classification],
                                                   userConsentedToRemote: consented)
                    }
                }
            }
        }
    }

    @Test func remoteWorkIsAllowedOnlyWhenEveryConditionHolds() {
        for policy in policies {
            for request in requests {
                guard case let .remote(providerID) = request.destination else { continue }
                let classification = request.sourceClassifications.max() ?? .restricted
                let withinCeiling = policy.maxRemoteClassification.map { classification <= $0 } ?? false
                let expected = request.userConsentedToRemote
                    && policy.allowedRemoteProviderIDs.contains(providerID)
                    && policy.allowedOperations.contains(request.operation)
                    && (request.operation != .export || policy.exportAllowed)
                    && withinCeiling
                let decision = KnowledgePolicyEvaluator.evaluate(request, under: [policy], featureEnabled: true)
                #expect(decision.isAllowed == expected, "\(request) under \(policy)")
            }
        }
    }

    @Test func nothingLeavesTheDeviceUnderTheDefaultOrWithoutTheFeature() {
        for policy in policies {
            for request in requests {
                #expect(!KnowledgePolicyEvaluator.evaluate(request, under: [policy], featureEnabled: false).isAllowed)
                #expect(!KnowledgePolicyEvaluator.evaluate(request, under: [], featureEnabled: true).isAllowed)
                #expect(!KnowledgePolicyEvaluator.evaluate(request, under: [.defaultDeny()], featureEnabled: true).isAllowed)
                // A default-deny source or context policy narrows any workspace back to the device.
                #expect(!KnowledgePolicyEvaluator.evaluate(request, under: [policy, .defaultDeny()], featureEnabled: true)
                    .isAllowed)
            }
        }
    }

    @Test func withdrawingConsentDeniesEveryRemoteRequestThatWasAllowed() {
        for policy in policies {
            for request in requests where KnowledgePolicyEvaluator.evaluate(request, under: [policy], featureEnabled: true)
                .isAllowed {
                var withdrawn = request
                withdrawn.userConsentedToRemote = false
                #expect(KnowledgePolicyEvaluator.evaluate(withdrawn, under: [policy], featureEnabled: true)
                    == .denied(.consentMissing))
            }
        }
    }
}
