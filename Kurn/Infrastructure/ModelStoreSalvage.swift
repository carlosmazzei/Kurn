//
//  ModelStoreSalvage.swift
//  Kurn
//
//  H2 PR 4's "attempt salvage into a separate container": when the live
//  store won't open, copy it aside and try opening the copy — read-only,
//  never touching the live files — so a failure that would still have opened
//  under slightly different conditions (a transient lock, a migration-plan
//  bookkeeping issue distinct from the underlying data) can still hand the
//  user their meetings back, exported as Markdown rather than restored in
//  place. Whatever made the live open fail would make restoring the same
//  bytes fail again too, so salvage is a data-recovery path, not a repair.
//
//  This is deliberately best-effort, not a guarantee: a genuinely corrupt
//  SQLite file or a real, un-migratable schema mismatch will fail here
//  exactly as it failed live. Two strategies are tried before giving up —
//  the production schema/migration plan (catches transient/environmental
//  causes), then a bare unversioned schema with no migration plan (catches
//  the case where the migration-plan machinery itself, not the underlying
//  data, was the problem).
//

import Foundation
import SwiftData

enum ModelStoreSalvageResult: Sendable, Equatable {
    /// No live store files exist — nothing to attempt.
    case unavailable
    case recovered(meetingCount: Int)
    case failed(ModelStoreOpenFailureReason)
}

@MainActor
enum ModelStoreSalvage {
    /// Runs the salvage attempt and, on success, returns both the outcome
    /// and the exported Markdown so the caller can offer it for sharing.
    /// `exportMarkdown` is `nil` unless `result` is `.recovered`.
    static func attempt(
        appSupportDirectory: URL,
        fileManager: FileManager = .default
    ) -> (result: ModelStoreSalvageResult, exportMarkdown: String?) {
        let liveFiles = ([""] + ModelStoreProtection.sidecarSuffixes)
            .map { appSupportDirectory.appendingPathComponent(ModelStoreProtection.baseName + $0) }
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard !liveFiles.isEmpty else { return (.unavailable, nil) }

        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("kurn_salvage_\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        do {
            try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            for source in liveFiles {
                try fileManager.copyItem(at: source, to: workDirectory.appendingPathComponent(source.lastPathComponent))
            }
        } catch {
            return (.failed(ModelStoreOpenFailureClassifier.classify(error)), nil)
        }

        let copyURL = workDirectory.appendingPathComponent(ModelStoreProtection.baseName)
        if let meetings = try? openReadOnly(
            at: copyURL, schema: KurnModelGraph.schema, migrationPlan: KurnModelGraph.migrationPlan
        ) {
            return (.recovered(meetingCount: meetings.count), exportMarkdown(for: meetings))
        }
        do {
            let meetings = try openReadOnly(
                at: copyURL, schema: Schema(KurnModelGraph.currentModels), migrationPlan: nil
            )
            return (.recovered(meetingCount: meetings.count), exportMarkdown(for: meetings))
        } catch {
            return (.failed(ModelStoreOpenFailureClassifier.classify(error)), nil)
        }
    }

    private static func openReadOnly(
        at url: URL,
        schema: Schema,
        migrationPlan: (any SchemaMigrationPlan.Type)?
    ) throws -> [Meeting] {
        let configuration = ModelConfiguration(schema: schema, url: url, allowsSave: false)
        let container: ModelContainer
        if let migrationPlan {
            container = try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: [configuration])
        } else {
            container = try ModelContainer(for: schema, configurations: [configuration])
        }
        return try container.mainContext.fetch(FetchDescriptor<Meeting>())
    }

    private static func exportMarkdown(for meetings: [Meeting]) -> String {
        var out = "# Kurn salvage export\n\n\(meetings.count) meeting(s) recovered.\n\n"
        for meeting in meetings.sorted(by: { $0.createdAt < $1.createdAt }) {
            out += "---\n\n"
            out += MeetingExport.markdown(for: meeting, summary: meeting.latestSummary)
            out += "\n"
        }
        return out
    }
}
