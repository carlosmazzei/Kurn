//
//  WhisperCppModelDownloader.swift
//  Kurn
//
//  Fetches whisper.cpp's GGML weight files on demand. Unlike the FluidAudio
//  engines — whose models are downloaded by the FluidAudio package itself —
//  whisper.cpp has no downloader of its own, so this is the app's only direct
//  model download.
//
//  Pure `Foundation`, no `import whisper`, so it compiles whether or not the
//  binary package is linked (`KurnTests` does not link it).
//

import Foundation
import KurnCore

/// Downloads and locates whisper.cpp models under
/// `Application Support/WhisperCpp/Models/<variant>/ggml-<variant>.bin`.
enum WhisperCppModelDownloader {

    /// Root for every whisper.cpp weight file. Kept separate from FluidAudio's
    /// `Application Support/FluidAudio/Models` so neither downloader can see or
    /// delete the other's files (see `ModelStore.ModelGroup.root`).
    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WhisperCpp/Models", isDirectory: true)
    }

    static func directory(for model: WhisperCppModel) -> URL {
        modelsDirectory.appendingPathComponent(model.folderName, isDirectory: true)
    }

    static func fileURL(for model: WhisperCppModel) -> URL {
        directory(for: model).appendingPathComponent(model.fileName)
    }

    /// Whether the weights are on disk and large enough to be a complete file.
    /// A transfer interrupted by termination leaves nothing behind (the move is
    /// the last step), but a server that truncates a response would, so the size
    /// is checked rather than mere existence.
    static func isInstalled(_ model: WhisperCppModel) -> Bool {
        ModelFileDownloader.installedSize(of: fileURL(for: model)) >= model.minimumPlausibleBytes
    }

    /// Download `model` unless it is already installed. Progress is reported as
    /// a `0...1` fraction of the transfer. `downloader` is injectable (H7 PR
    /// 15) so tests can exercise this against `MockURLProtocol`; production
    /// callers never pass it.
    static func download(
        _ model: WhisperCppModel,
        policy: LargeTransferPolicy = .wifiOnly,
        downloader: any ModelDownloading = ModelFileDownloader.shared,
        onProgress: @escaping @Sendable (ModelDownloadStatus) -> Void = { _ in }
    ) async throws {
        if isInstalled(model) {
            AppLog.transcription.atDebug.debug(
                "whisperCppDownload: \(model.fileName, privacy: .public) already installed"
            )
            onProgress(ModelDownloadStatus(fractionCompleted: 1, phase: .compiling))
            return
        }

        onProgress(ModelDownloadStatus(fractionCompleted: 0, phase: .preparing))
        try await downloader.fetch(
            url: model.downloadURL,
            destination: fileURL(for: model),
            minimumPlausibleBytes: model.minimumPlausibleBytes,
            policy: policy,
            logLabel: "whisperCppDownload"
        ) { fraction in
            onProgress(ModelDownloadStatus(fractionCompleted: fraction, phase: .downloading))
        }
        onProgress(ModelDownloadStatus(fractionCompleted: 1, phase: .compiling))

        // H7 PR 16: PR 15's `fetch` already proved the transfer matched its
        // declared size (and, when offered, a checksum) — but a byte-correct
        // file can still fail to load (wrong GGML version, a corruption PR
        // 15's checks don't cover). Prove it loads before calling this
        // install done, so that failure surfaces now instead of at the next
        // real transcription.
        do {
            try await WhisperCppTranscriber.verifyModelLoads(at: fileURL(for: model))
        } catch {
            try? FileManager.default.removeItem(at: directory(for: model))
            AppLog.transcription.atError.error(
                "whisperCppDownload: \(model.fileName, privacy: .public) failed post-install verification"
            )
            throw AppError.modelDownloadFailed("downloaded model failed to load — the file may be corrupt")
        }
        ModelVerification.record(
            id: ModelVerification.recordID(for: .whisperCpp, folder: model.folderName),
            size: ModelFileDownloader.installedSize(of: fileURL(for: model))
        )
        AppLog.transcription.atNotice.notice(
            "whisperCppDownload: installed \(model.fileName, privacy: .public)"
        )
    }
}
