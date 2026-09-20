//
//  TranscriptionEngine+ModelSet.swift
//  Kurn
//
//  Adds back the one member of `TranscriptionEngine` that couldn't move to
//  KurnCore with the rest of the enum: `ModelSet` (`ModelDownloadConsent.swift`)
//  orchestrates actual FluidAudio/whisper.cpp downloads and isn't portable, so
//  this stays app-side as an extension on the KurnCore-defined enum.
//

import Foundation
import KurnCore

extension TranscriptionEngine {
    /// Model family that must be downloaded before this engine runs, or `nil`
    /// when it needs no download.
    ///
    /// Unlike the other stage enums this is a function, because whisper.cpp has
    /// a variant axis: the set has to name *which* weight file to fetch, and a
    /// defaulted parameter would let a caller silently download the wrong one.
    func requiredModelSet(whisperCppModel: WhisperCppModel) -> ModelSet? {
        switch self {
        case .appleSpeech, .whisperAPI: return nil
        case .fluidAudioParakeet: return .onDeviceASR
        case .whisperCpp: return .whisperCppASR(whisperCppModel)
        }
    }
}
