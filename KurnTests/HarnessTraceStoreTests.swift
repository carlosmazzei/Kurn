import AgentHarness
import Foundation
import Testing
@testable import Kurn

struct HarnessTraceStoreTests {
    private func location() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HarnessTraceStoreTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func resolutionAndTerminalSurviveReopeningAndAreExportableWithConsoleOff() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HarnessTraceStore(location: url)
        let resolution = AgentContextResolution(contextWindowTokens: 1_050_000, source: .fixedTable,
                                                reason: .catalogMatch, catalogVersion: "2026-11-08")
        store.record(resolution)
        store.record(AgentDiagnostic(runID: UUID(), sequence: 1, kind: .runFinished, resolutionID: resolution.id))
        let reopened = HarnessTraceStore(location: url)
        let text = try reopened.exportJSONL()
        #expect(text.contains("fixed_table"))
        #expect(text.contains("1050000"))
        #expect(text.contains("runFinished"))
        #expect(text.contains(resolution.id.uuidString))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("\(resolution.id).jsonl").path))
        for line in text.split(separator: "\n") {
            #expect(throws: Never.self) { try JSONSerialization.jsonObject(with: Data(line.utf8)) }
        }
    }

    @Test func quotaMarksIncompleteAndStillRetainsTerminal() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HarnessTraceStore(location: url, maxRunBytes: 1)
        let id = UUID()
        store.record(AgentDiagnostic(runID: id, sequence: 1, kind: .requestStarted))
        store.record(AgentDiagnostic(runID: id, sequence: 2, kind: .contextCheck))
        store.record(AgentDiagnostic(runID: id, sequence: 3, kind: .runFailed))
        let text = try store.exportJSONL()
        #expect(text.components(separatedBy: "traceIncomplete").count == 2)
        #expect(text.contains("runFailed"))
    }

    @Test func completedRunRotationKeepsTheActiveRun() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HarnessTraceStore(location: url, completedRunLimit: 1)
        let active = UUID()
        store.record(AgentDiagnostic(runID: active, sequence: 1, kind: .runStarted))
        for _ in 0..<3 { store.record(AgentDiagnostic(runID: UUID(), sequence: 1, kind: .runFinished)) }
        let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        #expect(try store.exportJSONL().contains(active.uuidString))
    }

    @Test func diagnosticWriteFailureDoesNotThrowIntoTheAgent() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("file")
        try Data().write(to: file)
        let store = HarnessTraceStore(location: file)
        store.record(AgentDiagnostic(runID: UUID(), sequence: 1, kind: .runFailed))
        #expect(throws: (any Error).self) { try store.exportJSONL() }
    }
}
