import AgentHarness
import Foundation

/// Bounded content-free diagnostics, independent of console verbosity and view lifetime.
/// Completed runs rotate as units. A truncated run retains an explicit marker and terminal.
final class HarnessTraceStore: @unchecked Sendable {
    static let shared = HarnessTraceStore()
    private let lock = NSLock()
    private let location: URL?
    private let maxRunBytes: Int
    private let completedRunLimit: Int
    private var truncated = Set<UUID>()

    init(location: URL? = nil, maxRunBytes: Int = 512 * 1024, completedRunLimit: Int = 20) {
        self.location = location
        self.maxRunBytes = maxRunBytes
        self.completedRunLimit = completedRunLimit
    }

    private struct Record: Encodable {
        var schemaVersion = 1
        var contextResolution: AgentContextResolution?
        var diagnostic: AgentDiagnostic?
    }

    func record(_ resolution: AgentContextResolution) {
        append(Record(contextResolution: resolution), id: resolution.id, terminal: false)
    }

    func record(_ diagnostic: AgentDiagnostic) {
        let terminal = [AgentDiagnostic.Kind.runFinished, .runFailed, .runCancelled].contains(diagnostic.kind)
        append(Record(diagnostic: diagnostic), id: diagnostic.resolutionID ?? diagnostic.runID, terminal: terminal)
    }

    func exportJSONL() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let files = try urls().sorted { $0.lastPathComponent < $1.lastPathComponent }
        let header = "{\"schemaVersion\":1,\"completedRunLimit\":\(completedRunLimit)}\n"
        return try files.reduce(into: header) { result, url in
            result += try String(contentsOf: url, encoding: .utf8)
        }
    }

    private func directory() throws -> URL {
        let root = try location ?? FileManager.default.url(for: .applicationSupportDirectory,
                                                          in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("HarnessTraces", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: RecordingProtection.protectionType])
        return root
    }

    private func urls() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "jsonl" }
    }

    private func append(_ record: Record, id: UUID, terminal: Bool) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let root = try directory()
            let url = root.appendingPathComponent("\(id).active.jsonl")
            let data = try JSONEncoder().encode(record) + Data([0x0A])
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size + data.count <= maxRunBytes || terminal {
                try write(data, to: url)
            } else if truncated.insert(id).inserted {
                try write(Data("{\"schemaVersion\":1,\"traceIncomplete\":true}\n".utf8), to: url)
            }
            if terminal {
                try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("\(id).jsonl"))
                truncated.remove(id)
                try prune()
            }
        } catch {
            // This path deliberately does not call ReliabilityLog (which could itself fail).
            AppLog.generation.atError.error("Harness trace write failed code=\(error.publicLogCode, privacy: .public)")
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            RecordingProtection.apply(to: url)
        }
    }

    private func prune() throws {
        let files = try urls()
        let completed = files.filter { !$0.lastPathComponent.hasSuffix(".active.jsonl") }.sorted {
            let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return first > second
        }
        for url in completed.dropFirst(max(0, completedRunLimit)) { try FileManager.default.removeItem(at: url) }
        // An abandoned active trace cannot grow forever across process crashes.
        for url in files where url.lastPathComponent.hasSuffix(".active.jsonl") {
            let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(date) > 7 * 24 * 3600 { try FileManager.default.removeItem(at: url) }
        }
    }
}
