//
//  ReadAloudControl.swift
//  Kurn
//
//  The inline "Read aloud" control shown above a summary, a wiki article and a
//  generated document. It owns no playback state — everything lives in
//  `ReadAloudController.shared` — so two screens showing the same content
//  agree on whether it is playing, and a failure shows under the control whose
//  text failed rather than as an alert that might land behind a sheet.
//

import KurnCore
import SwiftUI

struct ReadAloudControl: View {
    let item: ReadAloudItem

    @Environment(AppSettings.self) private var settings

    private var controller: ReadAloudController { .shared }

    var body: some View {
        let phase = controller.phase(for: item.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                toggleButton(phase)
                if phase != .idle {
                    transportButtons
                    Text(String(
                        format: NSLocalizedString("read_aloud.progress", comment: "Paragraph N of M"),
                        controller.chunkIndex + 1, controller.chunkCount
                    ))
                    .font(Theme.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            if let error = controller.error(for: item.id) {
                errorRow(error)
            }
        }
    }

    private func toggleButton(_ phase: ReadAloudController.Phase) -> some View {
        Button {
            controller.toggle(item, settings: settings)
        } label: {
            HStack(spacing: 6) {
                if phase == .preparing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: Self.icon(for: phase))
                        .accessibilityHidden(true)
                }
                Text(Self.title(for: phase))
            }
            .font(Theme.subheadlineEmphasized)
        }
        .buttonStyle(.bordered)
        .tint(Theme.accent)
        .accessibilityIdentifier("readAloud.toggle")
    }

    private var transportButtons: some View {
        HStack(spacing: 4) {
            Button { controller.skip(by: -1) } label: {
                Image(systemName: "backward.end.fill")
                    .frame(minWidth: 32, minHeight: 32)
            }
            .accessibilityLabel(NSLocalizedString("read_aloud.previous", comment: "Previous paragraph"))
            Button { controller.skip(by: 1) } label: {
                Image(systemName: "forward.end.fill")
                    .frame(minWidth: 32, minHeight: 32)
            }
            .accessibilityLabel(NSLocalizedString("read_aloud.next", comment: "Next paragraph"))
            Button { controller.stop() } label: {
                Image(systemName: "stop.fill")
                    .frame(minWidth: 32, minHeight: 32)
            }
            .accessibilityLabel(NSLocalizedString("read_aloud.stop", comment: "Stop reading"))
            .accessibilityIdentifier("readAloud.stop")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.textSecondary)
    }

    private func errorRow(_ error: AppError) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            Text(error.errorDescription ?? "")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { controller.clearError() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("read_aloud.dismiss_error", comment: "Dismiss read-aloud error"))
        }
    }

    private static func icon(for phase: ReadAloudController.Phase) -> String {
        switch phase {
        case .idle: return "speaker.wave.2.fill"
        case .preparing, .speaking: return "pause.fill"
        case .paused: return "play.fill"
        }
    }

    private static func title(for phase: ReadAloudController.Phase) -> String {
        switch phase {
        case .idle: return NSLocalizedString("read_aloud.start", comment: "Read aloud")
        case .preparing, .speaking: return NSLocalizedString("read_aloud.pause", comment: "Pause reading")
        case .paused: return NSLocalizedString("read_aloud.resume", comment: "Resume reading")
        }
    }
}

// MARK: - Content

extension ReadAloudItem {
    static func summary(_ summary: Summary, meeting: Meeting) -> ReadAloudItem {
        ReadAloudItem(
            id: "summary:\(summary.id.uuidString)",
            ownerID: meeting.id,
            title: meeting.title,
            subtitle: NSLocalizedString("read_aloud.kind.summary", comment: "Summary (Now Playing subtitle)"),
            spokenText: SpokenText.fromSections(summary.sections)
        )
    }

    static func wiki(_ article: WikiArticle) -> ReadAloudItem {
        ReadAloudItem(
            id: "wiki:\(article.id.uuidString)",
            ownerID: article.meeting?.id ?? article.id,
            title: article.meeting?.title ?? article.meetingTitleSnapshot,
            subtitle: NSLocalizedString("read_aloud.kind.wiki", comment: "Meeting wiki (Now Playing subtitle)"),
            spokenText: SpokenText.fromMarkdown(article.bodyMarkdown)
        )
    }

    static func document(_ document: GeneratedDocument) -> ReadAloudItem {
        ReadAloudItem(
            id: "document:\(document.id.uuidString)",
            ownerID: document.id,
            title: document.title,
            subtitle: NSLocalizedString("read_aloud.kind.document", comment: "Document (Now Playing subtitle)"),
            spokenText: SpokenText.fromMarkdown(document.bodyMarkdown)
        )
    }
}
