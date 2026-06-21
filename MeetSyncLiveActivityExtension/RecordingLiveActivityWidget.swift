//
//  RecordingLiveActivityWidget.swift
//  MeetSyncLiveActivityExtension
//
//  Live Activity + Dynamic Island for an active recording, styled to match the
//  iOS design handoff: MeetSync logo, red record accent, a waveform strip, a live
//  timer, and Pause/Stop pills. Live Activities can't run continuous animations,
//  so the waveform/dot are rendered statically; the timer counts live via
//  `Text(_:style:)`.
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
                    HStack(spacing: 8) {
                        MeetSyncLogo(size: 26)
                        RecordingStatusBadge(context: context)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedText(context)
                        .font(.system(size: 17, weight: .light, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 12) {
                        ActivityWaveform(barCount: 10, height: 24, paused: context.state.isPaused)
                        commandButtons(context, height: 34)
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)
                }
            } compactLeading: {
                // Per the design: just the pulsing record dot.
                Circle()
                    .fill(context.state.isPaused ? Color.meetSyncPaused : Color.meetSyncAccent)
                    .frame(width: 8, height: 8)
            } compactTrailing: {
                elapsedText(context)
                    .font(.system(.caption2, design: .rounded).monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44)
                    .minimumScaleFactor(0.8)
            } minimal: {
                Circle()
                    .fill(context.state.isPaused ? Color.meetSyncPaused : Color.meetSyncAccent)
                    .frame(width: 8, height: 8)
            }
            .keylineTint(.meetSyncAccent)
        }
    }
}

// MARK: - Lock screen

private struct LockScreenRecordingView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    MeetSyncLogo(size: 28)
                    Text("MeetSync")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                HStack(spacing: 8) {
                    Circle()
                        .fill(context.state.isPaused ? Color.meetSyncPaused : Color.meetSyncAccent)
                        .frame(width: 7, height: 7)
                    elapsedText(context)
                        .font(.system(size: 22, weight: .light, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }

            ActivityWaveform(barCount: 16, height: 32, paused: context.state.isPaused)

            commandButtons(context, height: 44)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [.clear, Color.meetSyncAccent.opacity(0.65), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 2)
        }
    }
}

private struct RecordingStatusBadge: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(context.state.isPaused ? Color.meetSyncPaused : Color.meetSyncAccent)
                .frame(width: 6, height: 6)
            Text(statusText(context))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
    }
}

// MARK: - Shared pieces

/// MeetSync app glyph: red gradient rounded square with a record-circle.
private struct MeetSyncLogo: View {
    var size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(red: 1, green: 0.231, blue: 0.188), Color(red: 1, green: 0.376, blue: 0.188)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            .frame(width: size, height: size)
            .overlay {
                ZStack {
                    Circle().stroke(.white, lineWidth: size * 0.06).frame(width: size * 0.55, height: size * 0.55)
                    Circle().fill(.white).frame(width: size * 0.22, height: size * 0.22)
                }
            }
    }
}

/// Static red waveform strip (Live Activities can't animate continuously).
private struct ActivityWaveform: View {
    var barCount: Int
    var height: CGFloat
    var paused: Bool

    // Deterministic 0...1 heights that read as a voice waveform.
    private static let pattern: [CGFloat] = [
        0.9, 0.5, 0.95, 0.4, 0.8, 0.55, 1.0, 0.45, 0.85, 0.6,
        0.7, 0.5, 0.9, 0.45, 0.8, 0.6, 0.95, 0.5, 0.75, 0.55,
    ]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                let h = Self.pattern[i % Self.pattern.count]
                Capsule()
                    .fill((paused ? Color.meetSyncPaused : Color.meetSyncAccent).opacity(0.6 + 0.4 * h))
                    .frame(width: 3, height: max(4, height * h))
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }
}

@MainActor
private func commandButtons(
    _ context: ActivityViewContext<RecordingActivityAttributes>,
    height: CGFloat
) -> some View {
    HStack(spacing: 10) {
        commandLink(
            systemImage: context.state.isPaused ? "play.fill" : "pause.fill",
            label: context.state.isPaused ? "live_activity.resume" : "live_activity.pause",
            url: "meetsync://recording/toggle",
            style: .prominent,
            height: height
        )
        commandLink(
            systemImage: "stop.fill",
            label: "live_activity.stop",
            url: "meetsync://recording/stop",
            style: .destructive,
            height: height
        )
    }
}

@ViewBuilder
private func elapsedText(_ context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
    if context.state.isPaused {
        Text(context.state.elapsed.clockDisplay)
    } else {
        Text(context.state.referenceDate.addingTimeInterval(-context.state.elapsed), style: .timer)
            .multilineTextAlignment(.trailing)
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
    style: RecordingCommandStyle,
    height: CGFloat
) -> some View {
    Link(destination: URL(string: url)!) {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: height < 40 ? 11 : 13, weight: .bold))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: height < 40 ? 12 : 14, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(style.background, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(style.borderOpacity), lineWidth: 0.5))
    }
}

private enum RecordingCommandStyle {
    case prominent
    case destructive

    var background: Color {
        switch self {
        case .prominent: return .white.opacity(0.12)
        case .destructive: return .meetSyncStop.opacity(0.85)
        }
    }

    var borderOpacity: Double {
        switch self {
        case .prominent: return 0.1
        case .destructive: return 0
        }
    }
}

private extension Color {
    static let meetSyncActivityBackground = Color(red: 0.055, green: 0.055, blue: 0.071)
    static let meetSyncAccent = Color(red: 1.0, green: 0.231, blue: 0.188)
    static let meetSyncPaused = Color(red: 1.0, green: 0.624, blue: 0.039)
    static let meetSyncStop = Color(red: 1.0, green: 0.231, blue: 0.188)
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
