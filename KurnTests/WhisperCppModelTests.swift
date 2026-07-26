//
//  WhisperCppModelTests.swift
//  KurnTests
//
//  The whisper.cpp model catalog and where its files land on disk. These are
//  pure value-type derivations, so they run without the binary package linked
//  (the test target does not link it).
//

import Foundation
import Testing
@testable import Kurn

struct WhisperCppModelTests {

    @Test func rawValuesRoundTrip() {
        for model in WhisperCppModel.allCases {
            #expect(WhisperCppModel(rawValue: model.rawValue) == model)
            #expect(model.id == model.rawValue)
        }
    }

    @Test func displayNamesAreLocalizedAndNonEmpty() {
        for model in WhisperCppModel.allCases {
            #expect(!model.displayName.isEmpty)
            // A missing key makes NSLocalizedString echo the key back.
            #expect(!model.displayName.hasPrefix("whisper_cpp.model."))
        }
    }

    /// The file names have to match whisper.cpp's published GGML assets exactly,
    /// or the download 404s at runtime.
    @Test func fileNamesMatchTheUpstreamAssets() {
        let expected: [WhisperCppModel: String] = [
            .base: "ggml-base-q5_1.bin",
            .small: "ggml-small-q5_1.bin",
            .largeTurbo: "ggml-large-v3-turbo-q5_0.bin"
        ]
        // Fails when a case is added without a name here, rather than silently
        // skipping it.
        #expect(expected.count == WhisperCppModel.allCases.count)
        for model in WhisperCppModel.allCases {
            #expect(model.fileName == expected[model])
            #expect(model.folderName == expected[model]?.replacingOccurrences(of: ".bin", with: ""))
        }
    }

    @Test func downloadURLsPointAtTheWhisperCppModelRepository() {
        for model in WhisperCppModel.allCases {
            let url = model.downloadURL
            #expect(url.absoluteString == "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(model.fileName)")
        }
    }

    /// Each variant needs its own folder, otherwise switching sizes would let
    /// one download overwrite another and `isInstalled` would lie.
    @Test func eachVariantHasADistinctFolder() {
        let folders = Set(WhisperCppModel.allCases.map(\.folderName))
        #expect(folders.count == WhisperCppModel.allCases.count)
    }

    @Test func plausibilityFloorIsBelowTheAdvertisedSize() {
        for model in WhisperCppModel.allCases {
            #expect(model.minimumPlausibleBytes > 0)
            #expect(model.minimumPlausibleBytes < model.approximateBytes)
        }
    }

    @Test func defaultIsTheSmallModel() {
        #expect(WhisperCppModel.default == .small)
    }

    // MARK: - On-disk layout

    @Test func modelsLiveUnderTheirOwnRootNotFluidAudios() {
        let root = WhisperCppModelDownloader.modelsDirectory
        #expect(root.path.hasSuffix("WhisperCpp/Models"))
        #expect(root != ModelStore.modelsDirectory)
        // A whisper download must never land inside FluidAudio's cache, which
        // `ModelStore` snapshot-diffs and could otherwise attribute or delete.
        #expect(!root.path.hasPrefix(ModelStore.modelsDirectory.path))

        for model in WhisperCppModel.allCases {
            let file = WhisperCppModelDownloader.fileURL(for: model)
            #expect(file.lastPathComponent == model.fileName)
            #expect(file.deletingLastPathComponent() == root.appendingPathComponent(model.folderName, isDirectory: true))
        }
    }

    @Test func modelStoreRoutesTheWhisperGroupToTheWhisperRoot() {
        #expect(ModelStore.ModelGroup.whisperCpp.root == WhisperCppModelDownloader.modelsDirectory)
        for group in ModelStore.ModelGroup.allCases where group != .whisperCpp {
            #expect(group.root == ModelStore.modelsDirectory)
        }
    }

    @Test func whisperGroupClaimsEveryVariantFolder() {
        let fallbacks = Set(ModelStore.ModelGroup.whisperCpp.fallbackFolderNames)
        #expect(fallbacks == Set(WhisperCppModel.allCases.map(\.folderName)))
    }

    /// Size variants are independently useful, so Storage has to list them one
    /// per row — keeping `small` while dropping `large-v3-turbo` is a reasonable
    /// thing to want. FluidAudio's folders are parts of one feature and stay
    /// grouped.
    @Test func onlyTheWhisperGroupListsItsFoldersSeparately() {
        #expect(ModelStore.ModelGroup.whisperCpp.listsFoldersSeparately)
        for group in ModelStore.ModelGroup.allCases where group != .whisperCpp {
            #expect(group.listsFoldersSeparately == false)
        }
    }

    @Test func eachVariantFolderGetsItsOwnRowName() {
        let group = ModelStore.ModelGroup.whisperCpp
        let names = WhisperCppModel.allCases.map { group.displayName(forFolder: $0.folderName) }
        #expect(Set(names).count == names.count)
        for (model, name) in zip(WhisperCppModel.allCases, names) {
            #expect(name.contains(model.displayName))
        }
        // An unrecognized folder falls back to the group name rather than
        // producing a row labelled with a raw directory name.
        #expect(group.displayName(forFolder: "ggml-nonexistent") == group.displayName)
    }

    /// The bug this covers: every installed variant collapsed into a single
    /// Storage row, so there was no way to delete just one of them.
    @Test func installedVariantsAreListedAndDeletedIndividually() throws {
        let fm = FileManager.default
        let root = WhisperCppModelDownloader.modelsDirectory
        let installed: [WhisperCppModel] = [.base, .largeTurbo]
        // Only run against a clean slate, so a real download on the simulator
        // can't make this flaky.
        try #require(WhisperCppModel.allCases.allSatisfy { !fm.fileExists(atPath: WhisperCppModelDownloader.directory(for: $0).path) })
        defer {
            for model in installed {
                try? fm.removeItem(at: WhisperCppModelDownloader.directory(for: model))
            }
        }

        for model in installed {
            let folder = WhisperCppModelDownloader.directory(for: model)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 2048).write(to: folder.appendingPathComponent(model.fileName))
        }

        let rows = ModelStore.installedModels().filter { $0.group == .whisperCpp }
        #expect(rows.count == installed.count)
        #expect(Set(rows.flatMap(\.folderNames)) == Set(installed.map(\.folderName)))
        // One folder per row is what makes the delete button surgical.
        #expect(rows.allSatisfy { $0.folderNames.count == 1 })
        #expect(rows.allSatisfy { $0.size > 0 })
        // The variant that was not written must not appear.
        #expect(!rows.contains { $0.folderNames.contains(WhisperCppModel.small.folderName) })

        guard let base = rows.first(where: { $0.folderNames == [WhisperCppModel.base.folderName] }) else {
            Issue.record("no row for the base variant")
            return
        }
        ModelStore.delete(base)
        #expect(!fm.fileExists(atPath: WhisperCppModelDownloader.directory(for: .base).path))
        // Deleting one variant must leave the others on disk.
        #expect(fm.fileExists(atPath: WhisperCppModelDownloader.directory(for: .largeTurbo).path))
        #expect(ModelStore.installedModels().filter { $0.group == .whisperCpp }.count == 1)
    }

    /// Nothing is installed on a clean simulator, so this also proves
    /// `isInstalled` doesn't throw or report a false positive for a missing file.
    @Test func uninstalledModelsReportNotInstalled() {
        for model in WhisperCppModel.allCases where !FileManager.default.fileExists(
            atPath: WhisperCppModelDownloader.fileURL(for: model).path
        ) {
            #expect(WhisperCppModelDownloader.isInstalled(model) == false)
        }
    }
}
