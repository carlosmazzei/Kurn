//
//  SherpaOnnxModelDownloader.swift
//  Kurn
//
//  Fetches sherpa-onnx's diarization model pair on demand: the
//  pyannote/segmentation-3.0 segmentation model and the 3D-Speaker CAM++
//  speaker-embedding model, both converted to ONNX and hosted on k2-fsa's own
//  GitHub releases (not a gated HuggingFace repo). Unlike the FluidAudio
//  engines — whose models are downloaded by the FluidAudio package itself —
//  sherpa-onnx has no downloader of its own, so this is a second direct model
//  download alongside `WhisperCppModelDownloader`.
//
//  Pure `Foundation`, no `import` of the sherpa-onnx module, so it compiles
//  whether or not the binary package is linked (`KurnTests` does not link it).
//

import Foundation
import KurnCore

/// Downloads and locates sherpa-onnx's diarization models under
/// `Application Support/SherpaOnnx/Models/`.
enum SherpaOnnxModelDownloader {

    /// Root for both sherpa-onnx model files. Kept separate from FluidAudio's
    /// and whisper.cpp's roots so neither downloader can see or delete the
    /// other's files (see `ModelStore.ModelGroup.root`).
    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SherpaOnnx/Models", isDirectory: true)
    }

    /// One subfolder per model file (`segmentation`/`embedding`), mirroring
    /// whisper.cpp's per-variant folders — `ModelStore` reports and deletes
    /// FluidAudio-shaped model groups by folder, not by loose file, so each
    /// model gets a folder of its own even though there is only ever one file
    /// in it.
    static var segmentationDirectory: URL {
        modelsDirectory.appendingPathComponent("segmentation", isDirectory: true)
    }

    static var embeddingDirectory: URL {
        modelsDirectory.appendingPathComponent("embedding", isDirectory: true)
    }

    static var segmentationModelURL: URL {
        segmentationDirectory.appendingPathComponent(segmentationFileName)
    }

    static var embeddingModelURL: URL {
        embeddingDirectory.appendingPathComponent(embeddingFileName)
    }

    /// Folder names `ModelStore` groups this downloader's files under.
    static let folderNames = ["segmentation", "embedding"]

    /// Converted from `pyannote/segmentation-3.0` (MIT) by sherpa-onnx's
    /// maintainer. The pinned, public Hugging Face file is byte-identical to
    /// `model.onnx` inside k2-fsa's official GitHub release archive.
    private static let segmentationFileName = "sherpa-onnx-pyannote-segmentation-3-0.onnx"
    private static let segmentationDownloadURL = URL(
        string: "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/9403a6902bb58e3d5ae8c7e77c3422de279db2e0/model.onnx"
    )!
    /// ~5.7 MiB upstream; loose lower bound so a truncated transfer is
    /// re-fetched rather than handed to sherpa-onnx as a corrupt model.
    private static let segmentationMinimumPlausibleBytes: Int64 = 3 * 1_000_000

    /// CAM++ speaker embedding model from the 3D-Speaker project (Apache-2.0),
    /// converted to ONNX by k2-fsa.
    ///
    /// This exact filename is published under k2-fsa's
    /// `speaker-recongition-models` GitHub release (the tag's spelling is
    /// upstream's, not a typo introduced here).
    private static let embeddingFileName = "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
    private static let embeddingDownloadURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
    )!
    /// ~28 MB upstream.
    private static let embeddingMinimumPlausibleBytes: Int64 = 15 * 1_000_000

    /// Whether both model files are on disk and large enough to be complete.
    static var isInstalled: Bool {
        ModelFileDownloader.installedSize(of: segmentationModelURL) >= segmentationMinimumPlausibleBytes
            && ModelFileDownloader.installedSize(of: embeddingModelURL) >= embeddingMinimumPlausibleBytes
    }

    /// Download both model files unless already installed. Progress is
    /// reported as a `0...1` fraction split evenly across the two transfers
    /// (segmentation is the much smaller of the two, but there is no cost
    /// signal cheap enough to weight the split more precisely than that).
    static func download(
        policy: LargeTransferPolicy = .wifiOnly,
        onProgress: @escaping @Sendable (ModelDownloadStatus) -> Void = { _ in }
    ) async throws {
        if isInstalled {
            AppLog.transcription.atDebug.debug("sherpaOnnxDownload: already installed")
            onProgress(ModelDownloadStatus(fractionCompleted: 1, phase: .compiling))
            return
        }

        onProgress(ModelDownloadStatus(fractionCompleted: 0, phase: .preparing))
        try await ModelFileDownloader.fetch(
            url: segmentationDownloadURL,
            destination: segmentationModelURL,
            minimumPlausibleBytes: segmentationMinimumPlausibleBytes,
            policy: policy,
            logLabel: "sherpaOnnxDownload"
        ) { fraction in
            onProgress(ModelDownloadStatus(fractionCompleted: fraction * 0.5, phase: .downloading))
        }
        try await ModelFileDownloader.fetch(
            url: embeddingDownloadURL,
            destination: embeddingModelURL,
            minimumPlausibleBytes: embeddingMinimumPlausibleBytes,
            policy: policy,
            logLabel: "sherpaOnnxDownload"
        ) { fraction in
            onProgress(ModelDownloadStatus(fractionCompleted: 0.5 + fraction * 0.5, phase: .downloading))
        }
        onProgress(ModelDownloadStatus(fractionCompleted: 1, phase: .compiling))
        AppLog.transcription.atNotice.notice("sherpaOnnxDownload: both models installed")
    }
}
