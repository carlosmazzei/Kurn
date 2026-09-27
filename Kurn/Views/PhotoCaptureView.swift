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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PhotoCapturePreview(session: controller.session)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
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
                    .padding()
                }
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

/// `UIViewRepresentable` wrapper around an `AVCaptureVideoPreviewLayer`,
/// since SwiftUI has no native camera preview view.
private struct PhotoCapturePreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
