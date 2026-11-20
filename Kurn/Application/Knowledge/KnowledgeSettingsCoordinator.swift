import Foundation
import KurnCore
import Observation

/// Retains an explicitly confirmed batch beyond the Settings view lifetime.
/// Individual extraction jobs/checkpoints remain owned by the shared queue.
@MainActor @Observable
final class KnowledgeSettingsCoordinator {
    let compilation: KnowledgeCompilationCoordinator
    private(set) var progress: KnowledgeBackfillProgress?
    private(set) var progressControls: KnowledgeControls?
    private(set) var progressMeetingIDs: Set<UUID> = []
    private(set) var failed = false
    @ObservationIgnored private var task: Task<Void, Never>?
    private var settings: AppSettings { compilation.settings }

    init(compilation: KnowledgeCompilationCoordinator) { self.compilation = compilation }

    /// On-device needs the model; a cloud provider needs its key and the automatic grant (CLAUDE.md, "Cloud consent").
    var canCompile: Bool {
        guard let provider = settings.knowledgeProvider else { return false }
        return settings.allowsCloud(provider, for: .automatic) && ProviderFactory.liveUsability(provider)
    }

    func preview(meetingIDs: Set<UUID>, rebuild: Bool) async throws -> KnowledgeBackfillPlan {
        guard settings.knowledgeEnabled, let controls = settings.knowledgeControls,
              settings.knowledgeProvider?.kind == .appleOnDevice else { throw KnowledgeSettingsError.unavailable }
        let read = try await read(meetingIDs: meetingIDs)
        guard settings.knowledgeControls == controls, settings.knowledgeEnabled else { throw KnowledgeSettingsError.stalePreview }
        return KnowledgeBackfillPlan(id: UUID(), controls: controls, read: read, rebuild: rebuild)
    }

    func start(_ plan: KnowledgeBackfillPlan) {
        guard task == nil else { return }
        failed = false
        progressControls = plan.controls
        progressMeetingIDs = plan.read.meetingIDs
        progress = KnowledgeBackfillProgress(total: plan.pending.count)
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.progress?.isRunning = false; self.task = nil }
            do {
                guard !plan.requiresRebuild else { throw KnowledgeSettingsError.recompileRequired }
                for source in plan.pending {
                    try Task.checkCancellation()
                    guard self.settings.knowledgeEnabled, self.settings.knowledgeControls == plan.controls,
                          !plan.controls.isPaused else { throw KnowledgeSettingsError.stalePreview }
                    let fresh = try await self.read(meetingIDs: plan.read.meetingIDs)
                    guard plan.read.sameSources(as: fresh), self.settings.knowledgeEnabled,
                          self.settings.knowledgeControls == plan.controls else { throw KnowledgeSettingsError.stalePreview }
                    // Another approved compilation may have filled a gap since
                    // preview. Missing-only mode never rebuilds that output.
                    if !plan.rebuild, fresh.sources.first(where: { $0.id == source.id })?.isCurrent == true {
                        self.progress?.completed += 1
                        continue
                    }
                    let outcome = await self.compilation.compile(meetingID: source.id, trigger: .explicit,
                        rebuildGeneration: plan.rebuild ? plan.id : nil,
                        expectedSource: .init(fingerprint: source.fingerprint, policyRevisionKey: plan.read.policyRevisionKey))
                    switch outcome {
                    case .completed: self.progress?.completed += 1
                    case .deferred: self.progress?.deferred += 1
                    case .failed: self.progress?.failed += 1
                    }
                }
            } catch {
                self.failed = !(error is CancellationError)
                if self.failed {
                    ReliabilityLog.record(ReliabilityEvent(operationID: OperationID(), operation: "knowledge_backfill", stage: "batch",
                        outcome: .failed, code: "backfill_changed_or_unavailable"))
                }
            }
        }
    }

    func waitUntilIdle() async { await task?.value }

    func coverage(meetingIDs: Set<UUID>) async throws -> KnowledgeScopedMaintenanceReport {
        let store = await compilation.jobQueue.writer()
        return try await store.maintenanceReport(meetingIDs: meetingIDs, scope: "workspace", authorization: { [weak self] in
            await self?.compilation.browserReadAuthorization(meetingIDs: meetingIDs)
                ?? KnowledgeSourceAuthorization(featureEnabled: false, meetingIDs: [], policies: [], sourceClassifications: [])
        })
    }

    func rebuildPages(meetingIDs: Set<UUID>) async throws {
        let store = await compilation.jobQueue.writer()
        let authorization: @Sendable () async -> KnowledgeSourceAuthorization = { [weak self] in
            await self?.compilation.browserReadAuthorization(meetingIDs: meetingIDs)
                ?? KnowledgeSourceAuthorization(featureEnabled: false, meetingIDs: [], policies: [], sourceClassifications: [])
        }
        let snapshot = try await store.wikiProjectionSnapshot(meetingIDs: meetingIDs, scope: "workspace", authorization: authorization)
        _ = try await store.publishWikiProjection(snapshot, authorization: authorization)
    }

    private func read(meetingIDs: Set<UUID>) async throws -> KnowledgeBackfillRead {
        guard settings.knowledgeProvider?.kind == .appleOnDevice else { throw KnowledgeSettingsError.unavailable }
        let store = await compilation.jobQueue.writer()
        return try await store.backfillRead(meetingIDs: meetingIDs, model: settings.summaryModel(for: .appleOnDevice), authorization: { [weak self] in
            await self?.compilation.browserReadAuthorization(meetingIDs: meetingIDs)
                ?? KnowledgeSourceAuthorization(featureEnabled: false, meetingIDs: [], policies: [], sourceClassifications: [])
        })
    }
}
