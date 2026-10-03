//
//  PhotoCaptureView.swift
//  Kurn
//
//  A camera sheet presented from `RecorderView` while a recording is active,
//  laid out like the system Camera (lens buttons, flash and timer menus,
//  thumbnail / shutter / flip row, focus square with exposure sun) but drawn
//  here rather than with the system picker — see `PhotoCaptureController`'s
//  header for why. The sheet stays open between shots, as the system Camera
//  does; "Done" returns to the recording.
//

import AVFoundation
import SwiftUI
import UIKit

struct PhotoCaptureView: View {
    let onCapture: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var controller = PhotoCaptureController()
    @State private var isCapturing = false
    @State private var flashMode: PhotoFlashMode = .auto
    @State private var timer: PhotoTimer = .off
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var focusPoint: CGPoint?
    @State private var lastThumbnail: UIImage?
    @State private var shotCount = 0
    @State private var shutterFlash = false
    /// Degrees the icons are turned so they stay upright as the phone turns.
    @State private var iconRotation: Double = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PhotoCapturePreview(controller: controller, focusPoint: $focusPoint)
                .ignoresSafeArea()

            GeometryReader { proxy in
                if let focusPoint {
                    FocusControl(
                        exposure: Binding(
                            get: { controller.exposureLevel },
                            set: { controller.setExposureLevel($0) }
                        ),
                        sunOnLeading: focusPoint.x > proxy.size.width - 90
                    )
                    .position(focusPoint)
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                if let countdown {
                    Text("\(countdown)")
                        .font(.system(size: 96, weight: .light))
                        .foregroundStyle(.white)
                        .shadow(radius: 6)
                        .accessibilityHidden(true)
                    Spacer()
                }
                if controller.lensStops.count > 1 {
                    lensRow.padding(.bottom, 16)
                }
                bottomBar
            }

            Color.white
                .opacity(shutterFlash ? 0.8 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .kurnAnimation(.easeOut(duration: 0.15), value: shutterFlash)
        }
        .task { await controller.start() }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            updateIconRotation()
        }
        .onDisappear {
            countdownTask?.cancel()
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            controller.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateIconRotation()
        }
        .onChange(of: flashMode) { _, mode in controller.flashMode = mode }
    }

    // MARK: - Controls

    private var topBar: some View {
        HStack(spacing: 12) {
            if shotCount > 0 {
                Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(.black.opacity(0.4), in: Capsule())
            } else {
                Button {
                    dismiss()
                } label: {
                    controlIcon("xmark")
                }
                .accessibilityLabel(NSLocalizedString("common.cancel", comment: "Cancel"))
            }
            Spacer()
            Menu {
                Picker(NSLocalizedString("recorder.photo_flash", comment: "Flash"), selection: $flashMode) {
                    ForEach(PhotoFlashMode.allCases, id: \.self) { mode in
                        Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                    }
                }
            } label: {
                controlIcon(flashMode.systemImage)
            }
            .accessibilityLabel(NSLocalizedString("recorder.photo_flash", comment: "Flash"))
            .accessibilityValue(flashMode.displayName)
            Menu {
                Picker(NSLocalizedString("recorder.photo_timer", comment: "Timer"), selection: $timer) {
                    ForEach(PhotoTimer.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } label: {
                controlIcon(timer.systemImage)
            }
            .accessibilityLabel(NSLocalizedString("recorder.photo_timer", comment: "Timer"))
            .accessibilityValue(timer.displayName)
        }
        .padding()
    }

    private var lensRow: some View {
        let active = PhotoZoom.activeStop(in: controller.lensStops, zoomFactor: controller.zoomFactor)
        return HStack(spacing: 8) {
            ForEach(controller.lensStops, id: \.deviceFactor) { stop in
                let isActive = stop == active
                let label = isActive
                    ? PhotoZoom.label(displayFactor: controller.zoomFactor / controller.zoomBase)
                    : stop.label
                Button {
                    controller.selectLens(stop)
                } label: {
                    Text(isActive ? "\(label)×" : label)
                        .font(.system(size: isActive ? 15 : 13, weight: .semibold))
                        .foregroundStyle(isActive ? Color.yellow : .white)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.4), in: Circle())
                        .rotationEffect(.degrees(iconRotation))
                }
                .accessibilityLabel(String(
                    format: NSLocalizedString("recorder.photo_zoom_format", comment: "Zoom level, e.g. Zoom 2×"),
                    stop.label
                ))
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.black.opacity(0.25), in: Capsule())
        .kurnAnimation(.easeOut(duration: 0.2), value: controller.zoomFactor)
    }

    private var bottomBar: some View {
        HStack {
            thumbnail
                .frame(maxWidth: .infinity)
            Button(action: shutterTapped) {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 84, height: 84)
                    .overlay(Circle().fill(.white).frame(width: 68, height: 68))
            }
            .disabled(isCapturing)
            .accessibilityLabel(NSLocalizedString("recorder.photo_shutter", comment: "Take Photo"))
            Button {
                Task { await controller.switchCamera() }
            } label: {
                controlIcon("arrow.triangle.2.circlepath.camera")
            }
            .accessibilityLabel(NSLocalizedString("recorder.photo_flip", comment: "Flip Camera"))
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal)
        .padding(.bottom, 32)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let lastThumbnail {
            Image(uiImage: lastThumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.6), lineWidth: 1))
                .rotationEffect(.degrees(iconRotation))
                .accessibilityLabel(NSLocalizedString("recorder.photo_last", comment: "Last photo taken"))
        } else {
            Color.clear.frame(width: 52, height: 52)
        }
    }

    private func controlIcon(_ systemName: String) -> some View {
        // Decorative: the Button or Menu wrapping it carries the label.
        Image(systemName: systemName)
            .accessibilityHidden(true)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(.black.opacity(0.4), in: Circle())
            .rotationEffect(.degrees(iconRotation))
            .kurnAnimation(.easeOut(duration: 0.25), value: iconRotation)
    }

    // MARK: - Capture

    private func updateIconRotation() {
        if let degrees = PhotoControlRotation.degrees(for: UIDevice.current.orientation) {
            iconRotation = degrees
        }
    }

    /// Tapping while a countdown runs cancels it, like the system camera.
    private func shutterTapped() {
        if countdownTask != nil {
            countdownTask?.cancel()
            countdownTask = nil
            countdown = nil
            return
        }
        guard !isCapturing else { return }
        let seconds = timer.seconds
        guard seconds > 0 else {
            takePhoto()
            return
        }
        countdownTask = Task { @MainActor in
            for remaining in stride(from: seconds, to: 0, by: -1) {
                countdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdown = nil
            countdownTask = nil
            takePhoto()
        }
    }

    private func takePhoto() {
        isCapturing = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        shutterFlash = true
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            shutterFlash = false
        }
        controller.capturePhoto { data in
            isCapturing = false
            guard let data else { return }
            onCapture(data)
            shotCount += 1
            lastThumbnail = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 160, height: 160))
        }
    }
}

