import Foundation
import KurnCore
import Testing
@testable import Kurn

struct ModelDownloadExplicitPolicyTests {
    private struct CellularNetwork: NetworkPathSnapshotProviding {
        let snapshot = NetworkPathSnapshot(isExpensive: true, isConstrained: false)
    }

    private static let fluidAudioSets: [ModelSet] = [
        .onDeviceASR, .diarization, .liveTranscriptionASR, .vad,
        .fluidAudioDiarization(.nemotron3), .fluidAudioUnifiedStreaming
    ] + FluidAudioASRModel.allCases.map { .fluidAudioASR($0) }

    @Test(arguments: ModelDownloadExplicitPolicyTests.fluidAudioSets)
    func cachedExplicitPreparationStillRejectsBlockedTransfers(_ set: ModelSet) async {
        do {
            try await ModelDownloadConsent.download(
                set,
                policy: .wifiOnly,
                network: CellularNetwork(),
                isInstalled: { _ in true },
                onProgress: { _ in
                    Issue.record("Blocked explicit preparation must not start library work or report progress")
                }
            )
            Issue.record("Expected cached explicit preparation to enforce the transfer policy")
        } catch AppError.networkPolicyRestricted {
            return
        } catch {
            Issue.record("Unexpected cached-preparation error: \(error)")
        }
    }

    @Test func installedLocalOnlyChecksStillSkipTransferPolicyValidation() throws {
        try ModelDownloadConsent.validateNetworkIfDownloadNeeded(
            for: Self.fluidAudioSets,
            policy: .wifiOnly,
            network: CellularNetwork(),
            isInstalled: { _ in true }
        )
    }
}
