import AgentHarness
import CryptoKit
import Foundation
import KurnCore
import SwiftData

/// The synchronous main-actor transaction has no suspension between reading a revision and saving
/// the new revision, presentation state and immutable effect receipt.
@MainActor
struct ChatDocumentEffectWriter {
    let store: SwiftDataAgentSessionStore
    let sessionID: String
    var prepareSession: @MainActor @Sendable () throws -> Void = {}
    var origin: ChatArtifactOrigin?

    func commit(_ name: String, arguments: JSONValue, execution: AgentToolExecutionContext) throws
        -> (output: AgentToolOutput, artifacts: [ChatDocumentArtifact]) {
        guard execution.sessionID == sessionID, execution.invocation.toolName == name,
              execution.invocation.namespace == nil else { throw AgentSessionStoreError.conflict }
        let target = try store.session(sessionID)
        _ = try store.snapshot(target)
        let snapshot = try target.harnessSnapshot()
        let digest = SHA256.hash(data: Data(try arguments.encodedString().utf8)).map { String(format: "%02x", $0) }.joined()
        let records = try store.records(target)
        if let record = records.first(where: { $0.kind == .effect && $0.id == execution.invocation.id }) {
            let receipt = try JSONDecoder().decode(DocumentEffectReceipt.self, from: Data(try record.data.encodedString().utf8))
            guard receipt.version == 1, receipt.invocation == execution.invocation, receipt.argumentsDigest == digest,
                  let revision = target.harnessRevisions.first(where: { $0.artifactID == receipt.artifactID && String($0.version) == receipt.artifactVersion }) else {
                throw AgentSessionStoreError.conflict
            }
            let artifact = try HarnessPresentationCodec.decode(ChatDocumentArtifact.self, from: revision.payloadData)
            guard ChatDocumentTools.mutationOutput(name, artifact: artifact) == receipt.output else { throw AgentSessionStoreError.corruptPayload }
            execution.progress(AgentToolProgress(.recoveredCommit))
            return (receipt.output, snapshot.artifacts)
        }
        try Task.checkCancellation()
        let change = try ChatDocumentTools.edit(name, arguments: arguments).applying(to: snapshot.artifacts)
        let output = ChatDocumentTools.mutationOutput(name, artifact: change.artifact)
        let receipt = DocumentEffectReceipt(version: 1, invocation: execution.invocation, argumentsDigest: digest,
            artifactID: change.artifact.id, artifactVersion: String(change.artifact.version), output: output)
        let record = try AgentRecoveryRecord(id: execution.invocation.id, kind: .effect, data: HarnessPresentationCodec.json(receipt))
        execution.progress(AgentToolProgress(.committing))
        var turns = snapshot.turns
        if let origin, let index = turns.indices.last {
            turns[index].artifacts = ChatArtifactReference.updating(turns[index].artifacts ?? [], from: snapshot.artifacts, to: change.artifacts)
            var origins = turns[index].artifactOrigins ?? [:]
            var updated = origin
            updated.sources = origin.sources?.retaining(ChatArtifactOrigin.recorded(artifactID: change.artifact.id, in: snapshot.turns).sources)
            origins[change.artifact.id] = updated; turns[index].artifactOrigins = origins
        }
        try store.writePresentation(target, turns: turns, scope: snapshot.scope, artifacts: change.artifacts, effect: record)
        execution.progress(AgentToolProgress(.committed))
        return (output, change.artifacts)
    }
}

private struct DocumentEffectReceipt: Codable {
    let version: Int
    let invocation: AgentToolInvocation
    let argumentsDigest: String
    let artifactID: UUID
    // Recovery record JSONValue uses Double numbers; keep the exact domain Int as decimal text.
    let artifactVersion: String
    let output: AgentToolOutput
}

/// The lease spans the durable transaction and publication to the in-memory workspace.
/// Actor reentrancy cannot allow a second edit to publish an older snapshot afterwards.
actor ChatDocumentEffectExecutor {
    private let writer: ChatDocumentEffectWriter
    private let workspace: ChatDocumentWorkspace
    private var busy = false
    private var prepared = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(writer: ChatDocumentEffectWriter, workspace: ChatDocumentWorkspace) { self.writer = writer; self.workspace = workspace }

    func execute(_ name: String, arguments: JSONValue, context: AgentToolExecutionContext) async throws -> AgentToolOutput {
        if busy { await withCheckedContinuation { waiting.append($0) } }
        else { busy = true }
        defer {
            if waiting.isEmpty { busy = false }
            else { waiting.removeFirst().resume() }
        }
        let needsPreparation = !prepared
        let writer = writer; let workspace = workspace
        let output = try await ChatDocumentCommitGate.shared.withLease {
            try Task.checkCancellation()
            if needsPreparation { try await writer.prepareSession() }
            let result = try await writer.commit(name, arguments: arguments, execution: context)
            // Do not check cancellation after a known durable commit: publish and acknowledge it.
            try await workspace.restoreCommitted(result.artifacts)
            return result.output
        }
        prepared = true
        return output
    }
}

/// Also fences overlapping run executors, until NH05 provides one owner per session.
/// All local document mutations share this short lease; independent reads remain parallel.
private actor ChatDocumentCommitGate {
    static let shared = ChatDocumentCommitGate()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func withLease<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async rethrows -> Value {
        if busy { await withCheckedContinuation { waiting.append($0) } }
        else { busy = true }
        defer {
            if waiting.isEmpty { busy = false }
            else { waiting.removeFirst().resume() }
        }
        return try await operation()
    }
}
