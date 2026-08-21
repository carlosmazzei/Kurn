//
//  WatchRecorderView.swift
//  KurnWatch
//
//  Single-screen remote control: mirrors the iPhone's recording state and
//  lets the user pause, resume, or stop without touching the phone.
//

import SwiftUI

struct WatchRecorderView: View {
    @Environment(WatchConnectivityManager.self) private var connectivity

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
            Image(systemName: "iphone.gen3")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("watch.open_iphone")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
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
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            timerText()
                .font(.title2)
                .monospacedDigit()

            if highlightCount > 0 {
                Label("\(highlightCount)", systemImage: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }

            if !isPaused {
                LevelMeter(level: connectivity.level)
            }

            HStack(spacing: 16) {
                Button {
                    Task { await connectivity.send(isPaused ? .resume : .pause) }
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    Task { await connectivity.send(.stop) }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await connectivity.send(.highlight) }
                } label: {
                    Image(systemName: "star.fill")
                }
                .buttonStyle(.bordered)
                .disabled(isPaused)
            }

            if connectivity.lastCommandFailed {
                Text("watch.unreachable")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(.secondary.opacity(0.3))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.green)
                        .frame(width: geometry.size.width * CGFloat(level))
                }
        }
        .frame(height: 6)
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
