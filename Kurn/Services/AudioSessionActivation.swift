//
//  AudioSessionActivation.swift
//  Kurn
//
//  The one call `AVAudioSession` itself documents as synchronous and
//  blocking: `setActive(_:options:)`. iOS 27 added a completion-handler async
//  variant (`activate(options:completionHandler:)`), but the app's floor is
//  iOS 26.0 and the project does not branch on `#available` for a pre-26
//  fallback, so that API is out of reach.
//
//  The fix available at 26.0 is the one `AudioRecorderService.setUpEngine`
//  already relies on for the rest of session setup: a plain function with no
//  actor isolation of its own. Calling it with `await` from `@MainActor` code
//  hops execution onto the cooperative thread pool for the duration of the
//  call instead of blocking the caller's thread — which is exactly what the
//  OS's "This method can lead to UI unresponsiveness" console warning is
//  asking for, without needing the iOS 27 API.
//

import AVFoundation

enum AudioSessionActivation {
    static func setActive(
        _ active: Bool,
        options: AVAudioSession.SetActiveOptions = []
    ) async throws {
        try AVAudioSession.sharedInstance().setActive(active, options: options)
    }
}
