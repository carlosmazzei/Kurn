//
//  RecordingOperationJournal.swift
//  Kurn
//
//  A small durable write-ahead journal for the mutations that touch SwiftData
//  and the filesystem together: deleting a meeting/recording (trash, model
//  commit, purge) and replacing a recording's bytes in place (compaction's
//  swap). Each operation writes its intent — a stable operation ID, its kind,
//  and the file names it owns — to disk *before* touching anything, advances
//  a durable state marker at each boundary, and removes the record only once
//  the operation is fully done.
//
//  On launch, `replay(context:)` resolves whatever a process death left
//  behind from the record's own state instead of inferring intent from
//  whichever side happened to change: an operation that never reached its
//  model commit rolls back (files restored), one that committed replays
//  forward (purge). The single genuinely in-doubt window — a death between
//  the model save and the `.committed` marker — is resolved by consulting the
//  authoritative store for exactly the file names the record itself lists,
//  the same way a two-phase participant resolves an in-doubt transaction by
//  asking its coordinator.
//
//  `RecordingTrash.sweep` still runs afterwards as the heuristic fallback for
//  trash folders that predate the journal (or whose record could not be
//  written — the journal degrades to journal-less trash-then-purge rather
//  than blocking an explicit user action).
//

import Foundation
import KurnCore
import SwiftData

enum RecordingOperationJournal {
    enum Kind: String, Codable {
        case delete
        case replace
    }

    enum State: String, Codable {
        /// Intent recorded; files may be partially moved to trash.
        case intent
        /// Every file move to trash finished; the model commit may or may
        /// not have happened.
        case trashed
        /// The model mutation is durably committed; only the purge remains.
        case committed
    }

    struct Record: Codable {
        let id: UUID
        let kind: Kind
        let fileNames: [String]
        let startedAt: Date
        var state: State
    }

    static var journalDirectoryURL: URL {
        AudioFileStore.recordingsDirectoryURL
            .appendingPathComponent(RecordingProtection.journalDirectoryName, isDirectory: true)
    }

    /// Subdirectory of the journal holding records that could not be decoded.
    /// They are moved here rather than deleted so a corrupt record is
    /// preserved for diagnosis, and rather than left in place so replay does
    /// not rediscover (and re-report) them on every launch.
    static let unreadableDirectoryName = "Unreadable"

    static var unreadableDirectoryURL: URL {
        journalDirectoryURL.appendingPathComponent(unreadableDirectoryName, isDirectory: true)
    }

    static let reliabilityOperation = "recording_journal"

    // MARK: - Journaled delete

    /// Runs a delete as journaled trash → model commit → purge. `commit` is
    /// the model mutation plus save, returning its failure if any; a failure
    /// (or a thrown error anywhere) restores the trashed files. Returns the
    /// commit's failure so the caller can surface it.
    @discardableResult
    @MainActor
    static func performDelete(
        fileNames: [String],
        fileManager: FileManager = .default,
        commit: () -> AppError?
    ) -> AppError? {
        let operationID = UUID()
        var journaled = write(Record(
            id: operationID,
            kind: .delete,
            fileNames: fileNames,
            startedAt: Date(),
            state: .intent
        ), fileManager: fileManager)

        RecordingTrash.trash(fileNames: fileNames, operationID: operationID)
        if journaled { journaled = advance(operationID, to: .trashed, fileManager: fileManager) }

        if let failure = commit() {
            RecordingTrash.restore(operationID: operationID)
            removeRecord(operationID, fileManager: fileManager)
            return failure
        }

        if journaled { journaled = advance(operationID, to: .committed, fileManager: fileManager) }
        RecordingTrash.purge(operationID: operationID)
        removeRecord(operationID, fileManager: fileManager)
        return nil
    }

    // MARK: - Journaled replace

