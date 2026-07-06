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
//  TODO: delete this file, `Meeting.summary`, and `Summary.meeting` once this
//  build has run at least once on every local store — this is a single-user,
//  pre-release app, so there's no installed base that needs the bridge kept
//  around long-term.
//

import Foundation
import SwiftData

enum SummaryMigration {

    /// TODO: remove alongside `Meeting.summary`/`Summary.meeting` once every
    /// local store has run this at least once.
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
