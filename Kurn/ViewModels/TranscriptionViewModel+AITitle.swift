//
//  TranscriptionViewModel+AITitle.swift
//  Kurn
//
//  AI title generation, split out of TranscriptionViewModel.swift to keep that
//  file under SwiftLint's file-length limit, the same reason
//  TranscriptionViewModel+Summary.swift and
//  TranscriptionViewModel+ResumeBudget.swift are separate files.
//

import Foundation
import KurnCore

extension TranscriptionViewModel {

    // MARK: - AI title

    /// Generate and persist a short AI-derived meeting title after transcription.
    /// Best-effort: errors are logged and swallowed (`aiTitleCoordinator`
    /// only sets `lastError` for an `.explicit` trigger) so a failed
    /// automatic title never blocks or surfaces as a user-facing error.
    func generateAITitle(for meeting: Meeting?, settings: AppSettings) async {
        guard let meeting,
              let title = await aiTitleCoordinator.generateTitle(
                for: meeting,
                settings: settings
              ),
              !Task.isCancelled else { return }
        meeting.aiTitle = title
        persist()
        AppLog.transcription.atNotice.notice("VM: AI title id=\(meeting.id, privacy: .public) \"\(title, privacy: .private)\"")
    }

    /// Whether `meeting`'s AI title is currently being (re)generated, so the
    /// overflow menu can show progress the same way `WikiCoordinator
    /// .generatingMeetingIDs` does for the wiki.
    func isGeneratingTitle(for meeting: Meeting) -> Bool {
        aiTitleCoordinator.generatingMeetingIDs.contains(meeting.id)
    }

    /// Build (or rebuild) this meeting's AI title from its own overflow
    /// menu — explicit and forced, the title analogue of
    /// `WikiCoordinator.generate`'s per-meeting action. Unlike the automatic
    /// post-transcription pass above, this always regenerates even when a
    /// title already exists, and a failure surfaces through `error` (this
    /// property's original, if previously unwired, purpose) instead of
    /// being swallowed.
    func regenerateTitle(for meeting: Meeting, settings: AppSettings) {
        Task { [weak self] in
            guard let self else { return }
            let title = await self.aiTitleCoordinator.generateTitle(
                for: meeting, settings: settings, trigger: .explicit, force: true
            )
            guard !Task.isCancelled else { return }
            if let title {
                meeting.aiTitle = title
                self.persist()
                AppLog.transcription.atNotice.notice("VM: AI title regenerated id=\(meeting.id, privacy: .public)")
            } else if let failure = self.aiTitleCoordinator.lastError {
                self.error = failure
                self.aiTitleCoordinator.lastError = nil
            }
        }
    }
}
