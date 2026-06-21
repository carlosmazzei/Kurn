//
//  RecordingLiveActivityWidget.swift
//  MeetSyncLiveActivityExtension
//

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MeetSyncLiveActivityExtensionBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivityWidget()
    }
}

struct RecordingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenRecordingView(context: context)
                .activityBackgroundTint(.meetSyncActivityBackground)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RecordingStatusBadge(context: context)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    elapsedText(context)
                        .font(.system(.caption, design: .rounded).monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(context.attributes.meetingTitle)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        HStack(spacing: 10) {
                            commandLink(
                                systemImage: context.state.isPaused ? "play.fill" : "pause.fill",
                                label: context.state.isPaused
                                    ? "live_activity.resume"
                                    : "live_activity.pause",
                                url: "meetsync://recording/toggle",
                                style: .prominent
                            )
                            commandLink(
                                systemImage: "stop.fill",
                                label: "live_activity.stop",
                                url: "meetsync://recording/stop",
                                style: .destructive
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "waveform")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(context.state.isPaused ? Color.meetSyncPaused : Color.meetSyncAccent)
            } compactTrailing: {
                elapsedText(context)
                    .font(.system(.caption2, design: .rounded).monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "waveform")
                    .foregroundStyle(context.state.isPaused ? Color.meetSyncPaused : Color.meetSyncAccent)
            }
            .keylineTint(.meetSyncAccent)
        }
    }
}

private struct LockScreenRecordingView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.meetSyncAccent.opacity(context.state.isPaused ? 0.16 : 0.22))
                        .frame(width: 44, height: 44)

                    Image(systemName: context.state.isPaused ? "pause.fill" : "waveform")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(context.state.isPaused ? Color.meetSyncPaused : Color.meetSyncAccent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(context.attributes.meetingTitle)
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    RecordingStatusBadge(context: context)
                }

                Spacer()

                elapsedText(context)
                    .font(.system(.title2, design: .rounded).monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }

            HStack(spacing: 10) {
                commandLink(
                    systemImage: context.state.isPaused ? "play.fill" : "pause.fill",
                    label: context.state.isPaused
                        ? "live_activity.resume"
                        : "live_activity.pause",
                    url: "meetsync://recording/toggle",
                    style: .prominent
                )
                commandLink(
                    systemImage: "stop.fill",
                    label: "live_activity.stop",
                    url: "meetsync://recording/stop",
                    style: .destructive
                )
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }
}

private struct RecordingStatusBadge: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(context.state.isPaused ? Color.meetSyncPaused : Color.meetSyncAccent)
                .frame(width: 7, height: 7)

            Text(statusText(context))
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
        }
    }
}

@ViewBuilder
private func elapsedText(_ context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
    if context.state.isPaused {
        Text(context.state.elapsed.clockDisplay)
    } else {
        Text(context.state.referenceDate.addingTimeInterval(-context.state.elapsed), style: .timer)
    }
}

private func statusText(_ context: ActivityViewContext<RecordingActivityAttributes>) -> LocalizedStringKey {
    context.state.isPaused ? "live_activity.paused" : "live_activity.recording"
}

@MainActor
private func commandLink(
    systemImage: String,
    label: LocalizedStringKey,
    url: String,
    style: RecordingCommandStyle
) -> some View {
    Link(destination: URL(string: url)!) {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .frame(width: 14)
                .foregroundStyle(style.icon)

            Text(label)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(style.foreground)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background(style.background, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private enum RecordingCommandStyle {
    case prominent
    case destructive

    var foreground: Color {
        .white
    }

    var icon: Color {
        switch self {
        case .prominent:
            return .meetSyncAccent
        case .destructive:
            return .meetSyncStop
        }
    }

    var background: Color {
        switch self {
        case .prominent:
            return .white.opacity(0.13)
        case .destructive:
            return .meetSyncStop.opacity(0.16)
        }
    }
}

private extension Color {
    static let meetSyncActivityBackground = Color(red: 0.055, green: 0.067, blue: 0.082)
    static let meetSyncAccent = Color(red: 0.22, green: 0.89, blue: 0.70)
    static let meetSyncPaused = Color(red: 1.0, green: 0.74, blue: 0.28)
    static let meetSyncStop = Color(red: 1.0, green: 0.32, blue: 0.35)
}

private extension TimeInterval {
    var clockDisplay: String {
        let total = Int(self.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
