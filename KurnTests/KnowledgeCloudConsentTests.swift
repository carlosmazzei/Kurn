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

    @Test func aGrantNamesTheProviderForInternalSourcesAndChangesTheRevision() {
        let settings = MeetingFixtures.isolatedSettings()
        settings.grantCloudConsent(.openAI, for: .onRequest)
        let policy = KnowledgeCompilationCoordinator.localPolicy(settings)
        #expect(policy.allowedRemoteProviderIDs == [AIProvider.openAI.id])
        #expect(policy.maxRemoteClassification == .internal)
        #expect(policy.revision != KnowledgeProcessingPolicy.defaultDeny().revision)
        #expect(KnowledgeCompilationCoordinator.localPolicy(settings).revision == policy.revision)
    }

    @Test func policyRevisionDependsOnlyOnTheProviderSet() {
        let revision = KnowledgeCompilationCoordinator.policyRevision(["a", "b"])
        #expect(revision == KnowledgeCompilationCoordinator.policyRevision(["b", "a"]))
        #expect(revision != KnowledgeCompilationCoordinator.policyRevision(["a"]))
        #expect(revision > 1)
    }

    @Test func extractionConsentNeedsTheAutomaticGrant() {
        let settings = MeetingFixtures.isolatedSettings()
        settings.grantCloudConsent(.openAI, for: .onRequest)
        #expect(!settings.allowsCloud(.openAI, for: .automatic))
        settings.grantCloudConsent(.openAI, for: .automatic)
        #expect(settings.allowsCloud(.openAI, for: .automatic))
    }
}
