//
//  WhisperBackgroundUploader.swift
//  Kurn
//
//  Uploads Whisper chunk requests over a background `URLSession` so an
//  in-flight upload survives the app being suspended or the phone locking:
//  the transfer runs in the system's out-of-process daemon and the app is
//  woken briefly for each completion, letting the chunk loop advance and
//  persist its checkpoint without the app staying in the foreground.
//
//  If the process is killed mid-upload the awaiting continuation dies with
//  it. The relaunch hook (`handleEvents`, called from the app delegate)
//  re-attaches the delegate so the session's remaining events are drained and
//  the system's completion handler is honored; the transcription itself
//  resumes from its checkpoint on the next foreground pass, losing at most
//  the one chunk that was in flight.
//

import Foundation

final class WhisperBackgroundUploader: NSObject, @unchecked Sendable {

    static let sessionIdentifier = "ai.kurn.whisper.upload"
    static let shared = WhisperBackgroundUploader()

    /// All mutable state below is guarded by `lock`; delegate callbacks arrive
    /// on the session's private queue while uploads are awaited from Swift
    /// concurrency executors.
    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<(Data, URLResponse), Error>] = [:]
    private var buffers: [Int: Data] = [:]
    private var bodyFiles: [Int: URL] = [:]
    private var eventsCompletionHandler: (@Sendable () -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Start transfers immediately — the user asked for this transcription;
        // don't let the system defer it for battery/network heuristics.
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        // Per-transfer budget. A 10-minute chunk uploads and transcribes in
        // well under an hour on any usable link; without a bound a dead
        // transfer would pin its continuation for the default 7 days.
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Relaunch hook: iOS calls the app delegate when transfers for this
    /// session finished while the app was dead. Touching `session` recreates
    /// it with the delegate attached so the pending events are delivered;
    /// the stored completion handler then tells the system we're done.
    static func handleEvents(identifier: String, completionHandler: @escaping @Sendable () -> Void) {
        guard identifier == sessionIdentifier else {
            completionHandler()
            return
        }
        shared.lock.lock()
        shared.eventsCompletionHandler = completionHandler
        shared.lock.unlock()
        _ = shared.session
    }

    /// Upload `body` for `request` and return the validated response, with the
    /// same transient-failure retry policy as `LLMHTTP.sendValidated`.
    /// Background sessions require file-based uploads, so the body is spooled
    /// to disk (readable while the device is locked) for the attempt.
    func sendValidated(_ request: URLRequest, body: Data) async throws -> (Data, URLResponse) {
        cleanupOrphanedUploadBodies()
        var attempt = 0
        while true {
            do {
                let (data, response) = try await upload(request, body: body)
                try LLMHTTP.validate(response: response, data: data)
                return (data, response)
            } catch let AppError.networkError(urlError) {
                guard let delay = LLMHTTP.retryableDelay(
                    attempt: attempt, status: nil, urlError: urlError, retryAfter: nil
                ) else { throw AppError.networkError(urlError) }
                AppLog.transcription.atInfo.info("bgUpload: retrying after network \(urlError.code.rawValue, privacy: .public)")
                try await Task.sleep(for: .seconds(delay))
                attempt += 1
            } catch let AppError.apiError(status, message) {
                guard let delay = LLMHTTP.retryableDelay(
                    attempt: attempt, status: status, urlError: nil, retryAfter: nil
                ) else { throw AppError.apiError(statusCode: status, message: message) }
                AppLog.transcription.atInfo.info("bgUpload: retrying after HTTP \(status, privacy: .public)")
                try await Task.sleep(for: .seconds(delay))
                attempt += 1
            }
        }
    }

    private func upload(_ request: URLRequest, body: Data) async throws -> (Data, URLResponse) {
        let bodyURL = try spoolBodyFile(body)
        let holder = UploadTaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.uploadTask(with: request, fromFile: bodyURL)
                lock.lock()
                continuations[task.taskIdentifier] = continuation
                buffers[task.taskIdentifier] = Data()
                bodyFiles[task.taskIdentifier] = bodyURL
                lock.unlock()
                AppLog.transcription.atInfo.info("bgUpload: started task=\(task.taskIdentifier, privacy: .public)")
                holder.start(task)
            }
        } onCancel: {
            // Cancelling the transfer makes the delegate complete with
            // URLError.cancelled, which the caller maps to a paused (.pending)
            // transcription rather than a failure.
            AppLog.transcription.atNotice.notice("bgUpload: Swift task cancelled — cancelling URLSession upload")
            holder.cancel()
        }
    }

    private func spoolBodyFile(_ body: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperUploadBodies", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + ".multipart")
        try body.write(to: url, options: [.atomic])
        // Readable while locked so uploads continue with the screen off. The
        // file is deleted as soon as its transfer completes; orphaned bodies
        // from process death are swept on the next upload.
        RecordingProtection.applyInFlight(to: url)
        return url
    }

    /// Remove leftover upload body files from earlier killed/crashed uploads.
    /// Unlike the generic tmp purge, this runs immediately so a recurring failure
    /// (e.g. long-chunk timeouts) does not accumulate one body file per attempt.
    /// Files currently tracked as in-flight are left untouched.
    private func cleanupOrphanedUploadBodies() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperUploadBodies", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let keys: [URLResourceKey] = [.nameKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        ) else { return }
        let inFlight = inFlightBodyFilePaths()
        var removed = 0
        for file in files where file.pathExtension == "multipart" && !inFlight.contains(file.path) {
            try? FileManager.default.removeItem(at: file)
            removed += 1
        }
        if removed > 0 {
            AppLog.transcription.atDebug.debug("bgUpload: cleaned up \(removed, privacy: .public) orphaned upload body file(s)")
        }
    }

    /// Paths of upload-body spool files currently attached to an in-flight
    /// `URLSessionUploadTask`. Exposed so other cleanup code (`TempFileCleaner`,
    /// which sweeps the same `WhisperUploadBodies` directory on a broader,
    /// age-based schedule and via the user-triggered "clear cache" action) can
    /// avoid deleting a file the background session is actively reading from disk.
    func inFlightBodyFilePaths() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(bodyFiles.values.map { $0.path })
    }
}

