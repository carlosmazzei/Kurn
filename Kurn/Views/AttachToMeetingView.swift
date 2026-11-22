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
    @State private var selectedMeeting: Meeting?

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
                    ToolbarItem(placement: .confirmationAction) {
                        Button(NSLocalizedString("attach.attach", comment: "Attach")) {
                            guard let selectedMeeting else { return }
                            Task { await viewModel.attach(to: selectedMeeting) }
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.ink)
                        .disabled(selectedMeeting == nil || viewModel.isImporting)
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
            Section {
                ForEach(viewModel.files, id: \.self) { file in
                    fileCard(file)
                }
            }
            Section {
                Button {
                    Task { await viewModel.attachToNewMeeting() }
                } label: {
                    Label(NSLocalizedString("attach.new_meeting", comment: "New meeting"), systemImage: "plus")
                        .foregroundStyle(Theme.link)
                }
                .accessibilityIdentifier("attach.new_meeting")
            }
            Section(NSLocalizedString("attach.recent", comment: "Recent")) {
                ForEach(viewModel.matchingMeetings(meetings)) { meeting in
                    Button {
                        selectedMeeting = meeting
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.title)
                                    .font(Theme.body)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(2)
                                Text("\(meeting.createdAt.relativeDay) · \(meeting.createdAt.shortTime)")
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if selectedMeeting?.persistentModelID == meeting.persistentModelID {
                                Image(systemName: "checkmark")
                                    .font(.system(.footnote, weight: .semibold))
                                    .foregroundStyle(Theme.link)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .searchable(
            text: $viewModel.searchText,
            prompt: NSLocalizedString("attach.search", comment: "Search meetings")
        )
        .disabled(viewModel.isImporting)
    }

    /// The incoming file as a card: `doc.text` on a grey well, filename, and
    /// the file size when the sandbox copy lets us stat it.
    private func fileCard(_ file: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 44, height: 52)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.lastPathComponent)
                    .font(Theme.subheadlineEmphasized)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let size = fileSizeString(file) {
                    Text(size)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func fileSizeString(_ file: URL) -> String? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
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
