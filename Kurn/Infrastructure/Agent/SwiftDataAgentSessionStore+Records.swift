import AgentHarness
import Foundation
import KurnCore
import SwiftData

@MainActor
extension SwiftDataAgentSessionStore {
    func validateRevisions(_ target: ChatSession) throws {
        var ids = Set<String>()
        for row in target.harnessRevisions {
            _ = try Self.checkedRevision(row, session: target)
            guard ids.insert(row.id).inserted else { throw AgentSessionStoreError.corruptPayload }
        }
    }

    static func checkedRevision(_ row: HarnessArtifactRevision, session: ChatSession) throws -> ChatDocumentArtifact {
        let value = try HarnessPresentationCodec.decode(ChatDocumentArtifact.self, from: row.payloadData)
        guard row.sessionID == session.id, row.artifactID == value.id, row.version == value.version,
              Self.isRevisionID(row.id, session: session, artifact: value, payload: row.payloadData) else { throw AgentSessionStoreError.corruptPayload }
        _ = try ChatDocumentWorkspace(artifacts: [value])
        return value
    }

    func records(_ target: ChatSession) throws -> [AgentRecoveryRecord] {
        try target.harnessRecords.map { try Self.checkedRecord($0, session: target) }
    }

    static func checkedRecord(_ row: HarnessSessionRecord, session: ChatSession) throws -> AgentRecoveryRecord {
        let value = try HarnessPresentationCodec.decode(AgentRecoveryRecord.self, from: row.payloadData)
        guard row.sessionID == session.id, row.recordID == value.id, row.kindRaw == value.kind.rawValue,
              row.id == session.id.uuidString + ":" + value.kind.rawValue + ":" + value.id else { throw AgentSessionStoreError.corruptPayload }
        return value
    }

    func put(_ value: AgentRecoveryRecord, in target: ChatSession, expectedRevision: Int) throws {
        _ = try snapshot(target)
        guard expectedRevision == target.canonicalRevision else { throw AgentSessionStoreError.conflict }
        let id = target.id.uuidString + ":" + value.kind.rawValue + ":" + value.id
        let data = try HarnessPresentationCodec.encode(value)
        let existing = target.harnessRecords.first { $0.id == id }
        // Effect records are append-only; generic metadata updates cannot invalidate a receipt.
        if value.kind == .effect, let existing {
            guard existing.payloadData == data else { throw AgentSessionStoreError.conflict }
            return
        }
        let oldData = existing?.payloadData
        let row = existing ?? HarnessSessionRecord(session: target, recordID: value.id, kindRaw: value.kind.rawValue, payloadData: data)
        do {
            if existing == nil {
                row.session = target
                context.insert(row)
            }
            row.payloadData = data; target.canonicalRevision += 1
            try save(context)
        } catch {
            target.canonicalRevision = expectedRevision
            if let oldData { row.payloadData = oldData }
            else { target.harnessRecords.removeAll { $0.id == id }; context.delete(row) }
            throw error
        }
    }
}