// MARK: - URLSession delegate

extension WhisperBackgroundUploader: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffers[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: task.taskIdentifier)
        let buffer = buffers.removeValue(forKey: task.taskIdentifier) ?? Data()
        let bodyFile = bodyFiles.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if let bodyFile {
            try? FileManager.default.removeItem(at: bodyFile)
        }

        guard let continuation else {
            // Completed after a relaunch — nobody is awaiting. The chunk loop
            // re-uploads this chunk when the transcription resumes from its
            // checkpoint.
            AppLog.transcription.atInfo.info("bgUpload: orphaned task \(task.taskIdentifier, privacy: .public) completed")
            return
        }
        if let error {
            let urlError = (error as? URLError) ?? URLError(.unknown)
            AppLog.transcription.atError.error("bgUpload: task=\(task.taskIdentifier, privacy: .public) failed: \(urlError.localizedDescription, privacy: .public) (code=\(urlError.code.rawValue, privacy: .public))")
            continuation.resume(throwing: AppError.networkError(urlError))
        } else if let response = task.response {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            AppLog.transcription.atInfo.info("bgUpload: task=\(task.taskIdentifier, privacy: .public) complete, HTTP \(status, privacy: .public), body=\(buffer.count, privacy: .public) bytes")
            continuation.resume(returning: (buffer, response))
        } else {
            AppLog.transcription.atError.error("bgUpload: task=\(task.taskIdentifier, privacy: .public) complete but no response")
            continuation.resume(throwing: AppError.networkError(URLError(.badServerResponse)))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = eventsCompletionHandler
        eventsCompletionHandler = nil
        lock.unlock()
        if let handler {
            DispatchQueue.main.async(execute: handler)
        }
    }
}

/// Bridges structured cancellation to the URLSession task: `cancel` may fire
/// on any thread before or after `start`, and a cancel that arrives first must
/// cancel the task the moment it's set.
private final class UploadTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionUploadTask?
    private var cancelled = false

    func start(_ task: URLSessionUploadTask) {
        lock.lock()
        self.task = task
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled {
            task.cancel()
        } else {
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
