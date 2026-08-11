//
//  MeetingsListComponents.swift
//  Kurn
//
//  Reusable components for the meetings list so `MeetingsListView` stays focused
//  on state and navigation.
//

import SwiftUI

/// The lock screen, rendered by `SecurityCoverView` in the cover window that
/// sits above the whole app. Offers a retry button when the user cancels the
/// prompt or biometrics fail. When the device has no passcode/biometrics
/// configured, a Settings button lets the user reach the in-app settings to
/// disable the auth requirement instead of leaving them stranded — the cover
/// presents that sheet itself, since nothing below the cover window is
/// reachable. Triggering authentication is the cover's job, not this view's.
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
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
                }

                metadata

                if !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }

                classifiers
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .kurnCard()
    }

    @ViewBuilder
    private var metadata: some View {
        FlowLayout(horizontalSpacing: 10, verticalSpacing: 4) {
            metadataItem(systemImage: "calendar", text: meeting.createdAt.meetingDisplay)
            if meeting.totalDuration > 0 {
                metadataItem(systemImage: "clock", text: meeting.totalDuration.clockDisplay)
            }
            metadataItem(
                systemImage: transcriptionIcon,
                text: meeting.aggregateStatus.displayName,
                tint: transcriptionColor
            )
            if !meeting.summaries.isEmpty {
                metadataItem(
                    systemImage: "sparkles",
                    text: summaryCountText,
                    tint: Theme.info
                )
            }
        }
    }

    @ViewBuilder
    private var classifiers: some View {
        let visibleTags = Array(meeting.tags.prefix(3))
        let overflowCount = max(0, meeting.tags.count - visibleTags.count)
        if meeting.folder != nil || !meeting.tags.isEmpty {
            FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                if let folder = meeting.folder {
                    folderChip(folder)
                }
                ForEach(visibleTags) { tag in
                    TagChip(tag: tag)
                }
                if overflowCount > 0 {
                    Text("+\(overflowCount)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.fill, in: Capsule())
                }
            }
        }
    }

    private func metadataItem(systemImage: String, text: String, tint: Color = Theme.textSecondary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: 13))
        .foregroundStyle(tint)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func folderChip(_ folder: Folder) -> some View {
        HStack(spacing: 4) {
            Image(systemName: folder.iconName)
                .font(.system(size: 10, weight: .semibold))
            Text(folder.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(Color(hex: folder.colorHex))
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(hex: folder.colorHex).opacity(0.12), in: Capsule())
    }

    private var summaryCountText: String {
        let count = meeting.summaries.count
        let key = count == 1 ? "meetings.summary_count.one" : "meetings.summary_count.other"
        return String(
            format: NSLocalizedString(key, comment: "Number of summaries on a meeting card"),
            count
        )
    }

    private var transcriptionIcon: String {
        switch meeting.aggregateStatus {
        case .none: return "waveform.slash"
        case .inProgress: return "waveform"
        case .pending: return "pause.circle"
        case .done: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        }
    }

    private var transcriptionColor: Color {
        switch meeting.aggregateStatus {
        case .none: return Theme.textSecondary
        case .inProgress, .pending: return Theme.warning
        case .done: return Theme.success
        case .failed: return Theme.accent
        }
    }
}
