import Foundation

#if canImport(BackgroundTasks)
import BackgroundTasks
import UIKit

/// An optional on-device window, never an automatic cloud launch. Foreground
/// resume is the reliable path; an expired window leaves durable work queued.
enum KnowledgeBackgroundScheduler {
    static let taskIdentifier = "ai.kurn.knowledge.processing"

    static func register(queue: @escaping @MainActor @Sendable () -> KnowledgeJobQueue?) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            let completion = KnowledgeBackgroundCompletion(task)
            let work = Task { @MainActor in
                guard UIApplication.shared.isProtectedDataAvailable, let queue = queue() else {
                    completion.finish(false)
                    return
                }
                guard !Task.isCancelled else { completion.finish(false); return }
                await queue.beginBackgroundOpportunity()
                queue.endBackgroundOpportunity()
                if !Task.isCancelled { await scheduleIfWorkRemains(queue: queue) }
                completion.finish(!Task.isCancelled)
            }
            task.expirationHandler = {
                work.cancel()
                Task { @MainActor in queue()?.endBackgroundOpportunity() }
                completion.finish(false)
            }
        }
    }

    @MainActor
    static func scheduleIfWorkRemains(queue: KnowledgeJobQueue) async {
        guard await queue.hasLocalWork() else { return }
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        do { try BGTaskScheduler.shared.submit(request) }
        catch { AppLog.transcription.atError.error("knowledge: background request failed code=\(error.publicLogCode, privacy: .public)") }
    }
}

/// BGTask completion is thread-safe; exactly once even when expiry races the
/// foreground-isolated runner. No model or queue is sent across this lock.
private final class KnowledgeBackgroundCompletion: @unchecked Sendable {
    private let task: BGTask
    private let lock = NSLock()
    private var completed = false
    init(_ task: BGTask) { self.task = task }
    func finish(_ success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        task.setTaskCompleted(success: success)
    }
}
#endif
