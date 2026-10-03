//
//  PhotoFlashMode.swift
//  Kurn
//
//  The decisions behind the in-recording camera's controls, kept apart from
//  `PhotoCaptureController` (an `AVCaptureSession` adapter the simulator has
//  no camera for) so they are tested: the flash toggle's cycle and icon, and
//  how far a pinch may zoom.
//

import CoreGraphics
import Foundation

/// Flash mode cycled by the shutter screen's flash toggle. Named to match
/// `AVCaptureDevice.FlashMode`, which this maps directly onto — kept as its
/// own type so the view layer doesn't need to import AVFoundation.
enum PhotoFlashMode: CaseIterable {
    case auto, on, off

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

enum PhotoZoom {
    /// This is a quick context capture, not a photography app, and digital
    /// zoom past a handful of times over softens text (the main reason to zoom
    /// here — reading a distant whiteboard) rather than helping it.
    static let ceiling: CGFloat = 6

    /// The zoom a pinch may reach: the device's own ceiling, capped at 6x.
    static func maxFactor(deviceMax: CGFloat) -> CGFloat {
        min(deviceMax, ceiling)
    }

    /// A requested zoom factor clamped to `1...maxFactor(deviceMax:)`.
    static func clamp(_ factor: CGFloat, deviceMax: CGFloat) -> CGFloat {
        max(1, min(factor, maxFactor(deviceMax: deviceMax)))
    }
}
