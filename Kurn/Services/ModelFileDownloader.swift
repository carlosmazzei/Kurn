//
//  ModelFileDownloader.swift
//  Kurn
//
//  Shared transfer-and-install mechanics for the app's direct model
//  downloads (`WhisperCppModelDownloader`, `SherpaOnnxModelDownloader`).
//  Each downloader keeps its own catalog — URLs, plausible sizes, folder
//  layout — and delegates the fetch → verify → stage → atomically-install
//  sequence here.
//
//  H7 PR 15: this used to trust a downloaded file the moment it cleared a
//  loose "roughly half the expected size" floor, and installed it by
//  removing whatever was there first and then moving the new file in — a
//  failure between those two steps left no model installed at all, not a
//  corrupt one. `ModelDownloading` is now an injectable seam (a protocol,
//  not a bare enum of static functions) so tests can exercise the
//  fetch/verify/install sequence against `MockURLProtocol` instead of a
//  real host. `verify(_:minimumPlausibleBytes:)` checks the downloaded
//  byte count against the server's own declared `Content-Length` exactly
//  (not a loose floor) and, when the origin volunteers one, a SHA-256
//  digest computed from the actual bytes received. `install(_:at:)` uses
//  `FileManager.replaceItemAt(_:withItemAt:backupItemName:)` to swap the
//  new file in atomically, keeping a backup that a failed post-install
//  re-verification restores from — so a failure at any point (transfer,
//  verification, or the install step itself) always leaves the previous
//  valid model exactly as it was, never absent and never silently corrupt.
//
//  What this deliberately does NOT do, and why: pin an exact SHA-256 or an
//  immutable source revision (commit SHA / release asset digest) as a
//  hardcoded manifest. Doing that responsibly requires fetching the real,
//  current values from the hosting services (HuggingFace, GitHub) to pin
//  against — and this change was authored in an environment with no
//  network path to either host to obtain them. A wrong hardcoded hash or a
//  commit SHA that stops existing would be worse than the loose check it
//  replaced: every future download would fail outright instead of just
//  being under-verified. `linkedHashHex(from:)` below is the honest
//  middle ground the roadmap's own wording allows for ("verify a
//  published exact size plus SHA-256, **or a stronger signed manifest**"):
//  it verifies the downloaded bytes against whatever integrity signal the
//  origin volunteers for *this* transfer, over HTTPS, rather than
//  fabricating a pinned value that was never actually confirmed against
//  the real file. See "PR 15" in docs/resilience-megaplan.md for the full
//  reasoning and what a follow-up with real network access should still do.
//
//  Pure `Foundation` (+ `CryptoKit` via `PipelineDigest`), no engine
//  imports, so it compiles whether or not the binary packages are linked
//  (`KurnTests` does not link them).
//

import Foundation
import KurnCore

/// The seam `ModelFileDownloader` conforms to, so a test can inject a fake
/// instead of exercising a real `URLSession` (H7 PR 15) — the same shape
/// `KeychainAccessing` (H7 PR 14) and `CloudKeyValueStore` give their own
/// system dependencies.
protocol ModelDownloading: Sendable {
    func fetch(
        url: URL,
        destination: URL,
        minimumPlausibleBytes: Int64,
        policy: LargeTransferPolicy,
        logLabel: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws
}

/// Transfers one model file and installs it, verified and atomically, in
/// place of whatever (if anything) already exists at the destination.
///
/// An `actor` rather than the previous bare enum of static functions: it
/// needs to hold resume data between one failed/cancelled attempt and the
/// next for the same destination, which has to be mutable state protected
/// from concurrent access.
actor ModelFileDownloader: ModelDownloading {
    static let shared = ModelFileDownloader()

    /// Resume data from the most recent interrupted attempt, keyed by
    /// destination. In-memory only and cleared on relaunch — resume data
    /// is itself best-effort across long gaps (Apple's own documentation
    /// says as much), so nothing here claims to survive one; it only
    /// avoids restarting a download the user cancelled or that dropped
    /// moments ago from byte zero.
    private var resumeDataByDestination: [URL: Data] = [:]

    /// Overrides the transfer session's protocol stack. `nil` in production
    /// (the real network); tests construct their own instance with
    /// `MockURLProtocol` here instead of using `.shared` (H7 PR 15).
    private let protocolClasses: [AnyClass]?

    init(protocolClasses: [AnyClass]? = nil) {
        self.protocolClasses = protocolClasses
    }

    /// Size of the file at `url`, or 0 when it does not exist — callers
    /// compare against a model's minimum plausible size so a truncated
    /// transfer is re-fetched rather than handed to an engine as corrupt.
    /// `nonisolated`: a pure filesystem read touching no actor state, kept
    /// callable synchronously from the many non-async `isInstalled` call
    /// sites this repository already has.
    nonisolated static func installedSize(of url: URL) -> Int64 {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return 0 }
        return Int64(size)
    }

