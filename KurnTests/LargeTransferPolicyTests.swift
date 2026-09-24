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

    @Test func bareOfflineErrorOnABlockedPathIsReportedAsPolicy() throws {
        var request = URLRequest(url: try #require(URL(string: "https://api.example.com/upload")))
        LargeTransferPolicy.wifiOnly.apply(to: &request)
        let offline = URLError(.notConnectedToInternet)

        for snapshot in [
            NetworkPathSnapshot(isExpensive: true, isConstrained: false),
            NetworkPathSnapshot(isExpensive: false, isConstrained: true)
        ] {
            let mapped = LargeTransferPolicy.restrictionError(for: offline, request: request, snapshot: snapshot)
            #expect(mapped?.logCode == "network_policy_restricted")
        }
    }

    @Test func genuinelyOfflineStaysANetworkError() throws {
        var request = URLRequest(url: try #require(URL(string: "https://api.example.com/upload")))
        LargeTransferPolicy.wifiOnly.apply(to: &request)

        // No usable path at all: neither expensive nor constrained.
        #expect(LargeTransferPolicy.restrictionError(
            for: URLError(.notConnectedToInternet),
            request: request,
            snapshot: NetworkPathSnapshot(isExpensive: false, isConstrained: false)
        ) == nil)
        // A request that already allows the path was not blocked by policy.
        var permissive = request
        LargeTransferPolicy(allowsExpensiveAccess: true, allowsConstrainedAccess: true).apply(to: &permissive)
        #expect(LargeTransferPolicy.restrictionError(
            for: URLError(.notConnectedToInternet),
            request: permissive,
            snapshot: NetworkPathSnapshot(isExpensive: true, isConstrained: true)
        ) == nil)
        // Other transport failures are never reclassified.
        #expect(LargeTransferPolicy.restrictionError(
            for: URLError(.timedOut),
            request: request,
            snapshot: NetworkPathSnapshot(isExpensive: true, isConstrained: false)
        ) == nil)
    }

    /// The model downloaders hold a policy rather than a request; the same
    /// judgement must come out of either entry point.
    @Test func policyEntryPointMatchesTheRequestOne() {
        let offline = URLError(.notConnectedToInternet)
        let cellular = NetworkPathSnapshot(isExpensive: true, isConstrained: false)

        #expect(LargeTransferPolicy.restrictionError(
            for: offline, policy: .wifiOnly, snapshot: cellular
        )?.logCode == "network_policy_restricted")
        #expect(LargeTransferPolicy.restrictionError(
            for: offline,
            policy: LargeTransferPolicy(allowsExpensiveAccess: true, allowsConstrainedAccess: false),
            snapshot: cellular
        ) == nil)
        #expect(LargeTransferPolicy.restrictionError(
            for: offline,
            policy: .wifiOnly,
            snapshot: NetworkPathSnapshot(isExpensive: true, isConstrained: false, isKnown: false)
        ) == nil)
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
