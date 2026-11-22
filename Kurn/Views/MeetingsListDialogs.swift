//
//  MeetingsListDialogs.swift
//  Kurn
//
//  The meetings list's delete-meeting `kurnDialog`, parameterized like
//  `recordingDeleteDialog` — `body`'s modifier chain is long enough that
//  the inline dialog block tips the type-checker over CI's slower compiler.
//  Split into its own file for the same reason `MeetingsListToolbar.swift`
//  exists (SwiftLint's file-length limit).
//

import KurnCore
import SwiftData
import SwiftUI

extension View {
    func meetingDeleteDialog(
        pending: Binding<Meeting?>,
        saveError: Binding<AppError?>,
        modelContext: ModelContext
    ) -> some View {
        kurnDialog(
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            iconSystemName: "trash.fill",
            iconTint: Theme.destructive,
            title: String(
                format: NSLocalizedString("meetings.delete.confirm_titled", comment: "Delete confirmation"),
                pending.wrappedValue?.title ?? ""
            ),
            message: NSLocalizedString("meetings.delete.message", comment: "What a meeting delete erases"),
            primaryTitle: NSLocalizedString("common.delete", comment: "Delete"),
            primaryRole: .destructive,
            primaryAction: {
                guard let meeting = pending.wrappedValue else { return }
                do throws(AppError) {
                    try MeetingLibrary(context: modelContext).deleteMeeting(meeting)
                } catch {
                    saveError.wrappedValue = error
                }
                pending.wrappedValue = nil
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel"),
            secondaryAction: {
                pending.wrappedValue = nil
            }
        )
    }
}
