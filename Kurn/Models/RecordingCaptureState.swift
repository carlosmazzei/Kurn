import Foundation

enum RecordingCaptureState: String, Codable, Sendable {
    case preparing
    case recording
    case finalizing
    case ready
    case recoveryNeeded
}

enum CaptureRecoveryReason: String, Codable, Sendable {
    case interruptedBeforeStart
    case interruptedDuringCapture
    case interruptedDuringFinalization
    case conversionFailed
    case writeFailed
    case finalDrainFailed
    case frameProgressStalled
    case fileMissing
    case emptyFile
    case unreadableFile
    case invalidDuration
    case protectionFailed

    init(_ failure: AudioSinkFailure) {
        switch failure {
        case .conversion: self = .conversionFailed
        case .write: self = .writeFailed
        case .finalDrain: self = .finalDrainFailed
        case .stalled: self = .frameProgressStalled
        }
    }
}
