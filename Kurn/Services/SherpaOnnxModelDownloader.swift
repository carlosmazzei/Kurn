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
        installedSize(of: segmentationModelURL) >= segmentationMinimumPlausibleBytes
            && installedSize(of: embeddingModelURL) >= embeddingMinimumPlausibleBytes
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
        try await fetch(
            url: segmentationDownloadURL,
            destination: segmentationModelURL,
            minimumPlausibleBytes: segmentationMinimumPlausibleBytes,
            policy: policy
        ) { fraction in
            onProgress(ModelDownloadStatus(fractionCompleted: fraction * 0.5, phase: .downloading))
        }
        try await fetch(
            url: embeddingDownloadURL,
            destination: embeddingModelURL,
            minimumPlausibleBytes: embeddingMinimumPlausibleBytes,
            policy: policy
        ) { fraction in
            onProgress(ModelDownloadStatus(fractionCompleted: 0.5 + fraction * 0.5, phase: .downloading))
        }
        onProgress(ModelDownloadStatus(fractionCompleted: 1, phase: .compiling))
        AppLog.transcription.atNotice.notice("sherpaOnnxDownload: both models installed")
    }

    private static func installedSize(of url: URL) -> Int64 {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return 0 }
        return Int64(size)
    }

    private static func fetch(
        url: URL,
        destination: URL,
        minimumPlausibleBytes: Int64,
        policy: LargeTransferPolicy,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard installedSize(of: destination) < minimumPlausibleBytes else { return }
        AppLog.transcription.atNotice.notice("sherpaOnnxDownload: fetching \(destination.lastPathComponent, privacy: .public)")
        let temporaryURL: URL
        do {
            temporaryURL = try await Downloader().download(
                from: url,
                policy: policy,
                onProgress: onProgress
            )
        } catch let appError as AppError {
            throw appError
        } catch {
            if let restriction = LargeTransferPolicy.restrictionError(for: error) {
                throw restriction
            }
            AppLog.transcription.atError.error("sherpaOnnxDownload: failed code=download_failed")
            try ResourceGuard.rethrowIfResourceFailure(error)
            throw AppError.modelDownloadFailed(error.localizedDescription)
        }
        try install(temporaryURL, at: destination)
    }

    /// Move the finished transfer into place. The move is the last step, so an
    /// interrupted download never leaves a partial file where `isInstalled`
    /// would find it.
    private static func install(_ downloadedURL: URL, at destination: URL) throws {
        let fm = FileManager.default
        do {
            let folder = destination.deletingLastPathComponent()
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // Models are re-downloadable, so they must not travel in the
            // user's iCloud backup.
            excludeFromBackup(folder)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: downloadedURL, to: destination)
        } catch {
            try? fm.removeItem(at: downloadedURL)
            try ResourceGuard.rethrowIfResourceFailure(error)
            throw AppError.modelDownloadFailed(error.localizedDescription)
        }
    }

    private static func excludeFromBackup(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }
}

/// Bridges `URLSessionDownloadTask` (delegate-based, with byte progress) into
/// async/await. One instance per download; the session is invalidated on
/// completion so the delegate reference cycle is broken.
///
/// Duplicated from `WhisperCppModelDownloader`'s private `Downloader` rather
/// than shared — both are small, file-private, and neither downloader depends
/// on the other.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private var continuation: CheckedContinuation<URL, Error>?
    private var onProgress: (@Sendable (Double) -> Void)?
    private var session: URLSession?
    /// Guards the continuation, which the delegate callbacks touch from the
    /// session's own queue.
    private let lock = NSLock()

    func download(
        from url: URL,
        policy: LargeTransferPolicy,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        self.onProgress = onProgress
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        policy.apply(to: configuration)
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    /// Deliver the result exactly once — `didFinishDownloadingTo` and
    /// `didCompleteWithError` both fire for a successful download.
    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        session?.finishTasksAndInvalidate()
        continuation.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // `location` is deleted as soon as this method returns, so the file has
        // to be moved out synchronously, before handing it to the caller.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurn_sherpa_\(UUID().uuidString).onnx")
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            finish(.failure(AppError.modelDownloadFailed("HTTP \(response.statusCode)")))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            finish(.success(staged))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress?(min(1, max(0, fraction)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finish(.failure(error))
    }
}
