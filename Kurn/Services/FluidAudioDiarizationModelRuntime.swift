import Foundation
import KurnCore

#if canImport(FluidAudio)
import FluidAudio
#endif

enum FluidAudioDiarizationModelRuntime {
    static var nemotronDirectory: URL {
        ModelStore.modelsDirectory.appendingPathComponent(FluidAudioDiarizationModel.nemotron3.folderName)
    }

    static func isInstalled(_ model: FluidAudioDiarizationModel) -> Bool {
        #if canImport(FluidAudio)
        switch model {
        case .pyannote:
            return PyannoteDiarizationCache.isInstalled(pyannoteCacheManifest)
        case .nemotron3:
            let config = Nemotron3Config.fast32
            let directory = nemotronDirectory
            let manifest = directory.appendingPathComponent(config.hubSubdirectory)
                .appendingPathComponent(config.modelFileName).appendingPathComponent("coremldata.bin")
            let marker = directory.appendingPathComponent(ModelNames.Nemotron3.weightsVersionFile)
            let silence = directory.appendingPathComponent(ModelNames.Nemotron3.silenceEmbeddingFile)
            let attributes = try? FileManager.default.attributesOfItem(atPath: silence.path)
            return NemotronDiarizationPolicy.isInstalled(
                cachedVersion: try? String(contentsOf: marker, encoding: .utf8),
                expectedVersion: ModelNames.Nemotron3.weightsVersion,
                hasCompiledManifest: FileManager.default.fileExists(atPath: manifest.path),
                silenceEmbeddingByteCount: (attributes?[.size] as? NSNumber)?.intValue
            )
        }
        #else
        return false
        #endif
    }

    #if canImport(FluidAudio)
    static var pyannoteDirectory: URL {
        ModelStore.modelsDirectory.appendingPathComponent(Repo.diarizer.folderName)
    }

    static var pyannoteCacheManifest: PyannoteDiarizationCache.Manifest {
        PyannoteDiarizationCache.Manifest(
            directory: pyannoteDirectory,
            compiledModels: [
                ModelNames.OfflineDiarizer.segmentationPath, ModelNames.OfflineDiarizer.fbankPath,
                ModelNames.OfflineDiarizer.embeddingPath, ModelNames.OfflineDiarizer.pldaRhoPath
            ],
            parametersFile: ModelNames.OfflineDiarizer.pldaParameters,
            expectedRevision: Repo.diarizer.revision
        )
    }
    #endif
}
