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

    /// Groups of FluidAudio models that map to a user-facing feature.
    enum ModelGroup: String, CaseIterable, Identifiable {
        case liveTranscription
        case onDeviceLanguage
        case diarization
        case vad

        var id: String { rawValue }

        /// Known historical/current cache folders. These are only a migration
        /// fallback; newly downloaded folders are discovered and persisted from
        /// filesystem snapshots so FluidAudio can rename repos without hiding
        /// models from Settings.
        var fallbackFolderNames: [String] {
            switch self {
            case .liveTranscription:
                // English-only EOU + multilingual Nemotron streaming.
                return [
                    "parakeet-eou-streaming",
                    "parakeet-realtime-eou-120m-coreml",
                    "nemotron-multilingual",
                    "Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"
                ]
            case .onDeviceLanguage:
                return [
                    "parakeet-tdt-0.6b-v3",
                    "parakeet-tdt-0.6b-v3-coreml"
                ]
            case .diarization:
                return [
                    "speaker-diarization",
                    "speaker-diarization-coreml"
                ]
            case .vad:
                return [
                    "silero-vad",
                    "silero-vad-coreml"
                ]
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
            case .vad:
                return NSLocalizedString("settings.models.vad", comment: "Voice activity detection model")
            }
        }
    }

    struct InstalledModel: Identifiable, Equatable {
        let id: String
        let group: ModelGroup?
        let displayName: String
        let folderNames: [String]
        let size: Int64

        var isOther: Bool { group == nil }
    }

    struct Snapshot {
        fileprivate let folders: [String: FolderSignature]
    }

    fileprivate struct FolderSignature: Equatable {
        let size: Int64
        let latestModification: TimeInterval
    }

    private static let folderRegistryKey = "settings.fluidAudioModelFoldersByGroup"

    /// FluidAudio's model cache directory on iOS:
    /// `Application Support/FluidAudio/Models`.
    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    static func snapshot() -> Snapshot {
        Snapshot(folders: topLevelFolderSignatures())
    }

    static func recordDownload(for group: ModelGroup, before: Snapshot) {
        let after = snapshot()
        let changed = after.folders.compactMap { name, signature -> String? in
            before.folders[name] == signature ? nil : name
        }
        let discovered = changed.isEmpty ? existingFallbackFolders(for: group) : changed
        guard !discovered.isEmpty else { return }
        var registry = folderRegistry()
        let existing = Set(registry[group.rawValue] ?? [])
        registry[group.rawValue] = Array(existing.union(discovered)).sorted()
        setFolderRegistry(registry)
    }

    /// Total bytes used on disk by a group's model folders (0 if none present).
    static func sizeOnDisk(_ group: ModelGroup) -> Int64 {
        folders(for: group).reduce(Int64(0)) { running, folder in
            running + directorySize(modelsDirectory.appendingPathComponent(folder, isDirectory: true))
        }
    }

    /// Whether any of the group's model folders exist on disk.
    static func isInstalled(_ group: ModelGroup) -> Bool {
        folders(for: group).contains { folder in
            FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent(folder).path)
        }
    }

    /// Delete a group's model folders. Missing folders are ignored.
    static func delete(_ group: ModelGroup) {
        delete(folders: folders(for: group))
        var registry = folderRegistry()
        registry[group.rawValue] = nil
        setFolderRegistry(registry)
    }

    static func delete(_ model: InstalledModel) {
        delete(folders: model.folderNames)
        if let group = model.group {
            var registry = folderRegistry()
            registry[group.rawValue] = nil
            setFolderRegistry(registry)
        }
    }

    static func installedModels() -> [InstalledModel] {
        let topLevel = Set(topLevelFolderSignatures().keys)
        var claimed = Set<String>()
        var models: [InstalledModel] = []

        for group in ModelGroup.allCases {
            let groupFolders = folders(for: group).filter { topLevel.contains($0) }
            guard !groupFolders.isEmpty else { continue }
            claimed.formUnion(groupFolders)
            models.append(
                InstalledModel(
                    id: group.rawValue,
                    group: group,
                    displayName: group.displayName,
                    folderNames: groupFolders.sorted(),
                    size: sizeOnDisk(group)
                )
            )
        }

        let otherFolders = topLevel.subtracting(claimed).sorted()
        let otherSize = otherFolders.reduce(Int64(0)) { running, folder in
            running + directorySize(modelsDirectory.appendingPathComponent(folder, isDirectory: true))
        }
        if otherSize > 0 {
            models.append(
                InstalledModel(
                    id: "other",
                    group: nil,
                    displayName: NSLocalizedString("settings.models.other", comment: "Other FluidAudio models"),
                    folderNames: otherFolders,
                    size: otherSize
                )
            )
        }

        return models
    }

    private static func folders(for group: ModelGroup) -> [String] {
        let registered = folderRegistry()[group.rawValue] ?? []
        return Array(Set(registered + group.fallbackFolderNames)).sorted()
    }

    private static func existingFallbackFolders(for group: ModelGroup) -> [String] {
        group.fallbackFolderNames.filter {
            FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent($0).path)
        }
    }

    private static func delete(folders: [String]) {
        let fm = FileManager.default
        for folder in folders {
            try? fm.removeItem(at: modelsDirectory.appendingPathComponent(folder, isDirectory: true))
        }
    }

    private static func folderRegistry() -> [String: [String]] {
        UserDefaults.standard.dictionary(forKey: folderRegistryKey) as? [String: [String]] ?? [:]
    }

    private static func setFolderRegistry(_ registry: [String: [String]]) {
        UserDefaults.standard.set(registry, forKey: folderRegistryKey)
    }

    private static func topLevelFolderSignatures() -> [String: FolderSignature] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var signatures: [String: FolderSignature] = [:]
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            signatures[url.lastPathComponent] = directorySignature(url)
        }
        return signatures
    }

    private static func directorySignature(_ directory: URL) -> FolderSignature {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey],
            options: []
        ) else {
            return FolderSignature(size: 0, latestModification: 0)
        }

        var total: Int64 = 0
        var latestModification: TimeInterval = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            )
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
            if let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate {
                latestModification = max(latestModification, modified)
            }
        }
        return FolderSignature(size: total, latestModification: latestModification)
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
