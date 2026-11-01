import KurnCore

extension ModelStore.ModelGroup {
    func canClaimFolder(_ folder: String) -> Bool {
        if self == .fluidAudioASR || self == .nemotronDiarization {
            return fallbackFolderNames.contains(folder)
        }
        return !Self.allCases.contains { group in
            group != self && group.root == root && group.fallbackFolderNames.contains(folder)
        }
    }
}

extension ModelStore {
    static func recordVerification(for set: ModelSet, group: ModelGroup) {
        let folder: String?
        switch set {
        case .fluidAudioASR(let model) where group == .fluidAudioASR:
            folder = model.folderName
        case .fluidAudioUnifiedStreaming:
            folder = FluidAudioASRModel.nemotronUnified.folderName
        default:
            folder = nil
        }
        ModelVerification.record(
            id: ModelVerification.recordID(for: group, folder: folder),
            size: sizeOnDisk(group, folder: folder)
        )
    }
}
