//
//  WatchRecorderView.swift
//  KurnWatch
//
//  Single-screen remote control: starts a recording on the iPhone from the
//  idle screen, and mirrors its state with pause, resume, or stop without
//  touching the phone.
//

import SwiftUI

struct WatchRecorderView: View {
    @Environment(WatchConnectivityManager.self) private var connectivity
    /// While a `.start` command is awaiting the phone's reply.
    @State private var startInFlight = false
    /// The phone accepted `.start` while backgrounded — it records once the
    /// app comes to the foreground.
    @State private var startQueued = false

    private static let buttonGrey = Color(red: 0x2c / 255, green: 0x2c / 255, blue: 0x2e / 255)

    var body: some View {
        VStack(spacing: 12) {
            switch connectivity.state {
            case .idle:
                idleView
            case .recording(let title, let referenceDate, let accumulatedElapsed, let highlightCount):
                // Shift the reference date back by the already-accumulated time so the
                // native ticking Text shows accumulatedElapsed + (now - referenceDate).
                let timerOrigin = referenceDate.addingTimeInterval(-accumulatedElapsed)
                activeView(
                    title: title,
                    isPaused: false,
                    timerText: { Text(timerOrigin, style: .timer) },
                    accumulatedElapsed: accumulatedElapsed,
                    highlightCount: highlightCount
                )
            case .paused(let title, let accumulatedElapsed, let highlightCount):
                activeView(
                    title: title,
                    isPaused: true,
                    timerText: { Text(accumulatedElapsed.formattedTimer) },
                    accumulatedElapsed: accumulatedElapsed,
                    highlightCount: highlightCount
                )
            }
        }
        .padding()
    }

    private var idleView: some View {
        VStack(spacing: 8) {
            // The phone owns capture; this button only asks it to start —
            // a red disc inside a dark circle, like the recorder's Stop.
            Button {
                Task { await startRecording() }
            } label: {
                ZStack {
                    Circle()
                        .fill(Self.buttonGrey)
                        .frame(width: 84, height: 84)
                    Circle()
                        .fill(.red)
                        .frame(width: 34, height: 34)
                }
            }
            .buttonStyle(.plain)
            .disabled(startInFlight)
            .accessibilityLabel(Text("watch.start.title"))

            if startInFlight {
                ProgressView()
            }

            Text("watch.start.subtitle")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if startQueued {
                Text("watch.start.queued")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if connectivity.lastCommandFailed {
                Text("watch.unreachable")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private func startRecording() async {
        startInFlight = true
        defer { startInFlight = false }
        let outcome = await connectivity.sendWithOutcome(.start)
        switch (outcome.ok, outcome.phase, outcome.error) {
        case (true, .queued, _):
            startQueued = true
        case (true, _, _):
            startQueued = false
        case (false, _, WatchSessionReplyError.recordingAlreadyActive):
            // Already recording on the phone — nothing to show; the pushed
            // context flips this view to the active state on its own.
            startQueued = false
            connectivity.clearCommandFailure()
        default:
            startQueued = false
        }
    }

    @ViewBuilder
    private func activeView(
        title: String,
        isPaused: Bool,
        timerText: () -> Text,
        accumulatedElapsed: TimeInterval,
        highlightCount: Int
    ) -> some View {
        VStack(spacing: 8) {
            Text("\(Text(isPaused ? "watch.state.paused" : "watch.state.recording")) · \(title)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            timerText()
                .font(.title2)
                .monospacedDigit()

            if highlightCount > 0 {
                Label("\(highlightCount)", systemImage: "bookmark.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 16) {
                Button {
                    Task { await connectivity.send(isPaused ? .resume : .pause) }
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 52, height: 52)
                        .background(Self.buttonGrey, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(isPaused ? "watch.resume" : "watch.pause"))

                Button(role: .destructive) {
                    Task { await connectivity.send(.stop) }
                } label: {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(.red, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("watch.stop"))

                Button {
                    Task { await connectivity.send(.highlight) }
                } label: {
                    Image(systemName: "bookmark.fill")
                        .frame(width: 52, height: 52)
                        .background(Self.buttonGrey, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isPaused)
                .accessibilityLabel(Text("watch.highlight"))
            }

            if connectivity.lastCommandFailed {
                Text("watch.unreachable")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}

private extension TimeInterval {
    var formattedTimer: String {
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
