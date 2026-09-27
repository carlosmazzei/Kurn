//
//  PhotoCaptureController.swift
//  Kurn
//
//  Minimal, video-only `AVCaptureSession` wrapper for the in-recording photo
//  button. Deliberately not `UIImagePickerController`/`PHPickerViewController`:
//  either could reconfigure the app's already-active `AVAudioSession`
//  (`CaptureAudioSession`) mid-recording, which must not happen. This session
//  carries no audio input at all, so it cannot touch the recording's audio
//  session category.
//

import AVFoundation
import Foundation

@MainActor
final class PhotoCaptureController: NSObject {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var isConfigured = false
    private var captureCompletion: ((Data?) -> Void)?

    /// Configure and start the session off-main, then resume on the main
    /// actor. Safe to call more than once (e.g. `onAppear` firing twice).
    func start() async {
        guard !isConfigured else {
            if !session.isRunning { await Task.detached(priority: .userInitiated) { [session] in session.startRunning() }.value }
            return
        }
        isConfigured = true
        let session = self.session
        let output = self.output
        await Task.detached(priority: .userInitiated) {
            session.beginConfiguration()
            session.sessionPreset = .photo
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            }
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            session.commitConfiguration()
            session.startRunning()
        }.value
    }

    func stop() {
        guard session.isRunning else { return }
        let session = self.session
        Task.detached(priority: .utility) { session.stopRunning() }
    }

    /// Capture a single JPEG. `completion` is called on the main actor with
    /// the JPEG bytes, or `nil` on any failure.
    func capturePhoto(completion: @escaping (Data?) -> Void) {
        captureCompletion = completion
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
    }
}

extension PhotoCaptureController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        Task { @MainActor in
            self.captureCompletion?(data)
            self.captureCompletion = nil
        }
    }
}
