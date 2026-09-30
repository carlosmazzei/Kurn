//
//  SettingsSections.swift
//  Kurn
//
//  Helpers for the Settings hub: the destructive reset. Which providers have a
//  key, and the invariants that keep the selected providers valid, live in
//  `AppSettings+ProviderSelection.swift`.
//
//  The section bodies these used to sit next to now live one per screen in
//  `Views/Settings/`.
//

import SwiftData
import SwiftUI

extension SettingsView {

    /// Stops whatever could still write meeting content (a running
    /// transcription, read-aloud) and hands the erase to `LibraryEraser`,
    /// which also removes the recovery copies a plain model delete leaves.
    func deleteAllData() {
        ReadAloudController.shared.stop()
        transcription?.cancelAllTranscriptions()
        Task {
            await transcription?.awaitActiveTranscriptions()
            let residual: Int
            do {
                residual = try LibraryEraser.eraseAll(context: modelContext)
            } catch {
                AppLog.persistence.atError.error(
                    "Failed to delete all data code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
                )
                dataError = .persistenceFailed(error.localizedDescription)
                return
            }
            if residual > 0 {
                dataError = .audioError(String(
                    format: NSLocalizedString("settings.delete_all.residual", comment: "Files left after delete all"),
                    residual
                ))
            }
        }
    }
}
