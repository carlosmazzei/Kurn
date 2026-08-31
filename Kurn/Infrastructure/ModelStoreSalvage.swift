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
        // Screen out a file that was never SQLite to begin with, so CoreData
        // is only ever asked to open something structurally plausible and a
        // junk file is classified here rather than by interpreting whatever
        // `NSPersistentStoreCoordinator` happens to throw. A genuinely
        // SwiftData-incompatible store (a migration mismatch) is still valid
        // SQLite, passes this check untouched, and is handled below.
        //
        // This is cheap insurance, not the fix for the `ModelContext.reset`
        // crash an earlier revision of this comment blamed on it — that was
        // a misdiagnosis; see `recoverReadOnly` for the actual cause.
        guard isLikelySQLiteDatabase(at: copyURL) else {
            return (.failed(.corruptOrUnknown), nil)
        }
        if let recovered = try? recoverReadOnly(
            at: copyURL, schema: KurnModelGraph.schema, migrationPlan: KurnModelGraph.migrationPlan
        ) {
            return recovered
        }
        do {
            return try recoverReadOnly(
                at: copyURL, schema: Schema(KurnModelGraph.currentModels), migrationPlan: nil
            )
        } catch {
            return (.failed(ModelStoreOpenFailureClassifier.classify(error)), nil)
        }
    }

    /// Opens the copy, reads everything needed out of it, and returns only
    /// **value types**.
    ///
    /// The export has to happen in here, not in the caller. A fetched
    /// `Meeting` is owned by `container.mainContext`, and SwiftData resets
    /// that context when the container deallocates — which, for a container
    /// held in a local like this one, is the moment this function returns.
    /// Handing `[Meeting]` back to the caller therefore handed back objects
    /// that were already destroyed, and the first property read on one
    /// (`exportMarkdown` reaching for `title`/`notes`/`summaries`) trapped
    /// the whole process:
    ///
    ///   SwiftData/BackingData.swift:844: Fatal error: This model instance
    ///   was destroyed by calling ModelContext.reset and is no longer usable.
    ///
    /// That crash landed on the recovery screen — the one place in the app
    /// that exists precisely because something already went wrong — so the
    /// rule this encodes is worth keeping: never let a `@Model` instance
    /// outlive the `ModelContainer` it was fetched from.
    private static func recoverReadOnly(
        at url: URL,
        schema: Schema,
        migrationPlan: (any SchemaMigrationPlan.Type)?
    ) throws -> (result: ModelStoreSalvageResult, exportMarkdown: String?) {
        let configuration = ModelConfiguration(schema: schema, url: url, allowsSave: false)
        let container: ModelContainer
        if let migrationPlan {
            container = try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: [configuration])
        } else {
            container = try ModelContainer(for: schema, configurations: [configuration])
        }
        // `withExtendedLifetime` rather than relying on the closure's own
        // capture: ARC is free to release `container` after its last use
        // (the fetch), which would destroy the very objects the export is
        // about to read.
        return try withExtendedLifetime(container) { () throws -> (result: ModelStoreSalvageResult, exportMarkdown: String?) in
            let meetings = try container.mainContext.fetch(FetchDescriptor<Meeting>())
            let markdown = Self.exportMarkdown(for: meetings)
            return (.recovered(meetingCount: meetings.count), markdown)
        }
    }

    /// SQLite database files begin with the fixed 16-byte magic header
    /// `"SQLite format 3\0"`. Cheap and exact — far simpler than trying to
    /// classify whatever `ModelContainer` throws (or doesn't) after the
    /// fact, and it runs before any CoreData API touches the file at all.
    private static func isLikelySQLiteDatabase(at url: URL) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16), header.count == 16 else { return false }
        return header == Data("SQLite format 3\0".utf8)
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
