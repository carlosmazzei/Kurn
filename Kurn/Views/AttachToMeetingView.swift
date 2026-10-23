//
//  AttachToMeetingView.swift
//  Kurn
//
//  The sheet a PDF shared into Kurn from another app opens on: pick the
//  meeting it belongs to — or start a new one named after the file — and it
//  is attached there, to be read alongside the transcript and photos by the
//  meeting's next summary. Presented by `ContentView` while
//  `IncomingFileInbox` holds files; `onFinished` empties the inbox (deleting
//  its copies) whichever way the sheet closes. Every decision lives in
//  `AttachToMeetingViewModel`; this file only renders it.
//

import KurnCore
import SwiftData
import SwiftUI

struct AttachToMeetingView: View {
    let onFinished: () -> Void

    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]
    @State private var viewModel: AttachToMeetingViewModel

    init(files: [URL], modelContext: ModelContext, onFinished: @escaping () -> Void) {
        _viewModel = State(initialValue: AttachToMeetingViewModel(files: files, modelContext: modelContext))
        self.onFinished = onFinished
    }

    var body: some View {
        NavigationStack {
            Group {
                if let title = viewModel.attachedMeetingTitle {
                    doneView(meetingTitle: title)
                } else {
                    pickerList
                }
            }
            .navigationTitle(NSLocalizedString("attach.title", comment: "Add to meeting"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.isFinished {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(NSLocalizedString("common.done", comment: "Done"), action: onFinished)
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(NSLocalizedString("common.cancel", comment: "Cancel"), action: onFinished)
                            .disabled(viewModel.isImporting)
                    }
                }
            }
            .overlay {
                if viewModel.isImporting {
                    ProgressView(NSLocalizedString("detail.attachments.adding", comment: "Adding PDF"))
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isImporting)
        .errorAlert($viewModel.error)
    }

    private var pickerList: some View {
        List {
            Section(NSLocalizedString("attach.files", comment: "Files being added")) {
                ForEach(viewModel.files, id: \.self) { file in
                    Label(file.lastPathComponent, systemImage: "doc.richtext")
                        .font(Theme.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            Section {
                Button {
                    Task { await viewModel.attachToNewMeeting() }
                } label: {
                    Label(NSLocalizedString("attach.new_meeting", comment: "New meeting"), systemImage: "plus.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
                .accessibilityIdentifier("attach.new_meeting")
            }
            Section(NSLocalizedString("attach.meetings", comment: "Meetings")) {
                ForEach(viewModel.matchingMeetings(meetings)) { meeting in
                    Button {
                        Task { await viewModel.attach(to: meeting) }
                    } label: {
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
        .searchable(text: $viewModel.searchText)
        .disabled(viewModel.isImporting)
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
}
