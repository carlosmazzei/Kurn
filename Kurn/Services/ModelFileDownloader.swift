//
//  ModelFileDownloader.swift
//  Kurn
//
//  Shared transfer-and-install mechanics for the app's direct model
//  downloads (`WhisperCppModelDownloader`, `SherpaOnnxModelDownloader`).
//  Each downloader keeps its own catalog — URLs, plausible sizes, folder
//  layout — and delegates the fetch → stage → move-into-place sequence here.
//
//  Pure `Foundation`, no engine imports, so it compiles whether or not the
//  binary packages are linked (`KurnTests` does not link them).
//

import Foundation
import KurnCore

enum ModelFileDownloader {

    /// Size of the file at `url`, or 0 when it does not exist — callers
    /// compare against a model's minimum plausible size so a truncated
    /// transfer is re-fetched rather than handed to an engine as corrupt.
    static func installedSize(of url: URL) -> Int64 {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return 0 }
        return Int64(size)
    }

    /// Download `url` to `destination` unless a plausible file is already
    /// there. Errors are mapped to the shared vocabulary: policy restrictions
    /// surface as their own `AppError`, resource failures are rethrown, and
    /// everything else becomes `.modelDownloadFailed`. `logLabel` prefixes the
    /// log lines so each downloader's stream stays greppable.
    static func fetch(
        url: URL,
        destination: URL,
        minimumPlausibleBytes: Int64,
        policy: LargeTransferPolicy,
        logLabel: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard installedSize(of: destination) < minimumPlausibleBytes else { return }
        AppLog.transcription.atNotice.notice(
            "\(logLabel, privacy: .public): fetching \(destination.lastPathComponent, privacy: .public)"
        )
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
            AppLog.transcription.atError.error("\(logLabel, privacy: .public): failed code=download_failed")
            try ResourceGuard.rethrowIfResourceFailure(error)
            throw AppError.modelDownloadFailed(error.localizedDescription)
        }
        try install(temporaryURL, at: destination)
    }

    /// Move the finished transfer into place. The move is the last step, so an
    /// interrupted download never leaves a partial file where an installation
    /// check would find it.
    static func install(_ downloadedURL: URL, at destination: URL) throws {
        let fm = FileManager.default
        do {
            let folder = destination.deletingLastPathComponent()
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // Models are re-downloadable (and run to hundreds of megabytes),
            // so they must not travel in the user's iCloud backup.
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
/// A plain (non-background) session is enough: `ModelDownloadController`
/// already wraps each model download in a `BackgroundActivity` window.
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
            .appendingPathComponent("kurn_model_\(UUID().uuidString)")
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
