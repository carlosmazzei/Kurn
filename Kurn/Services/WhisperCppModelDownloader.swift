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
        let url = fileURL(for: model)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return false }
        return Int64(size) >= model.minimumPlausibleBytes
    }

    /// Download `model` unless it is already installed. Progress is reported as
    /// a `0...1` fraction of the transfer.
    static func download(
        _ model: WhisperCppModel,
        policy: LargeTransferPolicy = .wifiOnly,
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
        AppLog.transcription.atNotice.notice(
            "whisperCppDownload: fetching \(model.fileName, privacy: .public)"
        )

        let temporaryURL: URL
        do {
            temporaryURL = try await Downloader().download(
                from: model.downloadURL,
                policy: policy
            ) { fraction in
                onProgress(ModelDownloadStatus(fractionCompleted: fraction, phase: .downloading))
            }
        } catch let appError as AppError {
            throw appError
        } catch {
            if let restriction = LargeTransferPolicy.restrictionError(for: error) {
                throw restriction
            }
            AppLog.transcription.atError.error("whisperCppDownload: failed code=download_failed")
            try ResourceGuard.rethrowIfResourceFailure(error)
            throw AppError.modelDownloadFailed(error.localizedDescription)
        }

        try install(temporaryURL, as: model)
        onProgress(ModelDownloadStatus(fractionCompleted: 1, phase: .compiling))
        AppLog.transcription.atNotice.notice(
            "whisperCppDownload: installed \(model.fileName, privacy: .public)"
        )
    }

    /// Move the finished transfer into place. The move is the last step, so an
    /// interrupted download never leaves a partial file where `isInstalled`
    /// would find it.
    private static func install(_ downloadedURL: URL, as model: WhisperCppModel) throws {
        let fm = FileManager.default
        let folder = directory(for: model)
        let destination = fileURL(for: model)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // Weights are re-downloadable and up to ~570 MB, so they must not
            // travel in the user's iCloud backup.
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
/// A plain (non-background) session is enough: `ModelDownloadController` already
/// wraps the whole download in a `BackgroundActivity` window, exactly as it does
/// for the FluidAudio downloads.
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
        // Weight files run to hundreds of megabytes on a phone connection.
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
            .appendingPathComponent("kurn_whisper_\(UUID().uuidString).bin")
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
