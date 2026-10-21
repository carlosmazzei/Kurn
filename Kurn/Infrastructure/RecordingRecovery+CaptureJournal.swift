//
//  RecordingRecovery+CaptureJournal.swift
//  Kurn
//
//  The automatic half of `CaptureJournalRepair`: after the synchronous
//  activation sweeps have reconciled a killed capture to `.recoveryNeeded`,
//  rebuild its undecodable `.m4a` from the journal so the recording shows its
//  real duration and plays, instead of waiting for the user to find it.
//

import Foundation
import SwiftData

extension RecordingRecovery {
    /// Only rows already reconciled to `.recoveryNeeded` are candidates. That
    /// is what keeps the file a live session is still writing — its row is
    /// `.preparing`/`.recording` — out of reach, and why a journal with no row
    /// at all is left on disk rather than rebuilt: there is no meeting to give
    /// it back to, and the orphan sweep would only quarantine it again.
    ///
    /// A rebuilt recording stays `.recoveryNeeded`, now as
    /// `.interruptedDuringCapture` — the same state a killed capture whose
    /// file happened to be readable reaches — so the user still confirms a
    /// recording that ends where the process died.
    ///
    /// Two overlapping runs (two quick activations) are harmless: a rebuild
    /// never replaces a readable file, and one whose journal the other run's
    /// finalizer already discarded just fails and leaves things as they are.
    @MainActor
    static func repairFromCaptureJournals(
        modelContainer: ModelContainer,
        export: CaptureJournalRepair.Exporter = CaptureJournalRepair.exportToM4A
    ) async {
        let journaled = Set(CaptureJournal.recordingFileNamesWithJournal())
        guard !journaled.isEmpty else { return }

        let context = modelContainer.mainContext
        guard let recordings = try? context.fetch(FetchDescriptor<Recording>()) else { return }
        let candidates = recordings.filter {
            $0.captureState == .recoveryNeeded && journaled.contains($0.fileName)
        }
        var changed = false
        for recording in candidates {
            let fileName = recording.fileName
            guard await CaptureJournalRepair.rebuild(fileName: fileName, export: export) == .rebuilt,
                  !recording.isDeleted,
                  let metadata = try? RecordingFileFinalizer().finalize(fileName: fileName) else { continue }
            recording.duration = metadata.duration
            recording.fileSize = metadata.fileSize
            recording.captureRecoveryReason = .interruptedDuringCapture
            CaptureReliability.finalized(fileName: fileName, reason: .interruptedDuringCapture, stage: "journal_rebuild")
            changed = true
        }
        guard changed else { return }
        context.saveOrError()
    }
}