    /// Record the intent to atomically replace `fileName`'s bytes in place
    /// (compaction's swap). Returns the operation ID to close with
    /// `finishReplace`, or nil when the journal itself is unavailable — the
    /// swap is a single atomic `replaceItemAt`, so proceeding unjournaled
    /// loses only the replayed protection re-stamp.
    static func beginReplace(fileName: String) -> UUID? {
        let operationID = UUID()
        guard write(Record(
            id: operationID,
            kind: .replace,
            fileNames: [fileName],
            startedAt: Date(),
            state: .intent
        )) else { return nil }
        return operationID
    }

    static func finishReplace(_ operationID: UUID?) {
        guard let operationID else { return }
        removeRecord(operationID)
    }

    // MARK: - Replay

    /// Resolve every journal record a process death left behind. Runs before
    /// `RecordingTrash.sweep` so journaled operations are resolved from their
    /// recorded state; the sweep only ever sees pre-journal leftovers.
    /// Idempotent: every step is a move/remove that tolerates already-done.
    @MainActor
    static func replay(context: ModelContext) {
        let records = pendingRecords()
        guard !records.isEmpty else { return }

        for record in records {
            switch record.kind {
            case .delete:
                replayDelete(record, context: context)
            case .replace:
                // `replaceItemAt` is atomic, so the file holds either the old
                // or the new bytes — both valid. The only thing a death can
                // have skipped is the post-swap protection re-stamp.
                for fileName in record.fileNames {
                    RecordingProtection.apply(to: AudioFileStore.resolveURL(fileName: fileName))
                }
            }
            removeRecord(record.id)
            AppLog.recorder.atNotice.notice(
                "journal: replayed \(record.kind.rawValue, privacy: .public) op in state \(record.state.rawValue, privacy: .public)"
            )
            ReliabilityLog.record(ReliabilityEvent(
                operationID: reliabilityID(record.id),
                operation: reliabilityOperation,
                stage: "replay",
                outcome: .succeeded,
                code: "\(record.kind.rawValue)_\(record.state.rawValue)"
            ))
        }
    }

    @MainActor
    private static func replayDelete(_ record: Record, context: ModelContext) {
        switch record.state {
        case .intent:
            // The model commit provably never ran: roll back whatever subset
            // of the moves happened.
            RecordingTrash.restore(operationID: record.id)
        case .trashed:
            // In-doubt: the death fell between the model save and the
            // `.committed` marker. The store is the authority — scoped to the
            // file names this record owns, not a global inference.
            if anyRowExists(for: record.fileNames, context: context) {
                RecordingTrash.restore(operationID: record.id)
            } else {
                RecordingTrash.purge(operationID: record.id)
            }
        case .committed:
            RecordingTrash.purge(operationID: record.id)
        }
    }

    @MainActor
    private static func anyRowExists(for fileNames: [String], context: ModelContext) -> Bool {
        guard let recordings = try? context.fetch(FetchDescriptor<Recording>()) else {
            // If the store cannot be read, restoring is the safe direction:
            // a restored file is at worst an orphan the recovery sweep can
            // re-adopt, a purged one is gone.
            return true
        }
        let known = Set(recordings.map(\.fileName))
        return fileNames.contains(where: known.contains)
    }

    // MARK: - Record storage

    /// Every readable record, oldest first. A record that cannot be read or
    /// decoded is set aside under `unreadableDirectoryURL` and reported,
    /// never silently dropped: its trash folder (if any) is still reconciled
    /// by `RecordingTrash.sweep`, which consults the store rather than the
    /// record, so setting the record aside loses no audio.
    static func pendingRecords(fileManager: FileManager = .default) -> [Record] {
        guard let items = try? fileManager.contentsOfDirectory(
            at: journalDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let decoder = JSONDecoder()
        var records: [Record] = []
        for url in items where url.pathExtension == "json" {
            do {
                records.append(try decoder.decode(Record.self, from: Data(contentsOf: url)))
            } catch {
                setAsideUnreadable(url, fileManager: fileManager)
            }
        }
        return records.sorted { $0.startedAt < $1.startedAt }
    }

    private static func setAsideUnreadable(_ url: URL, fileManager: FileManager) {
        let name = url.lastPathComponent
        do {
            let directory = try RecordingProtection.ensureProtectedDirectory(
                named: "\(RecordingProtection.journalDirectoryName)/\(unreadableDirectoryName)",
                in: AudioFileStore.recordingsDirectoryURL,
                fileManager: fileManager
            )
            let destination = directory.appendingPathComponent(name)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: url, to: destination)
            reportFailure(operationID: operationIDFromFileName(name), stage: "replay", code: "journal_record_unreadable")
        } catch {
            AppLog.recorder.atError.error(
                "journal: unreadable record could not be set aside code=\(error.publicLogCode, privacy: .public)"
            )
            reportFailure(operationID: operationIDFromFileName(name), stage: "replay", code: "journal_record_stuck")
        }
    }

