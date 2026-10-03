//
//  ModelDownloadConsent.swift
//  Kurn
//
//  Single place that downloads FluidAudio's CoreML models after the user
//  consents in Settings. Each `ModelSet` case only triggers its own model
//  family's download — enabling live transcription never fetches the
//  diarization models, and vice versa.
//

import Foundation
import KurnCore

enum ModelSet: Sendable, Equatable {
    case liveTranscriptionASR
    case onDeviceASR
    case diarization
    case vad
    /// whisper.cpp GGML weights. Carries the variant because, unlike the
    /// FluidAudio sets, the user chooses which weight file to download.
    case whisperCppASR(WhisperCppModel)
    /// sherpa-onnx's diarization model pair (segmentation + speaker embedding
    /// ONNX files). Brings its own downloader, unrelated to FluidAudio's —
    /// same shape as `whisperCppASR`.
    case sherpaOnnxDiarization

    var isInstalled: Bool {
        switch self {
        case .whisperCppASR(let model):
            WhisperCppModelDownloader.isInstalled(model)
        case .sherpaOnnxDiarization:
            SherpaOnnxModelDownloader.isInstalled
        case .liveTranscriptionASR:
            ModelStore.isInstalled(.liveTranscription)
        case .onDeviceASR:
            ModelStore.isInstalled(.onDeviceLanguage)
        case .diarization:
            ModelStore.isInstalled(.diarization)
        case .vad:
            ModelStore.isInstalled(.vad)
        }
    }
}

enum ModelDownloadPhase: Sendable, Equatable {
    case preparing
    case downloading
    case compiling
}

struct ModelDownloadStatus: Sendable, Equatable {
    var fractionCompleted: Double
    var phase: ModelDownloadPhase

    /// One step of a download that owns only `lowerBound...upperBound` of the
    /// overall bar (live transcription warms two models, each half of it).
    /// The reported fraction is clamped first, so a library overshooting 1
    /// or reporting a negative value can never move the bar backwards or
    /// past its slice.
    static func scaled(
        _ fraction: Double,
        from lowerBound: Double,
        to upperBound: Double,
        phase: ModelDownloadPhase
    ) -> ModelDownloadStatus {
        let clamped = min(1, max(0, fraction))
        return ModelDownloadStatus(
            fractionCompleted: lowerBound + clamped * (upperBound - lowerBound),
            phase: phase
        )
    }
}

struct ModelDownloadConsent {
    static func validateNetworkIfDownloadNeeded(
        for sets: [ModelSet],
        policy: LargeTransferPolicy,
        network: some NetworkPathSnapshotProviding = NetworkPathObserver.shared,
        isInstalled: @escaping @Sendable (ModelSet) -> Bool = { $0.isInstalled }
    ) throws {
        if sets.contains(where: { !isInstalled($0) }) {
            try policy.validate(network.snapshot)
        }
    }

    static func download(
        _ set: ModelSet,
        policy: LargeTransferPolicy = .wifiOnly,
        network: some NetworkPathSnapshotProviding = NetworkPathObserver.shared,
        isInstalled: @escaping @Sendable (ModelSet) -> Bool = { $0.isInstalled },
        onProgress: @escaping @Sendable (ModelDownloadStatus) -> Void = { _ in }
    ) async throws {
        try validateNetworkIfDownloadNeeded(
            for: [set],
            policy: policy,
            network: network,
            isInstalled: isInstalled
        )
        try await ResourceGuard.requireModelDownloadHeadroom()
        // Handled before the FluidAudio branch below: whisper.cpp brings its own
        // downloader, so this set must work in a build without FluidAudio linked.
        if case .whisperCppASR(let model) = set {
            try await WhisperCppModelDownloader.download(
                model,
                policy: policy,
                onProgress: onProgress
            )
            try await ResourceGuard.requireModelDownloadHeadroom()
            return
        }
        // Same reasoning as `.whisperCppASR` above: sherpa-onnx brings its own
        // downloader, unrelated to FluidAudio, so this set must also work in a
        // build without FluidAudio linked.
        if case .sherpaOnnxDiarization = set {
            try await SherpaOnnxModelDownloader.download(
                policy: policy,
                onProgress: onProgress
            )
            try await ResourceGuard.requireModelDownloadHeadroom()
            return
        }
        #if canImport(FluidAudio)
        try await downloadFluidAudioModels(set, policy: policy, network: network, onProgress: onProgress)
        #else
        throw AppError.modelDownloadRequired(
            NSLocalizedString("settings.fluid_audio.package_missing", comment: "FluidAudio package missing")
        )
        #endif
    }

    /// What a failed FluidAudio download surfaces as: an `AppError` unchanged;
    /// a URL failure the transfer policy explains as `.networkPolicyRestricted`
    /// rather than "offline"; a resource failure (disk full) as itself; and
    /// anything else as `.modelDownloadFailed`. Pure so it is tested without a
    /// real download.
    static func downloadFailure(
        for error: Error,
        policy: LargeTransferPolicy,
        snapshot: NetworkPathSnapshot
    ) -> AppError {
        if let appError = error as? AppError { return appError }
        if let restriction = LargeTransferPolicy.restrictionError(for: error, policy: policy, snapshot: snapshot) {
            return restriction
        }
        if let resource = ResourceGuard.appErrorIfResourceFailure(error) { return resource }
        return .modelDownloadFailed(error.localizedDescription)
    }
}
