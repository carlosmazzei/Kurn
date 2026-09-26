//
//  CaptureAudioSession.swift
//  Kurn
//
//  Audio-session setup for a recording: which physical input captures, and
//  which session category that input needs.
//
//  The category is the part that matters to anyone wearing hearing aids (or
//  Bluetooth earbuds). `.playAndRecord` opens an output route as well as an
//  input one, and iOS sends that output to the connected hearing device, which
//  switches it into its streaming program — attenuating or muting its own
//  microphones for the whole meeting — even though the recording is taken
//  from the iPhone's mic and the app never plays a sound. So when the built-in
//  mic is the input, the session is `.record`: no output route, nothing for
//  the hearing device to stream, and no Bluetooth profile switch either.
//  `.playAndRecord` with Bluetooth HFP is kept only for an external input,
//  where the accessory has to be routed anyway.
//

import AVFoundation
import Foundation
import KurnCore
import os

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
}

enum CaptureAudioSession {
    static func configure(
        pickup: MicPickup,
        forceBuiltIn: Bool,
        preferredInputUID: String?
    ) async throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // `availableInputs` only lists a Bluetooth accessory while the
            // category allows Bluetooth HFP, so the inputs are enumerated under
            // that category (not yet active: nothing is routed by this).
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            let ports = session.availableInputs ?? []
            let selection = CaptureInputSelection.resolve(
                inputs: ports.map { .init(uid: $0.uid, isBuiltIn: $0.portType == .builtInMic) },
                forceBuiltIn: forceBuiltIn,
                preferredInputUID: preferredInputUID
            )
            if !selection.needsPlayAndRecord {
                try session.setCategory(.record, mode: .default, options: [])
            }
            try await activate(session)
            selectInput(selection, in: session, pickup: pickup)
            let route = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
            AppLog.recorder.atDebug.debug(
                "configureSession: active category=\(session.category.rawValue, privacy: .public) route=\(route, privacy: .public) sampleRate=\(session.sampleRate, privacy: .public)"
            )
        } catch {
            AppLog.recorder.atError.error("configureSession: failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            throw AppError.audioError(error.localizedDescription)
        }
    }

    /// Activate the session with a short retry/backoff. Requesting
    /// `.playAndRecord` while a Bluetooth headset is connected forces the
    /// accessory to switch profile (A2DP/idle → HFP), an asynchronous radio
    /// handshake that can make `setActive(true)` throw transiently while it's
    /// in flight. A brief retry rides out that window instead of failing the
    /// whole recording start on the first attempt.
    private static func activate(_ session: AVAudioSession, attempts: Int = 3) async throws {
        for attempt in 1...attempts {
            do {
                try session.setActive(true)
                return
            } catch {
                if attempt == attempts { throw error }
                AppLog.recorder.atInfo.info("activateSession: attempt \(attempt, privacy: .public) failed, retrying code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// Apply the resolved input, re-reading the ports because the category
    /// switch above changes what `availableInputs` lists; then, for the
    /// built-in mic only, steer its polar pattern.
    private static func selectInput(
        _ selection: CaptureInputSelection,
        in session: AVAudioSession,
        pickup: MicPickup
    ) {
        let uid: String
        switch selection {
        case .systemDefault: return
        case .builtIn(let builtInUID): uid = builtInUID
        case .external(let externalUID): uid = externalUID
        }
        guard let port = session.availableInputs?.first(where: { $0.uid == uid }) else { return }
        try? session.setPreferredInput(port)
        if port.portType == .builtInMic {
            applyPolarPattern(to: port, pickup: pickup)
        }
    }

    /// Steer the built-in mic's polar pattern according to `micPickup`:
    /// whole-room favours an omnidirectional pickup (every participant), while
    /// focus-speaker favours cardioid (the person in front). Both fall back to
    /// subcardioid, then the hardware default.
    private static func applyPolarPattern(to builtIn: AVAudioSessionPortDescription, pickup: MicPickup) {
        guard let sources = builtIn.dataSources, !sources.isEmpty else { return }

        // Try patterns in priority order for the chosen pickup mode; apply the
        // first one the hardware actually supports.
        let preferredPatterns: [AVAudioSession.PolarPattern] = pickup == .wholeRoom
            ? [.omnidirectional, .subcardioid]
            : [.cardioid, .subcardioid]

        for pattern in preferredPatterns {
            guard let source = sources.first(where: {
                $0.supportedPolarPatterns?.contains(pattern) == true
            }) else { continue }
            try? source.setPreferredPolarPattern(pattern)
            try? builtIn.setPreferredDataSource(source)
            AppLog.recorder.atDebug.debug("configureMicrophone: pickup=\(pickup.rawValue, privacy: .public) pattern=\(pattern.rawValue, privacy: .public) source=\(source.dataSourceName, privacy: .public)")
            return
        }
        AppLog.recorder.atDebug.debug("configureMicrophone: pickup=\(pickup.rawValue, privacy: .public) hardware default pattern (no preferred pattern available)")
    }
}
