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

// `AVCaptureSession`/`AVCapturePhotoOutput` predate Swift 6 Sendable auditing,
// so passing them into a `Task.detached` closure needs the same
// `@preconcurrency` treatment `VADAudioCompactor.swift` already uses for
// `AVAudioEngine`.
@preconcurrency import AVFoundation
import Foundation

extension PhotoFlashMode {
    fileprivate var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .auto: return .auto
        case .on: return .on
        case .off: return .off
        }
    }
}

@MainActor
final class PhotoCaptureController: NSObject {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    /// Set once configuration finishes, back on the main actor — the pinch
    /// and tap gesture handlers read/lock it for zoom and focus/exposure.
    private var device: AVCaptureDevice?
    private var isConfigured = false
    private var captureCompletion: ((Data?) -> Void)?
    var flashMode: PhotoFlashMode = .auto

    /// The device's current zoom, so a new pinch gesture can scale from
    /// wherever the last one left off instead of resetting to 1x.
    var currentZoomFactor: CGFloat {
        device?.videoZoomFactor ?? 1
    }

    /// See `PhotoZoom.maxFactor(deviceMax:)`.
    var maxZoomFactor: CGFloat {
        PhotoZoom.maxFactor(deviceMax: device?.activeFormat.videoMaxZoomFactor ?? 1)
    }

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
        let configuredDevice = await Task.detached(priority: .userInitiated) { () -> AVCaptureDevice? in
            session.beginConfiguration()
            session.sessionPreset = .photo
            var addedDevice: AVCaptureDevice?
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
                addedDevice = device
            }
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            session.commitConfiguration()
            session.startRunning()
            return addedDevice
        }.value
        device = configuredDevice
    }

    func stop() {
        guard session.isRunning else { return }
        let session = self.session
        Task.detached(priority: .utility) { session.stopRunning() }
    }

    /// Set the zoom factor directly (not relative to the current value —
    /// callers scale from `currentZoomFactor` themselves, e.g. a pinch
    /// gesture multiplying it by the gesture's own scale), clamped to
    /// `1...maxZoomFactor`.
    func setZoom(factor: CGFloat) {
        guard let device else { return }
        let clamped = PhotoZoom.clamp(factor, deviceMax: device.activeFormat.videoMaxZoomFactor)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        } catch {
            AppLog.recorderUI.atDebug.debug(
                "PhotoCaptureController: zoom lock failed code=\(error.publicLogCode, privacy: .public)"
            )
        }
    }

    /// Focus and expose at `point`, in the device's normalized (0...1, top-left
    /// origin) coordinate space — the preview layer converts a tap's screen
    /// location into this space before calling in.
    func focus(at point: CGPoint) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()
        } catch {
            AppLog.recorderUI.atDebug.debug(
                "PhotoCaptureController: focus lock failed code=\(error.publicLogCode, privacy: .public)"
            )
        }
    }

    /// Capture a single JPEG. `completion` is called on the main actor with
    /// the JPEG bytes, or `nil` on any failure.
    func capturePhoto(completion: @escaping (Data?) -> Void) {
        captureCompletion = completion
        let settings = AVCapturePhotoSettings()
        if output.supportedFlashModes.contains(flashMode.avFlashMode) {
            settings.flashMode = flashMode.avFlashMode
        }
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
