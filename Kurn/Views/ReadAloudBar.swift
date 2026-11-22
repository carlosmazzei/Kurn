//
//  ReadAloudBar.swift
//  Kurn
//
//  The floating read-aloud bar that replaces the Ask bar at the bottom of a
//  meeting's detail screen while a summary is being read: what is playing
//  (paragraph counter + voice), prev/play/next, a progress hairline and a
//  close button. State stays in `ReadAloudController.shared`, the same
//  singleton `ReadAloudControl` drives on the wiki and document screens —
//  this is only the summary's floating chrome for it.
//

import KurnCore
import SwiftUI

struct ReadAloudBar: View {
    let item: ReadAloudItem
    /// Line the bar leads with; the summary's "Reading the summary" by default,
    /// other surfaces pass their own ("Reading the document").
    var title: String = NSLocalizedString("detail.read_aloud.title", comment: "Reading the summary")

    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var controller: ReadAloudController { .shared }
    private var phase: ReadAloudController.Phase { controller.phase(for: item.id) }
    /// A failed read leaves `phase == .idle` plus a recorded error — the bar
    /// stays mounted in that state so the message is seen and can be closed.
    private var readError: AppError? { controller.error(for: item.id) }
    private var errorOnly: Bool { phase == .idle && readError != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.subheadlineEmphasized)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if errorOnly, let readError {
                        Text(readError.errorDescription ?? "")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.destructive)
                            .lineLimit(2)
                    } else {
                        subtitleText
                            .font(Theme.caption)
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if errorOnly {
                    transportButton(icon: "xmark",
                                    label: NSLocalizedString("read_aloud.dismiss_error", comment: "Dismiss")) {
                        controller.clearError(for: item.id)
                    }
                } else {
                    transportButton(icon: "backward.fill",
                                    label: NSLocalizedString("read_aloud.previous", comment: "Previous paragraph")) {
                        controller.skip(by: -1)
                    }
                    toggleButton
                    transportButton(icon: "forward.fill",
                                    label: NSLocalizedString("read_aloud.next", comment: "Next paragraph")) {
                        controller.skip(by: 1)
                    }
                    transportButton(icon: "xmark",
                                    label: NSLocalizedString("read_aloud.stop", comment: "Stop reading")) {
                        controller.stop()
                    }
                }
            }

            if !errorOnly {
                ProgressView(value: controller.chunkCount > 0
                             ? Double(controller.chunkIndex + 1) / Double(controller.chunkCount)
                             : 0)
                    .progressViewStyle(.linear)
                    .tint(Theme.ink)
            }

            if let readError, !errorOnly {
                Text(readError.errorDescription ?? "")
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.destructive)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 1))
            } else {
                Color.clear
                    .glassEffect(in: .rect(cornerRadius: 26))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    /// While preparing: "Preparing audio…". Once speaking: "Paragraph N of
    /// M · <voice>", dropping the voice when the full line would truncate.
    @ViewBuilder
    private var subtitleText: some View {
        if phase == .preparing {
            Text(NSLocalizedString("read_aloud.preparing", comment: "Preparing audio"))
        } else {
            let progress = String(
                format: NSLocalizedString("read_aloud.progress_named", comment: "Paragraph N of M"),
                controller.chunkIndex + 1, controller.chunkCount
            )
            let voice = settings.speechProvider.speechSynthesisAPI == .system
                ? NSLocalizedString("read_aloud.voice.device", comment: "Device voice")
                : settings.speechProvider.displayName
            ViewThatFits(in: .horizontal) {
                Text("\(progress) · \(voice)")
                Text(progress)
            }
        }
    }

    private func transportButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 36, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var toggleButton: some View {
        Button {
            controller.toggle(item, settings: settings)
        } label: {
            Group {
                if phase == .preparing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.onInk)
                } else {
                    Image(systemName: phase == .paused ? "play.fill" : "pause.fill")
                        .font(.system(.callout, weight: .bold))
                        .foregroundStyle(Theme.onInk)
                }
            }
            .foregroundStyle(Theme.onInk)
            .frame(width: 38, height: 38)
            .background(Theme.ink, in: Circle())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(toggleAccessibilityLabel)
        .accessibilityIdentifier("readAloud.toggle")
    }

    private var toggleAccessibilityLabel: String {
        switch phase {
        case .preparing: return NSLocalizedString("read_aloud.preparing", comment: "Preparing audio")
        case .paused: return NSLocalizedString("read_aloud.resume", comment: "Resume reading")
        default: return NSLocalizedString("read_aloud.pause", comment: "Pause reading")
        }
    }
}
