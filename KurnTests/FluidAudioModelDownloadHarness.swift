import Foundation
import KurnCore
import Synchronization
import Testing
@testable import Kurn

final class FluidAudioDownloadScript: Sendable {
    struct Call: Equatable, Sendable {
        let set: ModelSet
        let policy: LargeTransferPolicy
    }

    private struct State: Sendable {
        var calls: [Call] = []
        var failure: Error?
        var waitsForCancellation = false
        var waitsForRelease = false
        var released = false
    }

    private let state = Mutex(State())

    var calls: [Call] { state.withLock { $0.calls } }

    func fail(with error: Error) { state.withLock { $0.failure = error } }
    func returnSuccessAfterCancellation() { state.withLock { $0.waitsForCancellation = true } }
    func holdUntilReleased() { state.withLock { $0.waitsForRelease = true } }
    func release() { state.withLock { $0.released = true } }

    var downloader: ModelDownloadController.Downloader {
        { [self] set, policy, progress in
            let (failure, waits, held) = state.withLock { state in
                state.calls.append(Call(set: set, policy: policy))
                return (state.failure, state.waitsForCancellation, state.waitsForRelease)
            }
            progress(ModelDownloadStatus(fractionCompleted: 0.5, phase: .downloading))
            if waits { try? await Task.sleep(for: .seconds(3_600)) }
            while held && !state.withLock({ $0.released }) {
                try await Task.sleep(for: .milliseconds(5))
            }
            if let failure { throw failure }
        }
    }
}

@MainActor
struct FluidAudioDownloadHarness {
    let script = FluidAudioDownloadScript()
    let settings: AppSettings
    let controller: ModelDownloadController
    let defaults: UserDefaults
    let suiteName: String

    init(
        installedASR: Set<FluidAudioASRModel> = [],
        installedDiarization: Set<FluidAudioDiarizationModel> = [],
        installedUnifiedStreaming: Bool = false,
        installedAutomaticLive: Bool = false
    ) throws {
        suiteName = "FluidAudioModelIntegrationTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        settings = AppSettings(cloudStore: InMemoryCloudKeyValueStore(), defaults: defaults)
        controller = ModelDownloadController(
            downloader: script.downloader,
            isWhisperCppInstalled: { _ in false },
            isFluidAudioASRInstalled: { installedASR.contains($0) },
            isFluidAudioDiarizationInstalled: { installedDiarization.contains($0) },
            isFluidAudioUnifiedStreamingInstalled: { installedUnifiedStreaming },
            isAutomaticFluidAudioLiveInstalled: { installedAutomaticLive }
        )
    }

    func awaitDownloadSettled() async {
        for _ in 0..<2_000 where controller.isDownloading {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!controller.isDownloading)
    }

    func awaitDownloadStarted() async {
        for _ in 0..<2_000 where script.calls.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!script.calls.isEmpty)
    }

    func modelEntry(
        _ group: ModelStore.ModelGroup,
        folders: [String]
    ) throws -> ModelStore.InstalledModel {
        for folder in folders {
            try #require(!FileManager.default.fileExists(atPath: group.root.appendingPathComponent(folder).path))
        }
        return ModelStore.InstalledModel(
            id: ModelVerification.recordID(for: group, folder: folders.first),
            group: group,
            displayName: "test",
            folderNames: folders,
            size: 0
        )
    }
}

@MainActor
func withFluidAudioDownloadHarness(
    installedASR: Set<FluidAudioASRModel> = [],
    installedDiarization: Set<FluidAudioDiarizationModel> = [],
    installedUnifiedStreaming: Bool = false,
    installedAutomaticLive: Bool = false,
    _ body: (FluidAudioDownloadHarness) async throws -> Void
) async throws {
    let harness = try FluidAudioDownloadHarness(
        installedASR: installedASR,
        installedDiarization: installedDiarization,
        installedUnifiedStreaming: installedUnifiedStreaming,
        installedAutomaticLive: installedAutomaticLive
    )
    defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }
    try await body(harness)
}
