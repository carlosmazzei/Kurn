import Foundation
import KurnCore

struct KnowledgeCompilationExpectation: Sendable {
    let fingerprint: String
    let policyRevisionKey: String
}

struct KnowledgeBackfillRead: Equatable, Sendable {
    struct Source: Equatable, Sendable, Identifiable {
        let id: UUID
        let title: String
        let fingerprint: String
        let segments: Int
        let characters: Int
        let isCurrent: Bool
        let requiresRebuild: Bool
    }
    let policyRevisionKey: String
    let sources: [Source]
    var meetingIDs: Set<UUID> { Set(sources.map(\.id)) }
    func sameSources(as other: Self) -> Bool {
        policyRevisionKey == other.policyRevisionKey && sources.map { [$0.id.uuidString, $0.title, $0.fingerprint] }
            == other.sources.map { [$0.id.uuidString, $0.title, $0.fingerprint] }
    }
}

struct KnowledgeBackfillPlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let controls: KnowledgeControls
    let read: KnowledgeBackfillRead
    let rebuild: Bool
    var pending: [KnowledgeBackfillRead.Source] { read.sources.filter { $0.segments > 0 && (rebuild || !$0.isCurrent) } }
    var requiresRebuild: Bool { !rebuild && pending.contains(where: \.requiresRebuild) }
}

struct KnowledgeBackfillProgress: Equatable {
    let total: Int
    var completed = 0
    var deferred = 0
    var failed = 0
    var isRunning = true
}

enum KnowledgeSettingsError: Error { case unavailable, stalePreview, limitExceeded, recompileRequired }
