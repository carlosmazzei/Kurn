//
//  PhotoCaptureView.swift
//  Kurn
//
//  A minimal, own-drawn camera sheet presented from `RecorderView` while a
//  recording is active. Not the system camera picker — see
//  `PhotoCaptureController`'s header for why.
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
    @State private var focusPoint: CGPoint?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PhotoCapturePreview(controller: controller, focusPoint: $focusPoint)
                .ignoresSafeArea()

            if let focusPoint {
                FocusReticle()
                    .position(focusPoint)
                    .allowsHitTesting(false)
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    .accessibilityLabel(NSLocalizedString("common.cancel", comment: "Cancel"))
                    Spacer()
                    Button {
                        flashMode = flashMode.next
                        controller.flashMode = flashMode
                    } label: {
                        Image(systemName: flashMode.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    .accessibilityLabel(NSLocalizedString("recorder.photo_flash", comment: "Flash"))
                }
                .padding()
                Spacer()
                Button {
                    guard !isCapturing else { return }
                    isCapturing = true
                    controller.capturePhoto { data in
                        isCapturing = false
                        if let data {
                            onCapture(data)
                        }
                        dismiss()
                    }
                } label: {
                    Circle()
                        .strokeBorder(.white, lineWidth: 4)
                        .frame(width: 84, height: 84)
                        .overlay(Circle().fill(.white).frame(width: 68, height: 68))
                }
                .disabled(isCapturing)
                .accessibilityLabel(NSLocalizedString("recorder.photo_shutter", comment: "Take Photo"))
                .padding(.bottom, 40)
            }
        }
        .task { await controller.start() }
        .onDisappear { controller.stop() }
    }
}

/// Brief tap-to-focus indicator, mirroring the system camera's yellow square —
/// shown for a moment at the tapped point and then faded out by the
/// coordinator that drives `focusPoint`.
private struct FocusReticle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(.yellow, lineWidth: 1.5)
            .frame(width: 70, height: 70)
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
                try? await Task.sleep(for: .seconds(1))
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
