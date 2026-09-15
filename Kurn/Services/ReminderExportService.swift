//
//  ReminderExportService.swift
//  Kurn
//
//  Writes selected summary bullets to the Reminders app as EKReminders. Local
//  write only — the app keeps no relationship to the reminders it creates and
//  never reads Reminders content back.
//

import EventKit
import Foundation
import KurnCore

struct ReminderExportService: Sendable {
    private let eventStore = EKEventStore()

    /// Current authorization state for creating reminders, without prompting.
    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    /// Prompts the user if needed. Returns whether the app can create
    /// reminders once the request completes.
    func requestAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToReminders()
    }

    /// Creates one reminder per non-empty item in the user's default
    /// reminders list, with a note referencing the source meeting. All
    /// reminders are staged then committed together, so a mid-batch save
    /// failure doesn't leave a half-written batch behind.
    @discardableResult
    func createReminders(
        for items: [String],
        meetingTitle: String,
        meetingDate: Date
    ) throws -> Int {
        guard let calendar = eventStore.defaultCalendarForNewReminders() else {
            throw AppError.reminderCreationFailed("no_default_list")
        }
        let note = String(
            format: NSLocalizedString("reminders.export.note", comment: "Reminder note referencing the source meeting"),
            meetingTitle,
            meetingDate.meetingDisplay
        )
        let trimmedItems = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for text in trimmedItems {
            let reminder = EKReminder(eventStore: eventStore)
            reminder.title = text
            reminder.notes = note
            reminder.calendar = calendar
            do {
                try eventStore.save(reminder, commit: false)
            } catch {
                throw AppError.reminderCreationFailed(error.localizedDescription)
            }
        }
        do {
            try eventStore.commit()
        } catch {
            throw AppError.reminderCreationFailed(error.localizedDescription)
        }
        return trimmedItems.count
    }
}
