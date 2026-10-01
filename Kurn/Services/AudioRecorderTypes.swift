//
//  AudioRecorderTypes.swift
//  Kurn
//
//  The values `AudioRecorderService` hands its callers: what a finished
//  recording produced, a buffered photo, the recorder state and why it paused.
//  Split out of `AudioRecorderService.swift` to keep it under SwiftLint's
//  file-length limit.
//

import Foundation
import KurnCore

struct AudioRecordingResult {
    let fileName: String
    let duration: TimeInterval
    let highlights: [Highlight]
    let photos: [CapturedPhotoRecord]
    let captureFailure: AudioSinkFailure?
}

/// A photo captured mid-recording, buffered in memory (the file itself is
/// already durably written by `PhotoFileStore` at capture time) until
/// `stop()` hands it to `RecorderViewModel` for persistence as a
/// `MeetingPhoto`, mirroring how `Highlight` is buffered here and persisted
/// to `Recording.highlights` at finalize.
struct CapturedPhotoRecord {
    let id: UUID
    let fileName: String
    let capturedAt: TimeInterval
    let createdAt: Date
}

enum AudioRecorderState: Equatable {
    case idle
    case recording
    case paused
}

/// Why `pause()` was invoked. Attached to the diagnostic log line so
/// Console / exported logs show WHY a recording paused — especially for
/// the automatic triggers that fire without any user interaction.
enum AudioRecorderPauseReason: String {
    case userToggle = "user toggled pause (in-app button or Live Activity pill)"
    case watchCommand = "Watch app pause command"
    case audioInterruption = "audio session interruption began"
    case engineRecoveryFailed = "engine recovery failed (tap rebuild after format change)"
    case engineRestartFailed = "engine recovery failed (engine.start() after rebuild)"
    case routeChanged = "input route became unavailable (oldDeviceUnavailable)"
    case sinkFailure = "audio conversion or file write failed"
    case captureStalled = "no output frames reached the recording file"
}
