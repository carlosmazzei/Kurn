import AgentHarness
import Foundation
import KurnCore
import SwiftData

@MainActor
extension SwiftDataAgentSessionStore {
    /// One atomic session is the resumable unit. A failed save leaves no conversion marker.
    func migrate(_ target: ChatSession) throws {
        if target.canonicalVersion != nil {
            storageLog("validation_started", session: target)
            do {
                _ = try snapshot(target); _ = try Self.projection(target)
                storageLog("validation_finished", session: target)
            } catch {
                storageLog("validation_failed", session: target)
                throw error
            }
            return
        }
        storageLog("migration_started", session: target)
        do {
            let legacy = try target.harnessSnapshot()
            try writePresentation(target, turns: legacy.turns, scope: legacy.scope, artifacts: legacy.artifacts, preserveUpdatedAt: true)
            storageLog("migration_finished", session: target)
        } catch {
            storageLog("migration_failed", session: target)
            throw error
        }
    }

    func writePresentation(_ target: ChatSession, turns: [PersistedChatTurn], scope: ChatSourceScope?, artifacts: [ChatDocumentArtifact],
                           effect: AgentRecoveryRecord? = nil, preserveCommittedArtifacts: Bool = false, preserveUpdatedAt: Bool = false) throws {
        storageLog("commit_started", session: target)
        do {
            var presentation = (turns: turns, artifacts: artifacts)
            if preserveCommittedArtifacts, target.canonicalVersion != nil {
                let committed = try target.harnessSnapshot()
                presentation = try HarnessPresentationReconciler.preserve(turns: turns, artifacts: artifacts,
                    committed: (committed.turns, committed.artifacts))
            }
            try planAndWritePresentation(target, turns: presentation.turns, scope: scope, artifacts: presentation.artifacts, effect: effect, preserveUpdatedAt: preserveUpdatedAt)
            storageLog("commit_finished", session: target)
        } catch {
            storageLog("commit_failed", session: target)
            throw error
        }
    }

    private func planAndWritePresentation(_ target: ChatSession, turns: [PersistedChatTurn], scope: ChatSourceScope?, artifacts: [ChatDocumentArtifact],
                                          effect: AgentRecoveryRecord?, preserveUpdatedAt: Bool) throws {
        guard Set(turns.map(\.id)).count == turns.count else { throw AgentSessionStoreError.invalidEntry }
        _ = try ChatDocumentWorkspace(artifacts: artifacts)
        let migrating = target.canonicalVersion == nil
        if let effect {
            guard !migrating, effect.kind == .effect, !target.harnessRecords.contains(where: { $0.recordID == effect.id && $0.kindRaw == "effect" }) else {
                throw AgentSessionStoreError.conflict
            }
        }
        if migrating, !target.harnessEntries.isEmpty || !target.harnessRevisions.isEmpty || !target.harnessRecords.isEmpty {
            throw AgentSessionStoreError.invalidGraph
        }
        let existing = migrating ? [] : try snapshot(target).entries
        let path = try AgentEntryGraph(sessionID: target.id.uuidString, entries: existing, leafID: migrating ? nil : target.canonicalLeafID).activePath
        let messages = path.filter { if case .message = $0.payload { return true }; return false }
        let proposed = try turns.map { (try HarnessPresentationCodec.message($0), try HarnessPresentationCodec.json(HarnessTurnMetadata($0))) }
        var prefix = 0
        for (old, new) in zip(messages, proposed) {
            guard old.payload == .message(new.0), old.metadata == new.1 else { break }
            prefix += 1
        }
        let (revisionRows, revisionIDs) = try planRevisions(target, artifacts: artifacts)
        let state = HarnessPresentationState(scope: scope, artifactRevisionIDs: revisionIDs)
        let stateJSON = try HarnessPresentationCodec.json(state)
        if effect == nil, !migrating, prefix == messages.count, prefix == proposed.count,
           path.last?.payload == .custom(type: HarnessPresentationState.type, data: stateJSON) { return }
        var parent = prefix == messages.count ? path.last?.id : prefix > 0 ? messages[prefix - 1].id : nil
        var additions: [AgentSessionEntry] = []
        for index in prefix..<proposed.count {
            let id = migrating ? turns[index].id.uuidString : UUID().uuidString
            let entry = try AgentSessionEntry(sessionID: target.id.uuidString, id: id, parentID: parent,
                ordinal: existing.count + additions.count + 1, createdAt: AgentSessionEntry.time(),
                payload: .message(proposed[index].0), metadata: proposed[index].1)
            additions.append(entry); parent = id
        }
        let stateEntry = try AgentSessionEntry(sessionID: target.id.uuidString, id: UUID().uuidString, parentID: parent,
            ordinal: existing.count + additions.count + 1, createdAt: AgentSessionEntry.time(),
            payload: .custom(type: HarnessPresentationState.type, data: stateJSON))
        additions.append(stateEntry)
        _ = try AgentEntryGraph(sessionID: target.id.uuidString, entries: existing + additions, leafID: stateEntry.id)
        let rows = try additions.map { entry in
            HarnessSessionEntry(session: target, entryID: entry.id, parentEntryID: entry.parentID,
                                ordinal: entry.ordinal, kindRaw: entry.kind, createdAtUTC: entry.createdAt, payloadData: try HarnessPresentationCodec.encode(entry))
        }
        let cache = try PresentationCache(turns: turns, scope: scope, artifacts: artifacts)
        let record = try effect.map { HarnessSessionRecord(session: target, recordID: $0.id, kindRaw: $0.kind.rawValue,
            payloadData: try HarnessPresentationCodec.encode($0)) }
        try applyPresentation(target, rows: rows, revisions: revisionRows, leaf: stateEntry.id, cache: cache, effect: record, preserveUpdatedAt: preserveUpdatedAt)
    }

