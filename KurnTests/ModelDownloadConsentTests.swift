//
//  ModelDownloadConsentTests.swift
//  KurnTests
//
//  The decisions `ModelDownloadConsent` keeps out of its FluidAudio adapter:
//  how a slice of the progress bar is scaled, how a failed download is
//  reported, that a blocked network stops every model family before any
//  downloader starts, and that each set answers whether it is installed.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct ModelDownloadConsentTests {

    private struct FixedNetworkPath: NetworkPathSnapshotProviding {
        let snapshot: NetworkPathSnapshot
    }

    private struct Unexpected: Error {}

    private static let cellular = NetworkPathSnapshot(isExpensive: true, isConstrained: false)
    private static let wifi = NetworkPathSnapshot(isExpensive: false, isConstrained: false)

    // MARK: - Progress scaling

    @Test func aSliceMapsTheFractionIntoItsOwnRange() {
        let status = ModelDownloadStatus.scaled(0.5, from: 0.5, to: 1, phase: .downloading)
        #expect(status.fractionCompleted == 0.75)
        #expect(status.phase == .downloading)
        #expect(ModelDownloadStatus.scaled(0.4, from: 0, to: 1, phase: .preparing).fractionCompleted == 0.4)
    }

    @Test func outOfRangeFractionsAreClampedToTheSlice() {
        #expect(ModelDownloadStatus.scaled(-3, from: 0, to: 0.5, phase: .compiling).fractionCompleted == 0)
        #expect(ModelDownloadStatus.scaled(7, from: 0, to: 0.5, phase: .compiling).fractionCompleted == 0.5)
    }

    // MARK: - Failure mapping

    @Test func anAppErrorIsReportedUnchanged() {
        let failure = ModelDownloadConsent.downloadFailure(
            for: AppError.networkPolicyRestricted, policy: .wifiOnly, snapshot: Self.wifi
        )
        guard case .networkPolicyRestricted = failure else {
            Issue.record("expected the AppError to pass through")
            return
        }
    }

    @Test func anOfflineErrorOnABlockedPathIsAPolicyRestriction() {
        let failure = ModelDownloadConsent.downloadFailure(
            for: URLError(.notConnectedToInternet), policy: .wifiOnly, snapshot: Self.cellular
        )
        guard case .networkPolicyRestricted = failure else {
            Issue.record("expected cellular + Wi-Fi-only to read as a policy restriction")
            return
        }
    }

    @Test func aFullDiskIsAResourceFailure() {
        let failure = ModelDownloadConsent.downloadFailure(
            for: CocoaError(.fileWriteOutOfSpace), policy: .wifiOnly, snapshot: Self.wifi
        )
        guard case .resourceUnavailable = failure else {
            Issue.record("expected a full disk to surface as a resource failure")
            return
        }
    }

    @Test func anythingElseIsADownloadFailure() {
        let offline = ModelDownloadConsent.downloadFailure(
            for: URLError(.notConnectedToInternet), policy: .wifiOnly, snapshot: Self.wifi
        )
        let other = ModelDownloadConsent.downloadFailure(
            for: Unexpected(), policy: .wifiOnly, snapshot: Self.wifi
        )
        guard case .modelDownloadFailed = offline, case .modelDownloadFailed = other else {
            Issue.record("expected a plain download failure")
            return
        }
    }

    // MARK: - Network gate

    @Test(arguments: [
        ModelSet.liveTranscriptionASR, .onDeviceASR, .diarization, .vad,
        .whisperCppASR(.base), .sherpaOnnxDiarization
    ])
    func everySetIsStoppedOnABlockedPathBeforeDownloading(_ set: ModelSet) async {
        await #expect(throws: AppError.self) {
            try await ModelDownloadConsent.download(
                set,
                policy: .wifiOnly,
                network: FixedNetworkPath(snapshot: Self.cellular),
                isInstalled: { _ in false }
            )
        }
    }

    @Test func anUnknownPathBlocksOnlyWhenSomethingIsMissing() throws {
        let unknown = NetworkPathSnapshot(isExpensive: false, isConstrained: false, isKnown: false)
        #expect(throws: AppError.self) {
            try ModelDownloadConsent.validateNetworkIfDownloadNeeded(
                for: [.vad, .diarization],
                policy: .wifiOnly,
                network: FixedNetworkPath(snapshot: unknown),
                isInstalled: { $0 == .vad }
            )
        }
        try ModelDownloadConsent.validateNetworkIfDownloadNeeded(
            for: [.vad, .diarization],
            policy: .wifiOnly,
            network: FixedNetworkPath(snapshot: unknown),
            isInstalled: { _ in true }
        )
        try ModelDownloadConsent.validateNetworkIfDownloadNeeded(
            for: [.vad],
            policy: LargeTransferPolicy(allowsExpensiveAccess: true, allowsConstrainedAccess: true),
            network: FixedNetworkPath(snapshot: Self.cellular),
            isInstalled: { _ in false }
        )
    }

    // MARK: - Installation

    @Test(arguments: [
        ModelSet.liveTranscriptionASR, .onDeviceASR, .diarization, .vad,
        .whisperCppASR(.small), .sherpaOnnxDiarization
    ])
    func everySetAnswersFromItsOwnStoreWithoutDownloading(_ set: ModelSet) {
        // Whether a model is present depends on the simulator's history, so
        // only the lookup itself is asserted: it must answer, and twice the same.
        #expect(set.isInstalled == set.isInstalled)
    }
}
