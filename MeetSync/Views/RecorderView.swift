//
//  RecorderView.swift
//  MeetSync
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
                AppLog.recorderUI.log("RecorderView.onAppear: creating view model")
                vm = RecorderViewModel(
                    meeting: meeting,
                    modelContext: modelContext,
                    defaultMode: settings.defaultMode,
                    micPickup: settings.micPickup
                )
            }
        }
    }
}

private struct RecorderContent: View {
    @Bindable var vm: RecorderViewModel
    let onFinished: () -> Void

    @State private var levels: [Float] = Array(repeating: 0, count: 48)
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Text(vm.elapsed.clockDisplay)
                .font(.system(size: 56, weight: .light, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            waveform

            if let message = vm.routeMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()

            controls
                .padding(.bottom, 40)
        }
        .navigationTitle(NSLocalizedString("recorder.title", comment: "Record"))
        .navigationBarTitleDisplayMode(.inline)
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
            AppLog.recorderUI.log("RecorderContent.task: starting recording")
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

    private var waveform: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(barColor)
                    .frame(width: 4, height: max(3, CGFloat(levels[i]) * 120))
            }
        }
        .frame(height: 120)
        .animation(.linear(duration: 0.05), value: levels)
    }

    private var controls: some View {
        HStack(spacing: 48) {
            // Pause / resume (hidden until recording starts).
            Button {
                AppLog.recorderUI.log("UI: pause/resume button tapped, state=\(String(describing: vm.state), privacy: .public)")
                vm.togglePause()
            } label: {
                Image(systemName: vm.state == .paused ? "play.fill" : "pause.fill")
                    .font(.title)
                    .frame(width: 64, height: 64)
                    .background(Color(.secondarySystemBackground), in: Circle())
            }
            .disabled(vm.state == .idle)

            // Record control (pulses while recording).
            Button {
                AppLog.recorderUI.log("UI: record button tapped, state=\(String(describing: vm.state), privacy: .public)")
                guard vm.state == .idle else { return }
                Task { await vm.startRecording() }
            } label: {
                ZStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 84, height: 84)
                        .scaleEffect(pulse && vm.state == .recording ? 1.08 : 1.0)
                        .opacity(vm.state == .recording ? 1 : 0.5)
                    Image(systemName: "mic.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }

            // Stop & save.
            Button {
                AppLog.recorderUI.log("UI: stop button tapped, state=\(String(describing: vm.state), privacy: .public)")
                vm.stopAndSave()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.title)
                    .frame(width: 64, height: 64)
                    .background(Color(.secondarySystemBackground), in: Circle())
            }
            .disabled(vm.state == .idle)
        }
    }

    private var barColor: Color {
        switch vm.state {
        case .recording: return .red
        case .paused: return .orange
        case .idle: return .secondary
        }
    }
}
