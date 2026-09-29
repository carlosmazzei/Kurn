//
//  CaptureEnums.swift
//  Kurn
//
//  Recording capture preferences: microphone pickup and audio quality.
//

import Foundation
import KurnCore

/// Microphone pickup pattern preference for the built-in mic.
enum MicPickup: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Omnidirectional: capture the whole room / all participants.
    case wholeRoom
    /// Cardioid (directional): favour the person in front of the device.
    case focusSpeaker

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wholeRoom: return NSLocalizedString("micpickup.whole_room", comment: "Whole room")
        case .focusSpeaker: return NSLocalizedString("micpickup.focus_speaker", comment: "Focus on speaker")
        }
    }
}

/// Recording audio quality, mapped to the encoder bit rate.
///
/// Every tier records at the same speech-optimized sample rate (see
/// `AudioRecorderService.storageSampleRate`), so the tiers differ only in bit
/// rate. That pairing is what makes even the lowest tier clean: the encoder
/// spends its budget on a 12kHz band instead of spreading it over the mic's
/// full 24kHz, which is what used to make the low tier sound artefacted.
enum AudioQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case high
    case standard
    case low

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .high: return NSLocalizedString("quality.high", comment: "High")
        case .standard: return NSLocalizedString("quality.standard", comment: "Standard")
        case .low: return NSLocalizedString("quality.low", comment: "Low")
        }
    }

    /// AAC bit rate (bits per second) for the recorder. Tuned for mono speech at
    /// `AudioRecorderService.storageSampleRate` — 48 kbps is transparent for
    /// voice there, so `.standard` is the default and `.high` is headroom.
    var bitRate: Int {
        switch self {
        case .high: return 64_000
        case .standard: return 48_000
        case .low: return 32_000
        }
    }

    /// Approximate bytes one hour of recording occupies at this tier. Constant
    /// bit rate makes this exact enough to show in Settings.
    var approximateBytesPerHour: Int64 {
        Int64(bitRate) / 8 * 3600
    }
}
