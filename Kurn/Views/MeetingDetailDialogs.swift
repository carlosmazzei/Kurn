//
//  MeetingDetailDialogs.swift
//  Kurn
//
//  The confirmation dialogs of `MeetingDetailView`'s overflow menu and row
//  actions, parameterized like `recordingDeleteDialog`. Kept out of the
//  view's `body` — inside the long modifier chain the inline `kurnDialog`
//  blocks timed the type-checker out on CI's slower compiler.
//

import KurnCore
import SwiftData
import SwiftUI

extension MeetingDetailView {
    /// Deletes the meeting and pops the detail — the dialog's primary action,
    /// named so the modifier chain stays simple for the type-checker.
    func deleteMeetingAndDismiss() {
        do throws(AppError) {
            try MeetingLibrary(context: modelContext).deleteMeeting(meeting)
            dismiss()
        } catch {
            actionError = error
        }
    }
}

extension View {
    func detailRetranscribeDialog(
        pending: Binding<Recording?>,
        onConfirm: @escaping (Recording) -> Void
    ) -> some View {
        kurnDialog(
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            iconSystemName: "arrow.clockwise.circle.fill",
            iconTint: Theme.destructive,
            title: NSLocalizedString("detail.retranscribe.confirm.title", comment: "Re-transcribe confirmation"),
            message: NSLocalizedString("detail.retranscribe.confirm.message", comment: "Re-transcribe message"),
            primaryTitle: NSLocalizedString("detail.retranscribe", comment: "Re-transcribe"),
            primaryRole: .destructive,
            primaryAction: {
                guard let recording = pending.wrappedValue else { return }
                onConfirm(recording)
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
    }

    func detailDeleteSummaryDialog(
        pending: Binding<Summary?>,
        onConfirm: @escaping (Summary) -> Void
    ) -> some View {
        kurnDialog(
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            iconSystemName: "trash.circle.fill",
            iconTint: Theme.warning,
            title: String(
                format: NSLocalizedString("detail.summary.delete_confirm.title_named", comment: "Delete summary confirmation"),
                pending.wrappedValue?.templateName?.isEmpty == false
                    ? pending.wrappedValue!.templateName!
                    : NSLocalizedString("detail.summary.untitled", comment: "Summary")
            ),
            message: NSLocalizedString("detail.summary.delete_confirm.message", comment: "Delete summary message"),
            primaryTitle: NSLocalizedString("common.delete", comment: "Delete"),
            primaryRole: .destructive,
            primaryAction: {
                guard let summary = pending.wrappedValue else { return }
                onConfirm(summary)
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
    }

    func detailDeleteMeetingDialog(
        isPresented: Binding<Bool>,
        meetingTitle: String,
        onConfirm: @escaping () -> Void
    ) -> some View {
        kurnDialog(
            isPresented: isPresented,
            iconSystemName: "trash.circle.fill",
            iconTint: Theme.destructive,
            title: String(format: NSLocalizedString("meetings.delete.confirm_titled", comment: "Delete meeting confirmation"), meetingTitle),
            message: NSLocalizedString("meetings.delete.message", comment: "Delete meeting message"),
            primaryTitle: NSLocalizedString("common.delete", comment: "Delete"),
            primaryRole: .destructive,
            primaryAction: onConfirm,
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
    }

    func detailRetranscribeAllDialog(
        isPresented: Binding<Bool>,
        onConfirm: @escaping () -> Void
    ) -> some View {
        kurnDialog(
            isPresented: isPresented,
            iconSystemName: "arrow.triangle.2.circlepath.circle.fill",
            iconTint: Theme.destructive,
            title: NSLocalizedString("detail.retranscribe_all.confirm.title", comment: "Re-transcribe all confirmation"),
            message: NSLocalizedString("detail.retranscribe_all.confirm.message", comment: "Re-transcribe all message"),
            primaryTitle: NSLocalizedString("detail.retranscribe_all.confirm.action", comment: "Re-transcribe all confirm button"),
            primaryRole: .destructive,
            primaryAction: onConfirm,
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
    }
}
