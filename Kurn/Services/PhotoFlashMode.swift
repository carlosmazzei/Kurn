//
//  PhotoFlashMode.swift
//  Kurn
//
//  The decisions behind the in-recording camera's controls, kept apart from
//  `PhotoCaptureController` (an `AVCaptureSession` adapter the simulator has
//  no camera for) so they are tested: the flash and timer choices, which lens
//  buttons to offer and how far a pinch may zoom, the exposure slider's
//  mapping, and how the controls counter-rotate with the phone.
//

import CoreGraphics
import Foundation
import UIKit

/// Flash mode cycled by the shutter screen's flash toggle. Named to match
/// `AVCaptureDevice.FlashMode`, which this maps directly onto — kept as its
/// own type so the view layer doesn't need to import AVFoundation.
enum PhotoFlashMode: CaseIterable {
    case auto, on, off

    var displayName: String {
        switch self {
        case .auto: return NSLocalizedString("recorder.photo_auto", comment: "Flash mode: automatic")
        case .on: return NSLocalizedString("recorder.photo_on", comment: "Flash mode: always on")
        case .off: return NSLocalizedString("recorder.photo_off", comment: "Flash / timer: off")
        }
    }

    var systemImage: String {
        switch self {
        case .auto: return "bolt.badge.a.fill"
        case .on: return "bolt.fill"
        case .off: return "bolt.slash.fill"
        }
    }

    var next: PhotoFlashMode {
        switch self {
        case .auto: return .on
        case .on: return .off
        case .off: return .auto
        }
    }
}

/// Self-timer delay chosen from the shutter screen's timer menu.
enum PhotoTimer: CaseIterable {
    case off, three, ten

    var seconds: Int {
        switch self {
        case .off: return 0
        case .three: return 3
        case .ten: return 10
        }
    }

    var displayName: String {
        switch self {
        case .off: return NSLocalizedString("recorder.photo_off", comment: "Flash / timer: off")
        case .three, .ten:
            return String(format: NSLocalizedString("recorder.photo_timer_seconds", comment: "Timer delay, e.g. 3 s"), seconds)
        }
    }

    var systemImage: String { self == .off ? "timer" : "timer.circle.fill" }
}

/// One lens button of the zoom row (0.5x / 1x / 2x / 3x on a multi-camera
/// phone). `deviceFactor` is what `AVCaptureDevice.videoZoomFactor` takes;
/// `displayFactor` is what the user reads — they differ on phones with an
/// ultra-wide, where device factor 1 is the 0.5x lens and the main camera
/// starts at 2.
struct PhotoLensStop: Equatable {
    let deviceFactor: CGFloat
    let displayFactor: CGFloat

    var label: String { PhotoZoom.label(displayFactor: displayFactor) }
}

enum PhotoZoom {
    /// This is a quick context capture, not a photography app, and digital
    /// zoom past a handful of times over softens text (the main reason to zoom
    /// here — reading a distant whiteboard) rather than helping it.
    static let ceiling: CGFloat = 6

    /// The zoom a pinch may reach: the device's own ceiling, capped at 6x.
    ///
    /// `base` is the device factor of the main (1x) lens: the ceiling is six
    /// times *that*, not six times the ultra-wide.
    static func maxFactor(deviceMax: CGFloat, base: CGFloat = 1) -> CGFloat {
        min(deviceMax, ceiling * base)
    }

    /// A requested zoom factor clamped to `1...maxFactor(deviceMax:)`.
    static func clamp(_ factor: CGFloat, deviceMax: CGFloat, base: CGFloat = 1) -> CGFloat {
        max(1, min(factor, maxFactor(deviceMax: deviceMax, base: base)))
    }

    /// Device zoom factor of the main camera: the first lens switch-over on a
    /// virtual device that includes an ultra-wide, otherwise 1.
    static func mainLensFactor(switchOverFactors: [CGFloat], hasUltraWide: Bool) -> CGFloat {
        hasUltraWide ? (switchOverFactors.first ?? 1) : 1
    }

    /// The lens buttons to offer: every physical lens, plus a 2x crop when the
    /// phone has no 2x telephoto, within the zoom ceiling.
    static func lensStops(switchOverFactors: [CGFloat], hasUltraWide: Bool, deviceMax: CGFloat) -> [PhotoLensStop] {
        let base = mainLensFactor(switchOverFactors: switchOverFactors, hasUltraWide: hasUltraWide)
        var factors: [CGFloat] = [1] + switchOverFactors
        if !factors.contains(where: { abs($0 / base - 2) < 0.1 }) {
            factors.append(2 * base)
        }
        let limit = maxFactor(deviceMax: deviceMax, base: base)
        return factors.sorted()
            .filter { $0 <= limit + 0.001 }
            .map { PhotoLensStop(deviceFactor: $0, displayFactor: $0 / base) }
    }

    /// The button that reads as selected at `zoomFactor`: the last lens at or
    /// below it, like the system camera.
    static func activeStop(in stops: [PhotoLensStop], zoomFactor: CGFloat) -> PhotoLensStop? {
        stops.last { $0.deviceFactor <= zoomFactor + 0.01 } ?? stops.first
    }

    static func label(displayFactor: CGFloat) -> String {
        let rounded = (displayFactor * 10).rounded() / 10
        return Double(rounded).formatted(.number.precision(.fractionLength(0...1)))
    }
}

/// The exposure slider next to the focus reticle: a drag on the sun maps to an
/// exposure bias, bounded well inside what a snapshot of a whiteboard needs.
enum PhotoExposure {
    /// Largest bias, in EV, either way.
    static let range: Float = 2
    /// Height of the sun's track, in points; half of it is a full deflection.
    static let trackHeight: CGFloat = 100

    /// Slider level (-1...1) after dragging `translation` points down from `start`.
    static func level(afterDrag translation: CGFloat, from start: Double) -> Double {
        max(-1, min(1, start - Double(translation / (trackHeight / 2))))
    }

    /// EV bias for a slider level, within the device's own limits.
    static func bias(level: Double, deviceMin: Float, deviceMax: Float) -> Float {
        let requested = Float(max(-1, min(1, level))) * range
        return max(max(deviceMin, -range), min(requested, min(deviceMax, range)))
    }
}

/// Icon rotation that keeps the controls upright while the (portrait-locked)
/// interface stays put and the phone turns, as the system camera does.
enum PhotoControlRotation {
    /// Degrees to rotate the icons for `orientation`, or `nil` to keep the
    /// current angle (flat, unknown, upside down).
    static func degrees(for orientation: UIDeviceOrientation) -> Double? {
        switch orientation {
        case .portrait: return 0
        case .landscapeLeft: return 90
        case .landscapeRight: return -90
        default: return nil
        }
    }
}
