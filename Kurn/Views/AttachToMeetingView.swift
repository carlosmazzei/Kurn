//
//  AttachToMeetingView.swift
//  Kurn
//
//  The sheet a PDF shared into Kurn from another app opens on: pick the
//  meeting it belongs to — or start a new one named after the file — and it
//  is attached there (`MeetingAttachmentImporter`), to be read alongside the
//  transcript and photos by the meeting's next summary. Presented by
//  `ContentView` while `IncomingFileInbox` holds files; `onFinished` empties
//  the inbox (deleting its copies) whichever way the sheet closes.
//

import KurnCore
import SwiftData
import SwiftUI

struct AttachToMeetingView: View {
    let files: [URL]
    let onFinished: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]

    @State private var searchText = ""
    @State private var isImporting = false
    @State private var importError: AppError?
    /// Title of the meeting the files went into, once they have.
    @State private var attachedMeetingTitle: String?

    var body: some View {
        NavigationStack {
            Group {
                if let attachedMeetingTitle {
                    doneView(meetingTitle: attachedMeetingTitle)
                } else {
                    pickerList
                }
            }
            .navigationTitle(NSLocalizedString("attach.title", comment: "Add to meeting"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if attachedMeetingTitle == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(NSLocalizedString("common.cancel", comment: "Cancel"), action: onFinished)
                            .disabled(isImporting)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(NSLocalizedString("common.done", comment: "Done"), action: onFinished)
                    }
                }
            }
            .overlay {
                if isImporting {
                    ProgressView(NSLocalizedString("detail.attachments.adding", comment: "Adding PDF"))
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .interactiveDismissDisabled(isImporting)
        .errorAlert($importError)
    }

    private var pickerList: some View {
        List {
            Section(NSLocalizedString("attach.files", comment: "Files being added")) {
                ForEach(files, id: \.self) { file in
                    Label(file.lastPathComponent, systemImage: "doc.richtext")
                        .font(Theme.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            Section {
                Button(action: attachToNewMeeting) {
                    Label(NSLocalizedString("attach.new_meeting", comment: "New meeting"), systemImage: "plus.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
                .accessibilityIdentifier("attach.new_meeting")
            }
            Section(NSLocalizedString("attach.meetings", comment: "Meetings")) {
                ForEach(filteredMeetings) { meeting in
                    Button { attach(to: meeting) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.title)
                                .font(Theme.body)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(2)
                            Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(Theme.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .searchable(text: $searchText)
        .disabled(isImporting)
    }

    private func doneView(meetingTitle: String) -> some View {
        ContentUnavailableView {
            Label(
                String(format: NSLocalizedString("attach.done.title", comment: "Added to meeting"), meetingTitle),
                systemImage: "checkmark.circle.fill"
            )
        } description: {
            Text(NSLocalizedString("attach.done.message", comment: "The document will be used in the summary"))
        }
    }

    private var filteredMeetings: [Meeting] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return meetings }
        return meetings.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func attachToNewMeeting() {
        let title = files.first.map { $0.deletingPathExtension().lastPathComponent } ?? ""
        do throws(AppError) {
            let meeting = try MeetingLibrary(context: modelContext).createMeeting(title: title)
            attach(to: meeting, isNewMeeting: true)
        } catch {
            importError = error
        }
    }

    private func attach(to meeting: Meeting, isNewMeeting: Bool = false) {
        guard !isImporting else { return }
        isImporting = true
        Task {
            let report = await MeetingAttachmentImporter(context: modelContext)
                .importPDFs(from: files, into: meeting)
            isImporting = false
            if report.importedCount > 0 {
                attachedMeetingTitle = meeting.title
            } else if isNewMeeting {
                // Nothing went in, so the meeting created for it would be an
                // empty leftover.
                try? MeetingLibrary(context: modelContext).deleteMeeting(meeting)
            }
            importError = report.firstFailure
        }
    }
}