    /// Download `url` to `destination` unless a plausible file is already
    /// there. Errors are mapped to the shared vocabulary: policy
    /// restrictions surface as their own `AppError`, resource failures are
    /// rethrown, cooperative cancellation propagates as `CancellationError`
    /// (never wrapped, so a caller's `catch is CancellationError` still
    /// works), and everything else becomes `.modelDownloadFailed`.
    /// `logLabel` prefixes the log lines so each downloader's stream stays
    /// greppable.
    func fetch(
        url: URL,
        destination: URL,
        minimumPlausibleBytes: Int64,
        policy: LargeTransferPolicy,
        logLabel: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard Self.installedSize(of: destination) < minimumPlausibleBytes else { return }
        AppLog.transcription.atNotice.notice(
            "\(logLabel, privacy: .public): fetching \(destination.lastPathComponent, privacy: .public)"
        )

        let priorResumeData = resumeDataByDestination.removeValue(forKey: destination)
        let outcome: Downloader.Outcome
        do {
            outcome = try await Downloader().download(
                from: url,
                resumeData: priorResumeData,
                policy: policy,
                protocolClasses: protocolClasses,
                onProgress: onProgress
            )
        } catch let interruption as Downloader.TransferInterruption {
            if let data = interruption.resumeData {
                resumeDataByDestination[destination] = data
            }
            if interruption.underlying is CancellationError {
                throw CancellationError()
            }
            try Self.translate(interruption.underlying, logLabel: logLabel)
            return
        }

        do {
            try Self.verify(outcome, minimumPlausibleBytes: minimumPlausibleBytes)
            try Self.install(outcome.fileURL, at: destination, expectedHashHex: Self.linkedHashHex(from: outcome.response))
            AppLog.transcription.atNotice.notice(
                "\(logLabel, privacy: .public): installed \(destination.lastPathComponent, privacy: .public)"
            )
        } catch {
            try? FileManager.default.removeItem(at: outcome.fileURL)
            // A verification/install failure means the bytes themselves were
            // wrong (or the move corrupted them) — resume data for this
            // attempt would only resume onto more of the same, so the next
            // attempt starts a fresh, full transfer instead.
            resumeDataByDestination[destination] = nil
            if let appError = error as? AppError {
                throw appError
            }
            try Self.translate(error, logLabel: logLabel)
        }
    }

    private static func translate(_ error: Error, logLabel: String) throws -> Never {
        if let restriction = LargeTransferPolicy.restrictionError(for: error) {
            throw restriction
        }
        AppLog.transcription.atError.error("\(logLabel, privacy: .public): failed code=download_failed")
        try ResourceGuard.rethrowIfResourceFailure(error)
        throw AppError.modelDownloadFailed(error.localizedDescription)
    }

    // MARK: - Verification

