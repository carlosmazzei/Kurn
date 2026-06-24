//
//  ModelStore.swift
//  Kurn
//
//  On-disk management of FluidAudio's downloaded CoreML models. FluidAudio caches
//  each model under `Application Support/FluidAudio/Models/<repo folder>`; this
//  lets Settings show how much space each model group uses and delete it to
//  reclaim storage. Deleted models are re-downloaded on demand the next time the
//  feature is enabled (the existing consent/toggle flow), so nothing is lost.
//
//  Pure `Foundation`/`FileManager` — no `import FluidAudio` — so it compiles and
//  works whether or not the package is linked.
//

import Foundation

enum ModelStore {

    /// Groups of FluidAudio models that map to a user-facing feature, paired with
    /// the on-disk folder names FluidAudio uses for each (its `Repo.folderName`).
    enum ModelGroup: String, CaseIterable, Identifiable {
        case liveTranscription
        case onDeviceLanguage
        case diarization

        var id: String { rawValue }

        /// Folder names under `modelsDirectory`.
        var folderNames: [String] {
            switch self {
            case .liveTranscription:
                // English-only EOU + multilingual Nemotron streaming.
                return [
                    "parakeet-realtime-eou-120m-coreml",
                    "Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"
                ]
            case .onDeviceLanguage:
                return ["parakeet-tdt-0.6b-v3-coreml"]
            case .diarization:
                return ["speaker-diarization-coreml"]
            }
        }

        var displayName: String {
            switch self {
            case .liveTranscription:
                return NSLocalizedString("settings.models.live", comment: "Live transcription models")
            case .onDeviceLanguage:
                return NSLocalizedString("settings.models.on_device_language", comment: "On-device language model")
            case .diarization:
                return NSLocalizedString("settings.models.diarization", comment: "Diarization models")
            }
        }
    }

    /// FluidAudio's model cache directory on iOS:
    /// `Application Support/FluidAudio/Models`.
    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    /// Total bytes used on disk by a group's model folders (0 if none present).
    static func sizeOnDisk(_ group: ModelGroup) -> Int64 {
        group.folderNames.reduce(Int64(0)) { running, folder in
            running + directorySize(modelsDirectory.appendingPathComponent(folder, isDirectory: true))
        }
    }

    /// Whether any of the group's model folders exist on disk.
    static func isInstalled(_ group: ModelGroup) -> Bool {
        group.folderNames.contains { folder in
            FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent(folder).path)
        }
    }

    /// Delete a group's model folders. Missing folders are ignored.
    static func delete(_ group: ModelGroup) {
        let fm = FileManager.default
        for folder in group.folderNames {
            try? fm.removeItem(at: modelsDirectory.appendingPathComponent(folder, isDirectory: true))
        }
    }

    /// Recursively sum the size of every regular file under `directory`.
    private static func directorySize(_ directory: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
