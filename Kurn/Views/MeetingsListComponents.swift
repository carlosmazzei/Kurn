//
//  MeetingsListComponents.swift
//  Kurn
//
//  Reusable components for the meetings list so `MeetingsListView` stays focused
//  on state and navigation.
//

import KurnCore
import LocalAuthentication
import SwiftUI

/// The lock screen, rendered by `SecurityCoverView` in the cover window that
/// sits above the whole app. Offers a retry button when the user cancels the
/// prompt or biometrics fail. Only when the device has no passcode configured
/// does a Settings button let the user turn the auth requirement off instead
/// of leaving them stranded — the cover presents that (deliberately minimal)
/// sheet itself, since nothing below the cover window is reachable. Triggering authentication is the cover's job, not this view's.
struct LockedRecordingsView: View {
    let gate: RecordingAccessGate
    @Binding var showingSettings: Bool

    /// The biometric the system prompt will lead with, read once — only a
    /// `canEvaluatePolicy` check, so choosing the glyph never triggers a
    /// prompt. Falls back to the generic open lock when there is no biometric.
    private static let unlockGlyph: String = {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return "lock.open"
        }
        switch context.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.open"
        }
    }()

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 46))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            Text(NSLocalizedString("recordings.locked_title", comment: "Recordings Locked"))
                .font(.title2.bold())
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
            // The one action this screen exists for — Liquid Glass primary
            // button language (Theme.swift, "Button language"), not a
            // hand-drawn rectangle.
            Button {
                Task { await gate.authenticate() }
            } label: {
                Label(
                    NSLocalizedString("recordings.unlock_button", comment: "Unlock"),
                    systemImage: Self.unlockGlyph
                )
                .font(Theme.subheadlineEmphasized)
                .foregroundStyle(Theme.onInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.ink)
            .padding(.top, 4)
            // Only when the device cannot authenticate at all; see
            // `RecordingAccessGate.offersSettingsEscapeHatch`.
            if gate.offersSettingsEscapeHatch {
                Button {
                    showingSettings = true
                } label: {
                    Text(NSLocalizedString("recordings.open_settings", comment: "Open Settings"))
                        .font(Theme.subheadlineEmphasized)
                        .foregroundStyle(Theme.link)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One row in the meetings list: title, a metadata-or-status line, an optional
/// folder/tags line, and trailing grey indicators (favourite, transcript,
/// summary count). No card chrome — it sits in a grouped `List` row.
struct MeetingCard: View {
    let meeting: Meeting
    /// Flat (non-day-grouped) sorts prefix the metadata line with the short
    /// date, since no section header carries it.
    var showsDate = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // One step below body so the generated default title
                // ("Meeting – 2026-11-22 04:27 GMT-3") fits one line on an
                // iPhone; long custom titles still wrap to a second line.
                Text(primaryTitle)
                    .font(Theme.calloutEmphasized)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                // The AI title is what tells meetings apart while the person
                // has not typed one: it leads when the title is still the
                // generated default, and reads as a second line otherwise.
                if let secondaryTitle {
                    Text(secondaryTitle)
                        .font(Theme.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }

                statusOrMetadata

                classifiers
            }
            Spacer(minLength: 8)
            indicators
        }
    }

    private var trimmedAITitle: String? {
        let trimmed = meeting.aiTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The AI title leads while the meeting still has its generated default
    /// name; a title the person typed always leads.
    private var primaryTitle: String {
        if meeting.isDefaultTitle, let trimmedAITitle { return trimmedAITitle }
        return meeting.title
    }

    /// The AI title as a second line under a typed title; nothing when there
    /// is no AI title or it already leads.
    private var secondaryTitle: String? {
        guard let trimmedAITitle, !meeting.isDefaultTitle, trimmedAITitle != meeting.title else { return nil }
        return trimmedAITitle
    }

    /// Line 2: the time/duration line, replaced by status words whenever the
    /// meeting needs attention (transcribing, queued, failed).
    @ViewBuilder
    private var statusOrMetadata: some View {
        switch meeting.aggregateStatus {
        case .inProgress:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
                Text(NSLocalizedString("meetings.status.transcribing", comment: "Transcribing"))
            }
            .font(Theme.subheadline)
            .foregroundStyle(Theme.warning)
        case .pending:
            Text(NSLocalizedString("meetings.status.queued", comment: "Queued to resume"))
                .font(Theme.subheadline)
                .foregroundStyle(Theme.warning)
        case .failed:
            Text(NSLocalizedString("meetings.status.transcription_failed", comment: "Transcription failed"))
                .font(Theme.subheadline)
                .foregroundStyle(Theme.destructive)
        case .none, .done:
            Text(metadataLine)
                .font(Theme.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    /// "18:28 · 12 min" for day-grouped lists, "Nov 20 · 18:28 · 12 min" for
    /// flat sorts. The duration joins only when the meeting has audio.
    private var metadataLine: String {
        var parts: [String] = []
        if showsDate {
            parts.append(meeting.createdAt.formatted(.dateTime.month(.abbreviated).day()))
        }
        parts.append(meeting.createdAt.formatted(date: .omitted, time: .shortened))
        if meeting.totalDuration > 0 {
            parts.append(durationText)
        }
        return parts.joined(separator: " · ")
    }

    private var durationText: String {
        Duration.seconds(meeting.totalDuration)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated,
                              maximumUnitCount: 2))
    }

    /// Line 3: folder glyph + name, then up to three tag dots + names, then
    /// "+N" — only rendered when the meeting has either.
    @ViewBuilder
    private var classifiers: some View {
        let visibleTags = Array(meeting.tags.prefix(3))
        let overflowCount = max(0, meeting.tags.count - visibleTags.count)
        if meeting.folder != nil || !meeting.tags.isEmpty {
            FlowLayout(horizontalSpacing: 10, verticalSpacing: 4) {
                if let folder = meeting.folder {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Color(hex: folder.colorHex))
                            .accessibilityHidden(true)
                        Text(folder.name)
                            .lineLimit(1)
                    }
                }
                ForEach(visibleTags) { tag in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(hex: tag.colorHex))
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(tag.name)
                            .lineLimit(1)
                    }
                }
                if overflowCount > 0 {
                    Text("+\(overflowCount)")
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .font(Theme.footnote)
            .foregroundStyle(Theme.textSecondary)
        }
    }

    /// Trailing grey glyphs, read top-aligned against the title line.
    @ViewBuilder
    private var indicators: some View {
        HStack(spacing: 8) {
            if meeting.isFavorite {
                Image(systemName: "star.fill")
                    .accessibilityHidden(true)
            }
            if meeting.aggregateStatus == .done {
                Image(systemName: "text.alignleft")
                    .accessibilityHidden(true)
            }
            if !meeting.summaries.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "sparkles")
                        .accessibilityHidden(true)
                    if meeting.summaries.count > 1 {
                        Text("\(meeting.summaries.count)")
                    }
                }
            }
        }
        .font(Theme.footnote)
        .foregroundStyle(Theme.indicator)
    }

    /// One spoken line combining title, status/time and the indicator words
    /// ("Favourite", "Transcribed", "N summaries") the glyphs stand for. The
    /// row Button reads it via `accessibilitySummary` — the combined-a11y
    /// element lives on the button, not on this inner stack, so the button's
    /// hit point stays tappable in every row.
    var accessibilitySummary: String {
        var parts = [primaryTitle]
        if let secondaryTitle { parts.append(secondaryTitle) }
        switch meeting.aggregateStatus {
        case .inProgress:
            parts.append(NSLocalizedString("meetings.status.transcribing", comment: "Transcribing"))
        case .pending:
            parts.append(NSLocalizedString("meetings.status.queued", comment: "Queued to resume"))
        case .failed:
            parts.append(NSLocalizedString("meetings.status.transcription_failed", comment: "Transcription failed"))
        case .none, .done:
            parts.append(metadataLine)
        }
        if meeting.isFavorite {
            parts.append(NSLocalizedString("meetings.favorite", comment: "Favorite"))
        }
        if meeting.aggregateStatus == .done {
            parts.append(NSLocalizedString("status.done", comment: "Done"))
        }
        if !meeting.summaries.isEmpty {
            let count = meeting.summaries.count
            let key = count == 1 ? "meetings.summary_count.one" : "meetings.summary_count.other"
            parts.append(String(format: NSLocalizedString(key, comment: "Summary count"), count))
        }
        return parts.joined(separator: ", ")
    }
}