    /// Checks the downloaded byte count against the server's own declared
    /// `Content-Length` exactly (falling back to the loose plausibility
    /// floor only when the server didn't report a length at all), and — if
    /// the origin volunteered one — the file's SHA-256 against it. See the
    /// file header for why this app cannot pin an out-of-band manifest
    /// value here instead.
    private static func verify(_ outcome: Downloader.Outcome, minimumPlausibleBytes: Int64) throws {
        let actualSize = installedSize(of: outcome.fileURL)
        let expectedLength = outcome.response.expectedContentLength
        if expectedLength > 0 {
            guard actualSize == expectedLength else {
                throw AppError.modelDownloadFailed(
                    "downloaded \(actualSize) bytes, server declared \(expectedLength)"
                )
            }
        } else {
            guard actualSize >= minimumPlausibleBytes else {
                throw AppError.modelDownloadFailed("downloaded file is smaller than expected")
            }
        }
        if let expectedHex = linkedHashHex(from: outcome.response) {
            let actualHex = try PipelineDigest.sha256Hex(ofFileAt: outcome.fileURL)
            guard actualHex.caseInsensitiveCompare(expectedHex) == .orderedSame else {
                throw AppError.modelDownloadFailed("downloaded file did not match its published checksum")
            }
        }
    }

    /// A SHA-256 hex digest the server volunteered for this exact transfer.
    /// HuggingFace sets `X-Linked-ETag` on an LFS-backed file's response to
    /// the raw hex Git LFS object ID, which for every binary model file
    /// this app fetches is a SHA-256. A plain `ETag` — typically a quoted
    /// Git blob SHA-1, or an opaque cache key — is deliberately never
    /// treated as a hash to verify against: only a header value that is
    /// exactly 64 hex characters (SHA-256's length) is trusted as one.
    private static func linkedHashHex(from response: HTTPURLResponse) -> String? {
        guard let raw = response.value(forHTTPHeaderField: "X-Linked-ETag") else { return nil }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard trimmed.count == 64, trimmed.allSatisfy(\.isHexDigit) else { return nil }
        return trimmed
    }

    // MARK: - Atomic install

    /// Move the verified download into place. When something is already at
    /// `destination`, `FileManager.replaceItemAt(_:withItemAt:backupItemName:)`
    /// swaps it in atomically and keeps the previous file as a backup; if
    /// `expectedHashHex` was checked during download, the *installed* file
    /// is re-hashed too (a cheap re-check reusing the same digest, guarding
    /// against the move itself corrupting an already-verified transfer) and
    /// the backup is restored — never just deleted — on a mismatch. Either
    /// way, a failure at any point here leaves the previous valid model
    /// exactly as it was, never absent and never silently wrong.
    private static func install(_ downloadedURL: URL, at destination: URL, expectedHashHex: String?) throws {
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // Models are re-downloadable (and run to hundreds of megabytes),
            // so they must not travel in the user's iCloud backup.
            excludeFromBackup(folder)
        } catch {
            try? fm.removeItem(at: downloadedURL)
            try ResourceGuard.rethrowIfResourceFailure(error)
            throw AppError.modelDownloadFailed(error.localizedDescription)
        }

        let hadExisting = fm.fileExists(atPath: destination.path)
        let backupName = "\(destination.lastPathComponent).previous-\(UUID().uuidString)"
        let backupURL = folder.appendingPathComponent(backupName)

        do {
            if hadExisting {
                _ = try fm.replaceItemAt(destination, withItemAt: downloadedURL, backupItemName: backupName)
            } else {
                try fm.moveItem(at: downloadedURL, to: destination)
            }
        } catch {
            try? fm.removeItem(at: downloadedURL)
            try ResourceGuard.rethrowIfResourceFailure(error)
            throw AppError.modelDownloadFailed(error.localizedDescription)
        }
        defer { try? fm.removeItem(at: backupURL) }

