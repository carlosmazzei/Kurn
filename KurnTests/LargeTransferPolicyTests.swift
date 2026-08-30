//
//  LargeTransferPolicyTests.swift
//  KurnTests
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct LargeTransferPolicyTests {
    @Test func wifiOnlyRejectsExpensiveAndConstrainedPaths() {
        #expect(throws: AppError.self) {
            try LargeTransferPolicy.wifiOnly.validate(
                NetworkPathSnapshot(isExpensive: true, isConstrained: false)
            )
        }
        #expect(throws: AppError.self) {
            try LargeTransferPolicy.wifiOnly.validate(
                NetworkPathSnapshot(isExpensive: false, isConstrained: true)
            )
        }
        #expect(throws: AppError.self) {
            try LargeTransferPolicy.wifiOnly.validate(
                NetworkPathSnapshot(isExpensive: false, isConstrained: false, isKnown: false)
            )
        }
    }

    @Test func enabledCostsAllowTheMatchingPaths() throws {
        let policy = LargeTransferPolicy(
            allowsExpensiveAccess: true,
            allowsConstrainedAccess: true
        )
        try policy.validate(NetworkPathSnapshot(isExpensive: true, isConstrained: true))
    }

    @Test func nativeNetworkRejectionMapsToPolicyError() {
        for reason in [
            URLError.NetworkUnavailableReason.expensive,
            URLError.NetworkUnavailableReason.constrained
        ] {
            let error = URLError(
                .notConnectedToInternet,
                userInfo: [NSURLErrorNetworkUnavailableReasonKey: reason.rawValue]
            )
            #expect(LargeTransferPolicy.restrictionError(for: error)?.logCode == "network_policy_restricted")
        }
    }

    @Test func modelDownloadFailsBeforeStartingOnBlockedPath() async {
        await #expect(throws: AppError.self) {
            try await ModelDownloadConsent.download(
                .vad,
                policy: .wifiOnly,
                network: FixedNetworkPath(
                    snapshot: NetworkPathSnapshot(isExpensive: true, isConstrained: false)
                ),
                isInstalled: { _ in false }
            )
        }
    }

    @Test func installedModelsDoNotRequireNetworkApproval() throws {
        try ModelDownloadConsent.validateNetworkIfDownloadNeeded(
            for: [.vad],
            policy: .wifiOnly,
            network: FixedNetworkPath(
                snapshot: NetworkPathSnapshot(isExpensive: true, isConstrained: true)
            ),
            isInstalled: { _ in true }
        )
    }

    @Test func policyAppliesNativeURLSessionFlags() throws {
        var request = URLRequest(url: try #require(URL(string: "https://api.example.com/upload")))
        let configuration = URLSessionConfiguration.ephemeral

        LargeTransferPolicy.wifiOnly.apply(to: &request)
        LargeTransferPolicy.wifiOnly.apply(to: configuration)

        #expect(request.allowsExpensiveNetworkAccess == false)
        #expect(request.allowsConstrainedNetworkAccess == false)
        #expect(configuration.allowsExpensiveNetworkAccess == false)
        #expect(configuration.allowsConstrainedNetworkAccess == false)
    }
}

private struct FixedNetworkPath: NetworkPathSnapshotProviding {
    let snapshot: NetworkPathSnapshot
}