/// Tap-to-focus indicator, mirroring the system camera's yellow square, with
/// the exposure sun beside it: drag it up to brighten, down to darken.
private struct FocusControl: View {
    @Binding var exposure: Double
    /// Near the right edge the sun moves to the other side so it stays on screen.
    let sunOnLeading: Bool
    @State private var dragStart: Double?

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(.yellow, lineWidth: 1.5)
            .frame(width: 70, height: 70)
            .allowsHitTesting(false)
            .overlay(alignment: sunOnLeading ? .leading : .trailing) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.yellow)
                    .frame(width: 36, height: 36)
                    .offset(x: sunOnLeading ? -44 : 44, y: CGFloat(-exposure) * PhotoExposure.trackHeight / 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let start = dragStart ?? exposure
                                dragStart = start
                                exposure = PhotoExposure.level(afterDrag: value.translation.height, from: start)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    .accessibilityLabel(NSLocalizedString("recorder.photo_exposure", comment: "Exposure"))
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: exposure = min(1, exposure + 0.25)
                        case .decrement: exposure = max(-1, exposure - 0.25)
                        @unknown default: break
                        }
                    }
            }
    }
}

/// `UIViewRepresentable` wrapper around an `AVCaptureVideoPreviewLayer`,
/// since SwiftUI has no native camera preview view. Also hosts the pinch (zoom)
/// and tap (focus/exposure) gesture recognizers, since neither maps cleanly
/// onto SwiftUI gestures layered over a `UIViewRepresentable`'s own view.
private struct PhotoCapturePreview: UIViewRepresentable {
    let controller: PhotoCaptureController
    @Binding var focusPoint: CGPoint?

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = controller.session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        view.addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, focusPoint: $focusPoint)
    }

    @MainActor
    final class Coordinator: NSObject {
        private let controller: PhotoCaptureController
        private let focusPoint: Binding<CGPoint?>
        /// Zoom factor at the start of the current pinch, so the gesture's
        /// own `.scale` (always relative to 1 at gesture start) multiplies
        /// from wherever the camera already was.
        private var pinchStartZoom: CGFloat = 1

        init(controller: PhotoCaptureController, focusPoint: Binding<CGPoint?>) {
            self.controller = controller
            self.focusPoint = focusPoint
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                pinchStartZoom = controller.currentZoomFactor
            case .changed:
                controller.setZoom(factor: pinchStartZoom * gesture.scale)
            default:
                break
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let previewView = gesture.view as? PreviewUIView else { return }
            let location = gesture.location(in: previewView)
            let devicePoint = previewView.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: location)
            controller.focus(at: devicePoint)

            focusPoint.wrappedValue = location
            Task {
                try? await Task.sleep(for: .seconds(4))
                if focusPoint.wrappedValue == location {
                    focusPoint.wrappedValue = nil
                }
            }
        }
    }

    final class PreviewUIView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
