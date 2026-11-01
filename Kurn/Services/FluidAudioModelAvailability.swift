import Foundation
import KurnCore

enum FluidAudioModelAvailability {
    static var automaticLive: Bool {
        #if canImport(FluidAudio)
        FluidAudioAutomaticStreamingRuntime.isInstalled
        #else
        false
        #endif
    }

    static func isASRInstalled(_ model: FluidAudioASRModel) -> Bool {
        #if canImport(FluidAudio)
        FluidAudioASRModelRuntime.isInstalled(model)
        #else
        false
        #endif
    }

    static func isDiarizationInstalled(_ model: FluidAudioDiarizationModel) -> Bool {
        #if canImport(FluidAudio)
        FluidAudioDiarizationModelRuntime.isInstalled(model)
        #else
        false
        #endif
    }

    static func isUnifiedStreamingInstalled() -> Bool {
        #if canImport(FluidAudio)
        FluidAudioASRModelRuntime.isUnifiedStreamingInstalled
        #else
        false
        #endif
    }
}
