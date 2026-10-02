//
//  CaptureInputSelection.swift
//  Kurn
//
//  The decisions behind a recording's audio session — which input captures,
//  whether that input needs an output route, which polar pattern the built-in
//  mic is steered to, and how activation is retried — kept apart from
//  `AVAudioSession` so they are testable without real hardware.
//  `CaptureAudioSession` applies them to the shared session.
//

import AVFoundation
import Foundation

/// Pure decision of which input a recording uses, kept apart from
/// `AVAudioSession` so it is testable without real hardware.
enum CaptureInputSelection: Equatable, Sendable {
    /// The iPhone's own microphone, identified by its port UID.
    case builtIn(uid: String)
    /// An explicitly chosen external input (Bluetooth, wired, USB).
    case external(uid: String)
    /// Leave the route to the system (an accessory is connected and nothing
    /// asked for a specific input).
    case systemDefault

    struct Input: Equatable, Sendable {
        let uid: String
        let isBuiltIn: Bool
    }

    /// Priority: an explicit `preferredInputUID` (from the per-recording
    /// microphone picker) always wins. Otherwise the built-in mic is selected
    /// when `forceBuiltIn` is set (Settings → always use the iPhone mic) or no
    /// external input exists; with an accessory connected and no preference,
    /// the system's own route choice is left alone.
    static func resolve(
        inputs: [Input],
        forceBuiltIn: Bool,
        preferredInputUID: String?
    ) -> CaptureInputSelection {
        if let uid = preferredInputUID, let match = inputs.first(where: { $0.uid == uid }) {
            return match.isBuiltIn ? .builtIn(uid: match.uid) : .external(uid: match.uid)
        }
        guard let builtIn = inputs.first(where: \.isBuiltIn) else { return .systemDefault }
        let hasExternal = inputs.contains { !$0.isBuiltIn }
        return forceBuiltIn || !hasExternal ? .builtIn(uid: builtIn.uid) : .systemDefault
    }

    /// Whether the session needs an output route (and Bluetooth HFP) for this
    /// input. Only the built-in mic can capture without one.
    var needsPlayAndRecord: Bool {
        if case .builtIn = self { return false }
        return true
    }

    /// Polar patterns to try on the built-in mic, in order: whole-room favours
    /// an omnidirectional pickup (every participant), focus-speaker favours
    /// cardioid (the person in front). Both fall back to subcardioid, then to
    /// the hardware default when none is supported.
    static func preferredPolarPatterns(for pickup: MicPickup) -> [AVAudioSession.PolarPattern] {
        switch pickup {
        case .wholeRoom: return [.omnidirectional, .subcardioid]
        case .focusSpeaker: return [.cardioid, .subcardioid]
        }
    }
}

/// Activation with a short retry/backoff. Requesting `.playAndRecord` while a
/// Bluetooth headset is connected forces the accessory to switch profile
/// (A2DP/idle → HFP), an asynchronous radio handshake that can make
/// `setActive(true)` throw transiently while it's in flight. A brief retry
/// rides out that window instead of failing the whole recording start on the
/// first attempt; the last attempt's error is the one thrown.
enum SessionActivationRetry {
    static func run(
        attempts: Int = 3,
        delayNanoseconds: UInt64 = 200_000_000,
        _ operation: () throws -> Void,
        onRetry: (Int, Error) -> Void = { _, _ in }
    ) async throws {
        for attempt in 1...max(1, attempts) {
            do {
                try operation()
                return
            } catch {
                if attempt >= attempts { throw error }
                onRetry(attempt, error)
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
    }
}
