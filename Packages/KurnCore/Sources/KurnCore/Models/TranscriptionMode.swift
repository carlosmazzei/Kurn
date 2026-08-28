//
//  TranscriptionMode.swift
//  KurnCore
//
//  Where a transcript is produced.
//

import Foundation

public enum TranscriptionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case onDevice
    case whisperAPI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .onDevice: return NSLocalizedString("mode.on_device", comment: "On-device")
        case .whisperAPI: return NSLocalizedString("mode.whisper", comment: "Whisper API")
        }
    }
}
