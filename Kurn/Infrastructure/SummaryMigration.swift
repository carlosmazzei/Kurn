//
//  SummaryMigration.swift
//  Kurn
//
//  One-shot upgrade sweep: moves any pre-existing single `Meeting.summary`
//  (the old one-to-one relationship, superseded by `Meeting.summaries`) into
//  the new one-to-many relationship. Runs once at launch; idempotent, since a
//  meeting whose legacy `summary` is already nil (fresh install, or already
//  migrated) is a no-op.
//

import Foundation
import SwiftData

enum SummaryMigration {

    @MainActor
    static func migrateLegacySummaries(modelContainer: ModelContainer) {
        let context = modelContainer.mainContext
        guard let meetings = try? context.fetch(FetchDescriptor<Meeting>()) else { return }
        var migrated = 0
        for meeting in meetings {
            guard let legacy = meeting.summary else { continue }
            legacy.owningMeeting = meeting
            meeting.summary = nil
            migrated += 1
        }
        guard migrated > 0 else { return }
        do {
            try context.save()
            AppLog.persistence.atNotice.notice("migration: moved \(migrated, privacy: .public) legacy summary(ies) into meeting.summaries")
        } catch {
            AppLog.persistence.atError.error("migration: legacy summary sweep save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
