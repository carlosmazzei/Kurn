import Foundation
import KurnCore

#if canImport(FluidAudio)
import CoreML
import FluidAudio

extension FluidAudioDiarizationModelRuntime {
    static func loadPyannoteLocal() async throws -> OfflineDiarizerModels {
        try Task.checkCancellation()
        guard isInstalled(.pyannote) else {
            throw AppError.modelDownloadRequired(FluidAudioDiarizationModel.pyannote.displayName)
        }
        let started = Date()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        configuration.allowLowPrecisionAccumulationOnGPU = true
        let fbankConfiguration = MLModelConfiguration()
        fbankConfiguration.computeUnits = .cpuOnly
        fbankConfiguration.allowLowPrecisionAccumulationOnGPU = true
        let parametersURL = pyannoteDirectory.appendingPathComponent(ModelNames.OfflineDiarizer.pldaParameters)
        let psi = try PyannotePLDAParameters.decodePsi(Data(contentsOf: parametersURL))
        let segmentation = try loadPyannoteModel(ModelNames.OfflineDiarizer.segmentationPath, configuration: configuration)
        let fbank = try loadPyannoteModel(ModelNames.OfflineDiarizer.fbankPath, configuration: fbankConfiguration)
        let embedding = try loadPyannoteModel(ModelNames.OfflineDiarizer.embeddingPath, configuration: configuration)
        let plda = try loadPyannoteModel(ModelNames.OfflineDiarizer.pldaRhoPath, configuration: configuration)
        return OfflineDiarizerModels(
            segmentationModel: segmentation,
            fbankModel: fbank,
            embeddingModel: embedding,
            pldaRhoModel: plda,
            pldaPsi: psi,
            compilationDuration: Date().timeIntervalSince(started)
        )
    }

    private static func loadPyannoteModel(_ name: String, configuration: MLModelConfiguration) throws -> MLModel {
        try Task.checkCancellation()
        return try MLModel(contentsOf: pyannoteDirectory.appendingPathComponent(name), configuration: configuration)
    }
}
#endif
