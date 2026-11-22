//
//  KnowledgeCloudConsentTests.swift
//  KurnTests
//
//  Knowledge follows the shared cloud-consent ledger: the local policy names
//  only providers with a grant, and Ask consents only under the on-request one.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

@MainActor
struct KnowledgeCloudConsentTests {
    @Test func theLocalPolicyDeniesEveryRemoteProviderWithoutAGrant() {
        let policy = KnowledgeCompilationCoordinator.localPolicy(MeetingFixtures.isolatedSettings())
        #expect(policy == .defaultDeny(id: KnowledgeCompilationCoordinator.localPolicyID))
        #expect(policy.allowedRemoteProviderIDs.isEmpty)
    }

    @Test func aGrantNamesTheProviderWithoutChangingTheRevision() {
        let settings = MeetingFixtures.isolatedSettings()
        let before = KnowledgePolicyEvaluator.revisionKey([KnowledgeCompilationCoordinator.localPolicy(settings)])
        settings.grantCloudConsent(.openAI, for: .onRequest)
        let policy = KnowledgeCompilationCoordinator.localPolicy(settings)
        #expect(policy.allowedRemoteProviderIDs == [AIProvider.openAI.id])
        #expect(policy.maxRemoteClassification == .internal)
        // Existing Knowledge stays readable: its policy revision key is unchanged.
        #expect(KnowledgePolicyEvaluator.revisionKey([policy]) == before)
    }

    @Test func exportIsAllowedOnlyWhileTurnedOnAndKeepsTheRevision() {
        let settings = MeetingFixtures.isolatedSettings()
        let export = KnowledgeProcessingRequest(operation: .export, destination: .onDevice,
                                                sourceClassifications: [.internal], userConsentedToRemote: false)
        let before = KnowledgeCompilationCoordinator.localPolicy(settings)
        #expect(!KnowledgePolicyEvaluator.evaluate(export, under: [before], featureEnabled: true).isAllowed)
        settings.knowledgeExportEnabled = true
        let policy = KnowledgeCompilationCoordinator.localPolicy(settings)
        #expect(policy.exportAllowed && policy.allowedOperations.contains(.export))
        #expect(policy.allowedRemoteProviderIDs.isEmpty && policy.maxRemoteClassification == nil)
        #expect(KnowledgePolicyEvaluator.evaluate(export, under: [policy], featureEnabled: true).isAllowed)
        #expect(!KnowledgePolicyEvaluator.evaluate(export, under: [policy], featureEnabled: false).isAllowed)
        #expect(KnowledgePolicyEvaluator.revisionKey([policy]) == KnowledgePolicyEvaluator.revisionKey([before]))
        try? settings.resetKnowledgeControls()
        #expect(!settings.knowledgeExportEnabled)
    }

    @Test func extractionConsentNeedsTheAutomaticGrant() {
        let settings = MeetingFixtures.isolatedSettings()
        settings.grantCloudConsent(.openAI, for: .onRequest)
        #expect(!settings.allowsCloud(.openAI, for: .automatic))
        settings.grantCloudConsent(.openAI, for: .automatic)
        #expect(settings.allowsCloud(.openAI, for: .automatic))
    }
}
