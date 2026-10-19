//
//  StartRecordingWidget.swift
//  KurnLiveActivityExtension
//
//  A Home Screen / Lock Screen / StandBy widget that starts a recording via
//  `StartRecordingIntent`, the same intent `StartRecordingControl` uses. The
//  intent's `openAppWhenRun = true` foregrounds the app and runs it there, so
//  `RecordingLauncher` presents the same `RecorderView` a tap on the record
//  button does — this file only draws the button.
//
//  The widget is static by design: it has no timeline data, no App Group and
//  reads nothing from the app. A widget is visible on a locked device and in
//  StandBy, so showing a meeting title, a count or the last recording would
//  leak exactly what `hideLiveActivityMeetingTitle` keeps off the Lock Screen.
//

import AppIntents
import SwiftUI
import WidgetKit

struct StartRecordingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "ai.kurn.app.widget.startRecording",
            provider: StartRecordingWidgetProvider()
        ) { _ in
            StartRecordingWidgetView()
        }
        .configurationDisplayName("widget.startRecording.displayName")
        .description("widget.startRecording.description")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct StartRecordingWidgetEntry: TimelineEntry {
    let date: Date
}

/// One entry, never refreshed: the widget's content does not depend on time
/// or on any app state.
struct StartRecordingWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> StartRecordingWidgetEntry {
        StartRecordingWidgetEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (StartRecordingWidgetEntry) -> Void) {
        completion(StartRecordingWidgetEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StartRecordingWidgetEntry>) -> Void) {
        completion(Timeline(entries: [StartRecordingWidgetEntry(date: .now)], policy: .never))
    }
}

private struct StartRecordingWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Button(intent: StartRecordingIntent()) {
            content
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("control.startRecording.title"))
        .containerBackground(for: .widget) {
            if family.isAccessory {
                AccessoryWidgetBackground()
            } else {
                Color.kurnActivityBackground
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            RecordGlyph()
                .padding(10)
        case .accessoryRectangular:
            HStack(spacing: 8) {
                RecordGlyph()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("widget.startRecording.title")
                        .font(.headline)
                        .widgetAccentable()
                    Text("widget.startRecording.subtitle")
                        .font(.caption)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        case .systemMedium:
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    KurnLogo(size: 28)
                    Spacer(minLength: 0)
                    titleStack
                }
                Spacer(minLength: 0)
                RecordButtonDisc()
                    .frame(width: 88, height: 88)
            }
        default:
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    KurnLogo(size: 26)
                    Spacer(minLength: 0)
                    RecordButtonDisc()
                        .frame(width: 56, height: 56)
                }
                Spacer(minLength: 0)
                titleStack
            }
        }
    }

    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("widget.startRecording.title")
                .font(.headline)
                .foregroundStyle(.white)
            Text("widget.startRecording.subtitle")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
        }
        .minimumScaleFactor(0.8)
    }
}

/// The red record disc on the Home Screen families. Tinted and clear
/// rendering modes keep only the accented part, so the inner dot is the
/// element marked accentable.
private struct RecordButtonDisc: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.kurnAccent.opacity(0.18))
            Circle()
                .stroke(Color.kurnAccent, lineWidth: 3)
                .padding(4)
            Circle()
                .fill(Color.kurnAccent)
                .padding(14)
                .widgetAccentable()
        }
        .accessibilityHidden(true)
    }
}

/// Monochrome glyph for the Lock Screen accessory families, which render in
/// the system's vibrant style and ignore custom colors.
private struct RecordGlyph: View {
    var body: some View {
        Image(systemName: "record.circle.fill")
            .resizable()
            .scaledToFit()
            .widgetAccentable()
            .accessibilityHidden(true)
    }
}

private extension WidgetFamily {
    var isAccessory: Bool {
        switch self {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: true
        default: false
        }
    }
}
