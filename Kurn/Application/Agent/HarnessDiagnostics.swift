import AgentHarness
import Foundation
import KurnCore

enum HarnessDiagnostics {
    static func record(_ resolution: AgentContextResolution) {
        HarnessTraceStore.shared.record(resolution)
        let source = resolution.source.rawValue
        let tokens = resolution.contextWindowTokens
        let reason = resolution.reason.rawValue
        let refresh = resolution.metadataRefresh?.rawValue ?? "unknown"
        AppLog.generation.atNotice.notice("model_metadata_checked outcome=\(refresh, privacy: .public) resolution=\(resolution.id.uuidString, privacy: .public)")
        AppLog.generation.atNotice.notice("context_window_resolved source=\(source, privacy: .public) tokens=\(tokens, privacy: .public) cached=\(resolution.isCached, privacy: .public) reason=\(reason, privacy: .public) resolution=\(resolution.id.uuidString, privacy: .public)")
    }

    static func record(_ diagnostic: AgentDiagnostic) {
        HarnessTraceStore.shared.record(diagnostic)
        AppLog.generation.atNotice.notice("\(diagnostic.logLine, privacy: .public)")
        if diagnostic.kind == .limitReached {
            ReliabilityLog.record(ReliabilityEvent(operationID: OperationID(diagnostic.runID.uuidString),
                operation: "meeting_chat", stage: "harness_limit", outcome: .failed,
                code: diagnostic.stopReason?.rawValue))
        }
    }
}
