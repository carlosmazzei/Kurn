//
//  WhisperBackgroundUploader.swift
//  Kurn
//
//  Retains the legacy background `URLSession` plumbing needed to drain tasks
//  created by earlier releases. New Whisper uploads use the origin-locked
//  foreground transport because iOS background sessions always follow redirects
//  without consulting `willPerformHTTPRedirection`. The relaunch hook still
//  re-attaches this delegate so pending legacy events can finish cleanly.
//

import Foundation

final class WhisperBackgroundUploader: NSObject, @unchecked Sendable {

    static let sessionIdentifier = "ai.kurn.whisper.upload"
    static let shared = WhisperBackgroundUploader()

    private let lock = NSLock()
    private var storedSession: URLSession?
    private let eventCompletions = BackgroundEventCompletionStore()

    private var session: URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let storedSession { return storedSession }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        storedSession = session
        return session
    }

    /// Relaunch hook: iOS calls the app delegate when transfers for this
    /// session finished while the app was dead. Touching `session` recreates
    /// it with the delegate attached so the pending events are delivered;
    /// the stored completion handlers then tell the system we're done.
    static func handleEvents(identifier: String, completionHandler: @escaping @Sendable () -> Void) {
        guard identifier == sessionIdentifier else {
            completionHandler()
            return
        }
        shared.eventCompletions.append(completionHandler)
        _ = shared.session
    }
}

extension WhisperBackgroundUploader: URLSessionDataDelegate {

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        dataTask.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let code = (error as? URLError)?.code.rawValue ?? URLError.unknown.rawValue
            AppLog.transcription.atInfo.info("bgUpload: legacy task=\(task.taskIdentifier, privacy: .public) finished code=\(code, privacy: .public)")
        } else {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            AppLog.transcription.atInfo.info("bgUpload: legacy task=\(task.taskIdentifier, privacy: .public) finished HTTP \(status, privacy: .public)")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        for handler in eventCompletions.drain() {
            DispatchQueue.main.async(execute: handler)
        }
    }
}

final class BackgroundEventCompletionStore: @unchecked Sendable {
    typealias Handler = @Sendable () -> Void

    private let lock = NSLock()
    private var handlers: [Handler] = []

    var count: Int {
        lock.withLock { handlers.count }
    }

    func append(_ handler: @escaping Handler) {
        lock.withLock { handlers.append(handler) }
    }

    func drain() -> [Handler] {
        lock.withLock {
            defer { handlers.removeAll() }
            return handlers
        }
    }
}
