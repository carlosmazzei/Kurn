//
//  RecorderView.swift
//  Kurn
//
//  Full-screen recorder: pulsing record control, live waveform meter, elapsed
//  timer, pause/resume, and stop-and-save. Recording is offline-first; the file
//  is written to Documents as it records.
//

import os
import SwiftData
import SwiftUI

struct RecorderView: View {
    let meeting: Meeting

    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var vm: RecorderViewModel?

    var body: some View {
        Group {
            if let vm {
                RecorderContent(vm: vm) {
                    dismiss()
                }
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if vm == nil {
                AppLog.recorderUI.debug("RecorderView.onAppear: creating view model")
                vm = RecorderViewModel(
                    meeting: meeting,
                    modelContext: modelContext,
                    defaultMode: settings.defaultMode,
                    micPickup: settings.micPickup,
                    audioQuality: settings.audioQuality,
                    liveTranscriptionEnabled: settings.liveTranscriptionEnabled
                )
            }
        }
    }
}

private struct RecorderContent: View {
    @Bindable var vm: RecorderViewModel
    let onFinished: () -> Void

    @State private var levels: [Float] = Array(repeating: 0, count: 40)

    var body: some View {
        ZStack {
            // Immersive black backdrop with a soft red glow, per the design mock.
            Color.black.ignoresSafeArea()
            RadialGradient(
                colors: [Theme.accent.opacity(0.12), .clear],
                center: .center, startRadius: 0, endRadius: 260
            )
            .ignoresSafeArea()
            .opacity(vm.state == .recording ? 1 : 0.4)

            VStack(spacing: 0) {
                topBar
                Spacer()
                statusBadge
                timer
                    .padding(.top, 22)
                waveform
                    .padding(.top, 26)
                titleField
                    .padding(.top, 28)
                liveTranscriptArea
                routeMessage
                Spacer()
                controls
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: vm.level) { _, newValue in
            levels.removeFirst()
            levels.append(newValue)
        }
        .onChange(of: vm.didSaveRecording) { _, saved in
            if saved { onFinished() }
        }
        .task {
            // The recorder spins up its audio engine off the main actor, so this
            // does not block the sheet's present animation.
            AppLog.recorderUI.notice("RecorderContent.task: starting recording")
            await vm.startRecording()
        }
        .alert(
            NSLocalizedString("recorder.permission.title", comment: "Mic permission"),
            isPresented: $vm.permissionDenied
        ) {
            Button(NSLocalizedString("common.ok", comment: "OK"), role: .cancel) { onFinished() }
        } message: {
            Text(NSLocalizedString("recorder.permission.message", comment: ""))
        }
        .alert(
            NSLocalizedString("common.error", comment: "Error"),
            isPresented: Binding(
                get: { vm.error != nil },
                set: { if !$0 { vm.error = nil } }
            ),
            presenting: vm.error
        ) { _ in
            Button(NSLocalizedString("common.ok", comment: "OK"), role: .cancel) {}
        } message: { error in
            Text(error.errorDescription ?? "")
        }
        .interactiveDismissDisabled(vm.state != .idle)
    }

    // MARK: - Subviews

    private var topBar: some View {
        HStack {
            Button(NSLocalizedString("common.cancel", comment: "Cancel")) {
                vm.cancel()
                onFinished()
            }
            .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(NSLocalizedString("recorder.title", comment: "Record"))
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            // Balance the Cancel button so the title stays centered.
            Text(NSLocalizedString("common.cancel", comment: "Cancel"))
                .opacity(0)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 8) {
            if vm.state == .recording {
                PulsingDot(color: Theme.accent)
            } else {
                Circle()
                    .fill(vm.state == .paused ? Theme.warning : Theme.accent)
                    .frame(width: 10, height: 10)
            }
            Text(vm.state == .paused
                 ? NSLocalizedString("recorder.paused", comment: "Paused")
                 : "REC")
                .font(.system(size: 13, weight: .bold))
                .tracking(2.5)
                .foregroundStyle(vm.state == .paused ? Theme.warning : Theme.accent)
        }
    }

    private var timer: some View {
        Text(vm.elapsed.clockDisplay)
            .font(.system(size: 64, weight: .ultraLight, design: .default))
            .monospacedDigit()
            .foregroundStyle(.white)
            .contentTransition(.numericText())
    }

    private var titleField: some View {
        VStack(spacing: 8) {
            TextField(
                NSLocalizedString("recorder.add_title", comment: "Add title…"),
                text: $vm.meetingTitle
            )
            .multilineTextAlignment(.center)
            .font(.system(size: 17))
            .foregroundStyle(.white)
            .tint(Theme.accent)
            Rectangle()
                .fill(.white.opacity(0.1))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var liveTranscriptArea: some View {
        if vm.isLiveTranscriptionRequested {
            ScrollView {
                Text(liveTranscriptText)
                    .font(.system(size: 15))
                    .foregroundStyle(liveTranscriptColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: 90)
            .padding(.top, 16)
        }
    }

    private var liveTranscriptText: String {
        if vm.isLiveTranscriptionUnavailable {
            return NSLocalizedString("recorder.live_unavailable", comment: "Live transcription unavailable")
        }
        if vm.isLiveTranscriptionLoading {
            return NSLocalizedString("recorder.live_loading", comment: "Preparing live transcription")
        }
        if !vm.livePartialText.isEmpty {
            return vm.livePartialText
        }
        return NSLocalizedString("recorder.live_listening", comment: "Listening…")
    }

    private var liveTranscriptColor: Color {
        if vm.isLiveTranscriptionUnavailable { return Theme.warning }
        return vm.livePartialText.isEmpty ? .white.opacity(0.4) : .white.opacity(0.85)
    }

    @ViewBuilder
    private var routeMessage: some View {
        if let message = vm.routeMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.warning)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
        }
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 3.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(barColor.opacity(i.isMultiple(of: 3) ? 0.7 : 1))
                    .frame(width: 3, height: max(4, CGFloat(levels[i]) * 56))
            }
        }
        .frame(height: 56)
        .animation(.linear(duration: 0.06), value: levels)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            // Pause / resume.
            Button {
                AppLog.recorderUI.info("UI: pause/resume tapped, state=\(String(describing: vm.state), privacy: .public)")
                vm.togglePause()
            } label: {
                pillLabel(
                    systemImage: vm.state == .paused ? "play.fill" : "pause.fill",
                    title: vm.state == .paused
                        ? NSLocalizedString("recorder.resume", comment: "Resume")
                        : NSLocalizedString("recorder.pause", comment: "Pause"),
                    foreground: .white,
                    background: AnyShapeStyle(.white.opacity(0.1)),
                    bordered: true
                )
            }
            .disabled(vm.state == .idle)

            // Stop & save.
            Button {
                AppLog.recorderUI.info("UI: stop tapped, state=\(String(describing: vm.state), privacy: .public)")
                vm.stopAndSave()
            } label: {
                pillLabel(
                    systemImage: "stop.fill",
                    title: NSLocalizedString("recorder.stop", comment: "Stop"),
                    foreground: .white,
                    background: AnyShapeStyle(Theme.accent),
                    bordered: false
                )
            }
            .disabled(vm.state == .idle)
            .shadow(color: Theme.accent.opacity(vm.state == .idle ? 0 : 0.45), radius: 14, y: 4)
        }
        .opacity(vm.state == .idle ? 0.5 : 1)
    }

    private func pillLabel(
        systemImage: String,
        title: String,
        foreground: Color,
        background: AnyShapeStyle,
        bordered: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
            Text(title).font(.system(size: 16, weight: .semibold))
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background(background, in: Capsule())
        .overlay(
            Capsule().stroke(.white.opacity(bordered ? 0.1 : 0), lineWidth: 0.5)
        )
    }

    private var barColor: Color {
        switch vm.state {
        case .recording: return Theme.accent
        case .paused: return Theme.warning
        case .idle: return .white.opacity(0.3)
        }
    }
}

/// A self-contained pulsing dot. Isolating the `repeatForever` animation here
/// keeps it from interacting with the recorder's 20 Hz metering re-renders.
private struct PulsingDot: View {
    let color: Color
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .opacity(dim ? 0.25 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}
