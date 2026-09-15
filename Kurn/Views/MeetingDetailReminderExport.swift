//
//  MeetingDetailReminderExport.swift
//  Kurn
//
//  Reminders-export support for `MeetingDetailView`. Isolated here for the
//  same reason as `MeetingDetailAutoTagging`: keeps the main detail view
//  focused on layout and navigation.
//

import KurnCore
import SwiftUI

extension MeetingDetailView {

    /// Checks (and requests, if undetermined) Reminders access for the given
    /// section, then opens the review sheet once access is available. Never
    /// creates a reminder directly — review is mandatory, the same rule
    /// `suggestTags()`/`AutoTagConfirmView` already enforce for LLM output.
    func exportItemsToReminders(_ section: SummarySection) {
        guard !isRequestingRemindersAccess else { return }
        let service = ReminderExportService()
        switch service.authorizationStatus {
        case .fullAccess:
            remindersSection = section
        case .notDetermined:
            isRequestingRemindersAccess = true
            Task { @MainActor in
                defer { isRequestingRemindersAccess = false }
                do {
                    if try await service.requestAccess() {
                        remindersSection = section
                    } else {
                        remindersError = .remindersAccessDenied
                    }
                } catch {
                    AppLog.ui.atError.error("Reminders access request failed")
                    remindersError = .remindersAccessDenied
                }
            }
        default:
            remindersError = .remindersAccessDenied
        }
    }

    /// Creates the reviewed selection as reminders and surfaces any failure.
    func applyReminderExport(_ items: [String]) {
        do {
            try ReminderExportService().createReminders(
                for: items,
                meetingTitle: meeting.title,
                meetingDate: meeting.createdAt
            )
        } catch {
            let code = (error as? AppError)?.logCode ?? "unexpected"
            AppLog.ui.atError.error("Reminder export failed code=\(code, privacy: .public)")
            remindersError = error as? AppError ?? .reminderCreationFailed(error.localizedDescription)
        }
        remindersSection = nil
    }
}