    /// The revision rows to add and the revision ID of each artifact. A revision is immutable and
    /// belongs to the branch that wrote it (NH09): the same artifact version written with other
    /// content on another branch is a revision of its own, never a conflict with the first.
    private func planRevisions(_ target: ChatSession, artifacts: [ChatDocumentArtifact]) throws -> ([HarnessArtifactRevision], [String]) {
        var rows: [HarnessArtifactRevision] = []
        var ids: [String] = []
        for artifact in artifacts {
            let payload = try HarnessPresentationCodec.encode(artifact)
            let saved = target.harnessRevisions.filter { $0.artifactID == artifact.id && $0.version == artifact.version }
            if let existing = try saved.first(where: { try HarnessPresentationCodec.decode(ChatDocumentArtifact.self, from: $0.payloadData) == artifact }) {
                ids.append(existing.id)
                continue
            }
            let base = Self.revisionID(session: target, artifact: artifact)
            let id = saved.contains { $0.id == base } ? Self.branchRevisionID(base: base, payload: payload) : base
            guard !saved.contains(where: { $0.id == id }) else { throw AgentSessionStoreError.conflict }
            rows.append(HarnessArtifactRevision(session: target, artifactID: artifact.id, version: artifact.version,
                                                payloadData: payload, id: id))
            ids.append(id)
        }
        return (rows, ids)
    }

    private func applyPresentation(_ target: ChatSession, rows: [HarnessSessionEntry], revisions: [HarnessArtifactRevision],
                                   leaf: String, cache: PresentationCache, effect: HarnessSessionRecord?, preserveUpdatedAt: Bool) throws {
        let old = PresentationCheckpoint(target)
        do {
            if target.canonicalVersion == nil {
                target.legacyTurnsData = target.turnsData; target.legacyScopeData = target.scopeData; target.legacyArtifactsData = target.artifactsData
            }
            for row in rows { insert(row, into: target) }
            for row in revisions {
                row.session = target
                context.insert(row)
            }
            if let effect {
                effect.session = target; context.insert(effect)
            }
            if !preserveUpdatedAt { target.updatedAt = Date() }
            target.turnsData = cache.turns; target.scopeData = cache.scope; target.artifactsData = cache.artifacts
            target.canonicalVersion = 1; target.canonicalLeafID = leaf; target.canonicalOrdinal += rows.count; target.canonicalRevision += 1
            try save(context)
        } catch {
            let entryIDs = Set(rows.map(\.id)); let revisionIDs = Set(revisions.map(\.id))
            target.harnessEntries.removeAll { entryIDs.contains($0.id) }
            target.harnessRevisions.removeAll { revisionIDs.contains($0.id) }
            for row in rows { context.delete(row) }
            for row in revisions { context.delete(row) }
            if let effect { target.harnessRecords.removeAll { $0.id == effect.id }; context.delete(effect) }
            old.restore(target)
            throw error
        }
    }

    private func storageLog(_ stage: String, session: ChatSession) {
        // The persisted reliability sink is independent of console verbosity.
        let outcome: ReliabilityEvent.Outcome = stage.hasSuffix("_failed") ? .failed : stage.hasSuffix("_started") ? .started : .succeeded
        ReliabilityLog.record(ReliabilityEvent(operationID: OperationID(session.id.uuidString), operation: "harness_store", stage: stage, outcome: outcome, code: "canonical_v1"))
        // UUID/counts only. Raw decode errors, questions and source/document bodies stay private.
        AppLog.persistence.atInfo.info("harness.store stage=\(stage, privacy: .public) session=\(session.id, privacy: .public) entries=\(session.canonicalOrdinal, privacy: .public) revision=\(session.canonicalRevision, privacy: .public)")
    }
}

struct PresentationCache {
    let turns: Data
    let scope: Data?
    let artifacts: Data
    init(turns: [PersistedChatTurn], scope: ChatSourceScope?, artifacts: [ChatDocumentArtifact]) throws {
        self.turns = try HarnessPresentationCodec.encode(turns)
        self.scope = try scope.map { try HarnessPresentationCodec.encode($0) }
        self.artifacts = try HarnessPresentationCodec.encode(artifacts)
    }
}

@MainActor
struct PresentationCheckpoint {
    let cache: (Data, Data?, Data?)
    let legacy: (Data?, Data?, Data?)
    let version: Int?
    let leaf: String?
    let ordinal: Int
    let revision: Int
    let updatedAt: Date
    init(_ session: ChatSession) {
        updatedAt = session.updatedAt
        cache = (session.turnsData, session.scopeData, session.artifactsData)
        legacy = (session.legacyTurnsData, session.legacyScopeData, session.legacyArtifactsData)
        version = session.canonicalVersion; leaf = session.canonicalLeafID; ordinal = session.canonicalOrdinal; revision = session.canonicalRevision
    }
    func restore(_ session: ChatSession) {
        session.updatedAt = updatedAt
        (session.turnsData, session.scopeData, session.artifactsData) = cache
        (session.legacyTurnsData, session.legacyScopeData, session.legacyArtifactsData) = legacy
        session.canonicalVersion = version; session.canonicalLeafID = leaf; session.canonicalOrdinal = ordinal; session.canonicalRevision = revision
    }
}
