import Foundation

public enum PyannoteDiarizationCache {
    public static let compiledManifest = "coremldata.bin"
    public static let revisionMarker = ".fluidaudio-revision"

    public struct Manifest: Sendable {
        public let directory: URL
        public let compiledModels: [String]
        public let parametersFile: String
        public let expectedRevision: String

        public init(directory: URL, compiledModels: [String], parametersFile: String, expectedRevision: String) {
            self.directory = directory
            self.compiledModels = compiledModels
            self.parametersFile = parametersFile
            self.expectedRevision = expectedRevision
        }
    }

    public static func isInstalled(
        _ manifest: Manifest,
        fileByteCount: (URL) -> Int? = regularFileByteCount,
        enumerate: (URL) -> [String]? = descendantPaths,
        readData: (URL) -> Data? = fileData
    ) -> Bool {
        guard !manifest.compiledModels.isEmpty, let descendants = enumerate(manifest.directory),
              !descendants.contains(where: isPartialDownload),
              let markerData = readData(manifest.directory.appendingPathComponent(revisionMarker)),
              let revision = String(data: markerData, encoding: .utf8),
              revision.trimmingCharacters(in: .whitespacesAndNewlines) == manifest.expectedRevision else { return false }
        guard manifest.compiledModels.allSatisfy({ model in
            let file = manifest.directory.appendingPathComponent(model).appendingPathComponent(compiledManifest)
            return (fileByteCount(file) ?? 0) > 0
        }) else { return false }
        let parameters = manifest.directory.appendingPathComponent(manifest.parametersFile)
        guard (fileByteCount(parameters) ?? 0) > 0, let data = readData(parameters),
              (try? PyannotePLDAParameters.decodePsi(data)) != nil else { return false }
        return true
    }

    public static func isPartialDownload(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasSuffix(".partial") || $0.hasSuffix(".partial.etag") }
    }

    public static func regularFileByteCount(at url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attributes[.size] as? NSNumber)?.intValue
    }

    public static func descendantPaths(at url: URL) -> [String]? {
        try? FileManager.default.subpathsOfDirectory(atPath: url.path)
    }

    public static func fileData(at url: URL) -> Data? {
        try? Data(contentsOf: url)
    }
}
