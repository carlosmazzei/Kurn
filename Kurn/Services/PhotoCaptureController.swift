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
import Observation

extension PhotoFlashMode {
    fileprivate var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .auto: return .auto
        case .on: return .on
        case .off: return .off
        }
    }
}

@MainActor @Observable
final class PhotoCaptureController: NSObject {
    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let output = AVCapturePhotoOutput()
    /// Set once configuration finishes, back on the main actor — the pinch
    /// and tap gesture handlers read/lock it for zoom and focus/exposure.
    @ObservationIgnored private var device: AVCaptureDevice?
    /// Tracks how the phone is physically held. The app UI is portrait-only, so
    /// the interface never rotates and the capture connection would otherwise
    /// always write portrait pixels, even with the phone lying on its side.
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var isConfigured = false
    @ObservationIgnored private var isSwitching = false
    @ObservationIgnored private var captureCompletion: ((Data?) -> Void)?
    @ObservationIgnored var flashMode: PhotoFlashMode = .auto

    private(set) var position: AVCaptureDevice.Position = .back
    /// Lens buttons for the current camera; empty (row hidden) on the front
    /// camera or a phone with a single lens.
    private(set) var lensStops: [PhotoLensStop] = []
    /// Device zoom factor of the main (1x) lens; see `PhotoZoom.lensStops`.
    private(set) var zoomBase: CGFloat = 1
    private(set) var zoomFactor: CGFloat = 1
    /// Exposure slider level, -1...1; reset by every focus tap.
    private(set) var exposureLevel: Double = 0

    /// The device's current zoom, so a new pinch gesture can scale from
    /// wherever the last one left off instead of resetting to 1x.
    var currentZoomFactor: CGFloat {
        device?.videoZoomFactor ?? 1
    }

    /// Configure and start the session off-main, then resume on the main
    /// actor. Safe to call more than once (e.g. `onAppear` firing twice).
    func start() async {
        guard !isConfigured else {
            if !session.isRunning { await Task.detached(priority: .userInitiated) { [session] in session.startRunning() }.value }
            return
        }
        isConfigured = true
        await attach(position: .back)
    }

    func stop() {
        guard session.isRunning else { return }
        let session = self.session
        Task.detached(priority: .utility) { session.stopRunning() }
    }

    /// Swap between the back and front cameras.
    func switchCamera() async {
        guard isConfigured, !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }
        await attach(position: position == .back ? .front : .back)
    }

    private func attach(position: AVCaptureDevice.Position) async {
        let session = self.session
        let output = self.output
        let configuredDevice = await Task.detached(priority: .userInitiated) { () -> AVCaptureDevice? in
            let added = Self.attachInput(position: position, session: session, output: output)
            if !session.isRunning { session.startRunning() }
            return added
        }.value
        adopt(configuredDevice, position: position)
    }

    /// The back camera is the virtual multi-camera when the phone has one, so
    /// the zoom row can move between the ultra-wide, main and telephoto lenses.
    nonisolated private static func discoverDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position)
            .devices.first
    }

    nonisolated private static func attachInput(
        position: AVCaptureDevice.Position,
        session: AVCaptureSession,
        output: AVCapturePhotoOutput
    ) -> AVCaptureDevice? {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        for input in session.inputs {
            session.removeInput(input)
        }
        var addedDevice: AVCaptureDevice?
        if let device = discoverDevice(position: position),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            addedDevice = device
        }
        if !session.outputs.contains(output), session.canAddOutput(output) {
            session.addOutput(output)
        }
        return addedDevice
    }

    private func adopt(_ newDevice: AVCaptureDevice?, position: AVCaptureDevice.Position) {
        device = newDevice
        self.position = position
        exposureLevel = 0
        rotationCoordinator = newDevice.map { AVCaptureDevice.RotationCoordinator(device: $0, previewLayer: nil) }
        guard let newDevice else {
            lensStops = []
            zoomBase = 1
            zoomFactor = 1
            return
        }
        let hasUltraWide = newDevice.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let switchOvers = newDevice.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        zoomBase = position == .back
            ? PhotoZoom.mainLensFactor(switchOverFactors: switchOvers, hasUltraWide: hasUltraWide)
            : 1
        lensStops = position == .back
            ? PhotoZoom.lensStops(
                switchOverFactors: switchOvers,
                hasUltraWide: hasUltraWide,
                deviceMax: newDevice.activeFormat.videoMaxZoomFactor
            )
            : []
        // A virtual camera starts on its ultra-wide; open on the main lens.
        setZoom(factor: zoomBase)
    }

    /// Set the zoom factor directly (not relative to the current value —
    /// callers scale from `currentZoomFactor` themselves, e.g. a pinch
    /// gesture multiplying it by the gesture's own scale), clamped to
    /// `1...` the zoom ceiling.
    func setZoom(factor: CGFloat) {
        guard let device else { return }
        let clamped = PhotoZoom.clamp(factor, deviceMax: device.activeFormat.videoMaxZoomFactor, base: zoomBase)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            zoomFactor = clamped
        } catch {
            AppLog.recorderUI.atDebug.debug(
                "PhotoCaptureController: zoom lock failed code=\(error.publicLogCode, privacy: .public)"
            )
        }
    }

    /// Ramp to a lens button's zoom, as a tap on 0.5x / 1x / 2x does in the
    /// system camera.
    func selectLens(_ stop: PhotoLensStop) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            device.ramp(toVideoZoomFactor: stop.deviceFactor, withRate: 8)
            device.unlockForConfiguration()
            zoomFactor = stop.deviceFactor
        } catch {
            AppLog.recorderUI.atDebug.debug(
                "PhotoCaptureController: lens lock failed code=\(error.publicLogCode, privacy: .public)"
            )
        }
    }

    /// Focus and expose at `point`, in the device's normalized (0...1, top-left
    /// origin) coordinate space — the preview layer converts a tap's screen
    /// location into this space before calling in. Resets the exposure bias.
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
            device.setExposureTargetBias(0)
            device.unlockForConfiguration()
            exposureLevel = 0
        } catch {
            AppLog.recorderUI.atDebug.debug(
                "PhotoCaptureController: focus lock failed code=\(error.publicLogCode, privacy: .public)"
            )
        }
    }

    /// Apply the exposure slider's level (-1...1) as an EV bias.
    func setExposureLevel(_ level: Double) {
        guard let device else { return }
        let clamped = max(-1, min(1, level))
        let bias = PhotoExposure.bias(
            level: clamped,
            deviceMin: device.minExposureTargetBias,
            deviceMax: device.maxExposureTargetBias
        )
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(bias)
            device.unlockForConfiguration()
            exposureLevel = clamped
        } catch {
            AppLog.recorderUI.atDebug.debug(
                "PhotoCaptureController: exposure lock failed code=\(error.publicLogCode, privacy: .public)"
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
        if let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
           let connection = output.connection(with: .video),
           connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
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
