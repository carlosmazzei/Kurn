//
//  MeetingsListComponents.swift
//  Kurn
//
//  Reusable components for the meetings list so `MeetingsListView` stays focused
//  on state and navigation.
//

import SwiftUI

/// Full-screen overlay shown in place of the meetings list while the gate is
/// locked. Triggers authentication automatically when it appears and offers a
/// retry button when the user cancels the prompt or biometrics fail. When the
/// device has no passcode/biometrics configured, a Settings button lets the user
/// reach the in-app settings to disable the auth requirement instead of leaving
/// them stranded.
struct LockedRecordingsView: View {
    let gate: RecordingAccessGate
    @Binding var showingSettings: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textSecondary)
            Text(NSLocalizedString("recordings.locked_title", comment: "Recordings Locked"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(NSLocalizedString("recordings.locked_subtitle", comment: "Authenticate to view"))
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if let message = gate.lastError?.errorDescription {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await gate.authenticate() }
            } label: {
                Text(NSLocalizedString("recordings.unlock_button", comment: "Unlock"))
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            Button {
                showingSettings = true
            } label: {
                Text(NSLocalizedString("recordings.open_settings", comment: "Open Settings"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One card in the meetings list.
struct MeetingCard: View {
    let meeting: Meeting
    let preview: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                if meeting.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(Theme.warning)
                        .font(.system(size: 13))
                        .accessibilityLabel(NSLocalizedString("meetings.favorite", comment: "Favorite"))
                }
                Text(meeting.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !meeting.summaries.isEmpty {
                    Image(systemName: "sparkles").foregroundStyle(Theme.info)
                }
                StatusBadge(status: meeting.aggregateStatus)
            }
            HStack(spacing: 6) {
                Text(meeting.createdAt.meetingDisplay)
                if meeting.totalDuration > 0 {
                    Text("·")
                    Text(meeting.totalDuration.clockDisplay)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)

            metaChips

            if !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
        }
        .kurnCard()
    }

    /// Optional row of scannable chips: # speakers, # recordings, summary
    /// template. Each chip only appears when it adds information (≥2 speakers,
    /// >1 recording, template named).
    @ViewBuilder
    private var metaChips: some View {
        let speakerCount = meeting.speakers.count
        let recordingCount = meeting.recordings.count
        let templateName = meeting.latestSummary?.templateName ?? ""
        let hasTags = !meeting.tags.isEmpty
        if speakerCount >= 2 || recordingCount > 1 || !templateName.isEmpty || hasTags {
            HStack(spacing: 6) {
                if speakerCount >= 2 {
                    metaChip(systemImage: "person.2.fill", text: "\(speakerCount)")
                }
                if recordingCount > 1 {
                    metaChip(systemImage: "waveform", text: "\(recordingCount)")
                }
                if !templateName.isEmpty {
                    metaChip(systemImage: "doc.text", text: templateName)
                }
                if hasTags {
                    TagChipsView(tags: meeting.tags, maxVisible: 3)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func metaChip(systemImage: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.fill, in: Capsule())
    }
}
