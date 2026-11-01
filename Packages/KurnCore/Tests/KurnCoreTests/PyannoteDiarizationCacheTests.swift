import Foundation
import Testing
@testable import KurnCore

struct PyannoteDiarizationCacheTests {
    @Test func completeFourModelCacheAndValidParametersAreInstalled() throws {
        let snapshot = try Snapshot()
        #expect(snapshot.isInstalled())
        #expect(snapshot.manifest.compiledModels.count == 4)
        #expect(snapshot.manifest.parametersFile == "plda-parameters.json")
    }

    @Test func everyCompiledManifestMustBePresentAndNonEmpty() throws {
        for model in Snapshot.models {
            for size: Int? in [nil, 0, -1] {
                var snapshot = try Snapshot()
                snapshot.byteCounts[snapshot.path("\(model)/coremldata.bin")] = size
                #expect(!snapshot.isInstalled())
            }
        }
    }

    @Test func bareFoldersAndEmptyModelRequirementsDoNotCountAsInstalled() throws {
        var snapshot = try Snapshot()
        snapshot.byteCounts = [:]
        #expect(!snapshot.isInstalled())
        snapshot = try Snapshot()
        #expect(!snapshot.isInstalled(models: []))
    }

    @Test func anyDescendantPartialDownloadRejectsTheWholeCache() throws {
        for partial in ["Embedding.mlmodelc/weights/weight.bin.partial", "Segmentation.mlmodelc/.hidden.partial",
                        "FBank.mlmodelc/model.partial.etag", "plda-parameters.json.partial",
                        "PldaRho.mlmodelc/staging.partial/remaining", ".fluidaudio-revision.partial"] {
            var snapshot = try Snapshot()
            snapshot.descendants?.append(partial)
            #expect(!snapshot.isInstalled())
        }
        #expect(!PyannoteDiarizationCache.isPartialDownload("weights/partial-description.bin"))
    }

    @Test func unreadableDirectoryListingFailsClosed() throws {
        var snapshot = try Snapshot()
        snapshot.descendants = nil
        #expect(!snapshot.isInstalled())
    }

    @Test func missingStaleAndInvalidRevisionMarkersRequireExplicitRepair() throws {
        for data: Data? in [nil, Data("preview".utf8), Data([0xff])] {
            var snapshot = try Snapshot()
            snapshot.contents[snapshot.path(PyannoteDiarizationCache.revisionMarker)] = data
            #expect(!snapshot.isInstalled())
        }
    }

    @Test func parametersMustBeReadableNonEmptyAndDecodable() throws {
        for data: Data? in [nil, Data(), Data("{}".utf8)] {
            var snapshot = try Snapshot()
            snapshot.contents[snapshot.path("plda-parameters.json")] = data
            #expect(!snapshot.isInstalled())
        }
        for size: Int? in [nil, 0] {
            var snapshot = try Snapshot()
            snapshot.byteCounts[snapshot.path("plda-parameters.json")] = size
            #expect(!snapshot.isInstalled())
        }
    }

    @Test func foundationProbesUseRealRegularFilesAndFailClosedWithoutModelFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appendingPathComponent("regular.txt")
        let link = directory.appendingPathComponent("link.txt")
        let missing = directory.appendingPathComponent("missing")
        let data = Data("cache-policy-probe".utf8)
        try data.write(to: text)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: text)
        #expect(PyannoteDiarizationCache.regularFileByteCount(at: text) == data.count)
        #expect(PyannoteDiarizationCache.regularFileByteCount(at: directory) == nil)
        #expect(PyannoteDiarizationCache.regularFileByteCount(at: link) == nil)
        #expect(PyannoteDiarizationCache.regularFileByteCount(at: missing) == nil)
        #expect(PyannoteDiarizationCache.fileData(at: text) == data)
        #expect(PyannoteDiarizationCache.fileData(at: missing) == nil)
        #expect(Set(PyannoteDiarizationCache.descendantPaths(at: directory) ?? []) == ["regular.txt", "link.txt"])
        #expect(PyannoteDiarizationCache.descendantPaths(at: missing) == nil)
    }

    private struct Snapshot {
        static let models = ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc"]
        let directory = URL(fileURLWithPath: "/pyannote-cache-policy-test")
        var byteCounts: [String: Int] = [:]
        var contents: [String: Data] = [:]
        var descendants: [String]? = Self.models

        init() throws {
            for model in Self.models { byteCounts[path("\(model)/coremldata.bin")] = 1 }
            let parameters = try PLDATestJSON.data()
            byteCounts[path("plda-parameters.json")] = parameters.count
            contents[path("plda-parameters.json")] = parameters
            contents[path(PyannoteDiarizationCache.revisionMarker)] = Data("reviewed\n".utf8)
        }

        var manifest: PyannoteDiarizationCache.Manifest { manifest(models: Self.models) }

        func path(_ relative: String) -> String { directory.appendingPathComponent(relative).path }

        func isInstalled(models: [String] = Self.models) -> Bool {
            PyannoteDiarizationCache.isInstalled(
                manifest(models: models),
                fileByteCount: { byteCounts[$0.path] },
                enumerate: { _ in descendants },
                readData: { contents[$0.path] }
            )
        }

        private func manifest(models: [String]) -> PyannoteDiarizationCache.Manifest {
            PyannoteDiarizationCache.Manifest(
                directory: directory, compiledModels: models,
                parametersFile: "plda-parameters.json", expectedRevision: "reviewed"
            )
        }
    }
}
