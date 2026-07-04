//
//  RecordingLiveActivityWidget.swift
//  KurnLiveActivityExtension
//
//  Live Activity + Dynamic Island for an active recording, styled to match the
//  iOS design handoff: Kurn logo, red record accent, a waveform strip, a live
//  timer, and Pause/Stop pills. Live Activities can't run continuous animations,
//  so the waveform/dot are rendered statically; the timer counts live via
//  `Text(_:style:)`.
//

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct KurnLiveActivityExtensionBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivityWidget()
    }
}

struct RecordingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenRecordingView(context: context)
                .activityBackgroundTint(.kurnActivityBackground)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        KurnLogo(size: 26)
                        RecordingStatusBadge(context: context)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedText(context)
                        .font(.system(size: 17, weight: .light, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    commandButtons(context, height: 34)
                        .padding(.horizontal, 2)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                }
            } compactLeading: {
                // Kurn icon (circular clip avoids pill-edge clipping) + live timer.
                HStack(spacing: 5) {
                    KurnLogo(size: 18)
                        .clipShape(Circle())
                        .padding(.leading, 2)
                    elapsedText(context)
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(context.state.isPaused ? Color.kurnPaused : Color.kurnAccent)
                        .fixedSize()
                }
            } compactTrailing: {
                // Waveform mirrors the phone-call indicator: active while recording,
                // dimmed when paused.
                Image(systemName: context.state.isPaused ? "waveform.slash" : "waveform")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(context.state.isPaused ? .white.opacity(0.4) : .white)
                    .padding(.trailing, 2)
            } minimal: {
                // Circular icon keeps the minimal indicator on-brand.
                KurnLogo(size: 16)
                    .clipShape(Circle())
            }
            .keylineTint(.kurnAccent)
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
                    KurnLogo(size: 28)
                    Text("Kurn")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                HStack(spacing: 8) {
                    Circle()
                        .fill(context.state.isPaused ? Color.kurnPaused : Color.kurnAccent)
                        .frame(width: 7, height: 7)
                    elapsedText(context)
                        .font(.system(size: 22, weight: .light, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }

            commandButtons(context, height: 44)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [.clear, Color.kurnAccent.opacity(0.65), .clear],
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
                .fill(context.state.isPaused ? Color.kurnPaused : Color.kurnAccent)
                .frame(width: 6, height: 6)
            Text(statusText(context))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
    }
}

// MARK: - Shared pieces

/// Kurn app glyph: red gradient rounded square with a record-circle.
private struct KurnLogo: View {
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

@MainActor
private func commandButtons(
    _ context: ActivityViewContext<RecordingActivityAttributes>,
    height: CGFloat
) -> some View {
    HStack(spacing: 10) {
        commandLink(
            systemImage: context.state.isPaused ? "play.fill" : "pause.fill",
            label: context.state.isPaused ? "live_activity.resume" : "live_activity.pause",
            url: "kurn://recording/toggle",
            style: .prominent,
            height: height
        )
        commandLink(
            systemImage: "stop.fill",
            label: "live_activity.stop",
            url: "kurn://recording/stop",
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
        case .destructive: return .kurnStop.opacity(0.85)
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
    static let kurnActivityBackground = Color(red: 0.055, green: 0.055, blue: 0.071)
    static let kurnAccent = Color(red: 1.0, green: 0.231, blue: 0.188)
    static let kurnPaused = Color(red: 1.0, green: 0.624, blue: 0.039)
    static let kurnStop = Color(red: 1.0, green: 0.231, blue: 0.188)
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
