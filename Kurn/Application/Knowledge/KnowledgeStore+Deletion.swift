import Foundation
import KurnCore
import SwiftData

extension KnowledgeStore {
    /// Purges the oldest deletion tombstone in one transaction. `beforeSave` is
    /// the fault-injection seam proving that a failed save leaves the tombstone
    /// and every canonical row in place for the next attempt.
    func purgeNextDeletion(beforeSave: @Sendable () throws -> Void = {}) throws -> KnowledgeDeletionReceipt? {
        try KnowledgeDeletionRows.purgeNext(container: modelContainer, beforeSave: beforeSave)
    }

    func pendingDeletionCount() throws -> Int {
        let context = ModelContext(modelContainer)
        return try KnowledgeDeletionRows.pendingCount(in: context)
    }

    /// Durably records "delete the whole Knowledge corpus" before anything is
    /// removed, so a process death mid-way resumes the purge at the next launch.
    func requestCorpusDeletion() throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        context.insert(KnowledgeDeletionRows.tombstone(.corpus, meetingID: nil))
        try context.save()
    }
}