    /// Durably write `record`, creating the protected journal directory as
    /// needed. Returns false when the record could not be made durable, in
    /// which case the operation proceeds unjournaled (the trash sweep remains
    /// as the fallback) rather than blocking an explicit user action.
    @discardableResult
    private static func write(_ record: Record, fileManager: FileManager = .default) -> Bool {
        do {
            let parent = try AudioFileStore.ensureRecordingsDirectory(fileManager: fileManager)
            let directory = try RecordingProtection.ensureProtectedDirectory(
                named: RecordingProtection.journalDirectoryName,
                in: parent,
                fileManager: fileManager
            )
            let data = try JSONEncoder().encode(record)
            try data.write(to: recordURL(record.id, in: directory), options: .atomic)
            return true
        } catch {
            AppLog.recorder.atError.error(
                "journal: could not record \(record.kind.rawValue, privacy: .public) intent code=\(error.publicLogCode, privacy: .public)"
            )
            reportFailure(operationID: record.id, stage: record.state.rawValue, code: "journal_write_failed")
            return false
        }
    }

    /// Durably move `operationID`'s record to `state`. Returns false — and
    /// withdraws the record — when the marker could not be written: a record
    /// frozen at a stale state would make replay roll back a commit that did
    /// happen, whereas with no record `RecordingTrash.sweep` resolves the
    /// trash folder from the store. The operation continues unjournaled.
    private static func advance(_ operationID: UUID, to state: State, fileManager: FileManager) -> Bool {
        guard var record = read(operationID) else {
            reportFailure(operationID: operationID, stage: state.rawValue, code: "journal_record_missing")
            removeRecord(operationID, fileManager: fileManager)
            return false
        }
        record.state = state
        guard write(record, fileManager: fileManager) else {
            reportFailure(operationID: operationID, stage: state.rawValue, code: "journal_advance_failed")
            removeRecord(operationID, fileManager: fileManager)
            return false
        }
        return true
    }

    private static func read(_ operationID: UUID) -> Record? {
        guard let data = try? Data(contentsOf: recordURL(operationID, in: journalDirectoryURL)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    static func removeRecord(_ operationID: UUID, fileManager: FileManager = .default) {
        let url = recordURL(operationID, in: journalDirectoryURL)
        do {
            try fileManager.removeItem(at: url)
        } catch {
            guard fileManager.fileExists(atPath: url.path) else { return }
            reportFailure(operationID: operationID, stage: "remove", code: "journal_record_stuck")
        }
    }

    private static func reportFailure(operationID: UUID, stage: String, code: String) {
        AppLog.recorder.atError.error(
            "journal: \(code, privacy: .public) stage=\(stage, privacy: .public)"
        )
        ReliabilityLog.record(ReliabilityEvent(
            operationID: reliabilityID(operationID),
            operation: reliabilityOperation,
            stage: stage,
            outcome: .failed,
            code: code
        ))
    }

    private static func reliabilityID(_ operationID: UUID) -> OperationID {
        OperationID(String(operationID.uuidString.prefix(8)))
    }

    private static func operationIDFromFileName(_ name: String) -> UUID {
        UUID(uuidString: (name as NSString).deletingPathExtension) ?? UUID()
    }

    private static func recordURL(_ operationID: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(operationID.uuidString).json")
    }
}