        guard let expectedHashHex else { return }
        guard let actualHex = try? PipelineDigest.sha256Hex(ofFileAt: destination),
              actualHex.caseInsensitiveCompare(expectedHashHex) == .orderedSame else {
            try? fm.removeItem(at: destination)
            if hadExisting, fm.fileExists(atPath: backupURL.path) {
                try? fm.moveItem(at: backupURL, to: destination)
            }
            throw AppError.modelDownloadFailed("model failed its post-install integrity check")
        }
    }

    private static func excludeFromBackup(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }
}

/// Bridges `URLSessionDownloadTask` (delegate-based, with byte progress and
/// resume-data support) into async/await. One instance per download; the
/// session is invalidated on completion so the delegate reference cycle is
/// broken.
///
/// A plain (non-background) session is enough: `ModelDownloadController`
/// already wraps each model download in a `BackgroundActivity` window.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    struct Outcome {
        var fileURL: URL
        var response: HTTPURLResponse
    }

    /// A transfer that ended without a usable file — cooperative
    /// cancellation, a network drop, or anything else `URLSession` reports
    /// through `didCompleteWithError`. Carries resume data when the system
    /// (or `cancel(byProducingResumeData:)`) provided any, so the caller can
    /// continue instead of restarting.
    struct TransferInterruption: Error {
        var underlying: Error
        var resumeData: Data?
    }

    private var continuation: CheckedContinuation<Outcome, Error>?
    private var onProgress: (@Sendable (Double) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    /// Guards every property above, which the delegate callbacks and the
    /// cancellation handler touch from different queues.
    private let lock = NSLock()

    /// `protocolClasses` is exposed only so tests can inject `MockURLProtocol`
    /// in place of the real network stack; production callers never set it.
    func download(
        from url: URL,
        resumeData: Data?,
        policy: LargeTransferPolicy,
        protocolClasses: [AnyClass]? = nil,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Outcome {
        self.onProgress = onProgress
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        // Weight files run to hundreds of megabytes on a phone connection.
        configuration.timeoutIntervalForResource = 3600
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        policy.apply(to: configuration)
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                let downloadTask = resumeData.map { session.downloadTask(withResumeData: $0) }
                    ?? session.downloadTask(with: url)
                lock.lock()
                self.task = downloadTask
                lock.unlock()
                downloadTask.resume()
            }
        } onCancel: { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let task = self.task
            self.lock.unlock()
            guard let task else {
                // Nothing has started yet — there is no task whose
                // `cancel(byProducingResumeData:)` completion `finish` could
                // wait for, so resolve directly.
                self.finish(.failure(TransferInterruption(underlying: CancellationError(), resumeData: nil)))
                return
            }
            // Deliberately does not also call `session.invalidateAndCancel()`
            // here: that would race the completion handler below and could
            // tear the session down before it delivers resume data. `finish`
            // already invalidates the session (via `finishTasksAndInvalidate`)
            // once a result — from either this handler or the delegate's own
            // `didCompleteWithError`, whichever arrives first — is delivered.
            task.cancel { [weak self] data in
                self?.finish(.failure(TransferInterruption(underlying: CancellationError(), resumeData: data)))
            }
        }
    }

    /// Deliver the result exactly once. Both a delegate callback and the
    /// cancellation handler can race to call this for the same download;
    /// whichever arrives first wins and every later call is a no-op.
    private func finish(_ result: Result<Outcome, Error>) {
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
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            finish(.failure(AppError.modelDownloadFailed("HTTP \(response.statusCode)")))
            return
        }
        guard let response = downloadTask.response as? HTTPURLResponse else {
            finish(.failure(AppError.modelDownloadFailed("no HTTP response")))
            return
        }
        // `location` is deleted as soon as this method returns, so the file has
        // to be moved out synchronously, before handing it to the caller. Kept
        // in the same `kurn_model_` prefix `TempFileCleaner` already sweeps, so
        // an orphaned staged file left behind by a crash is cleaned up the same
        // way every other pipeline temp file is (H7 PR 15).
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurn_model_\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            finish(.success(Outcome(fileURL: staged, response: response)))
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
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        finish(.failure(TransferInterruption(underlying: error, resumeData: resumeData)))
    }
}
