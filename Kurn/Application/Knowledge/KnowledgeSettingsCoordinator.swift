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
        guard settings.knowledgeEnabled, let controls = settings.knowledgeControls, let provider = settings.knowledgeProvider,
              settings.allowsCloud(provider, for: .automatic) else { throw KnowledgeSettingsError.unavailable }
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
        let classifications = try await store.browserRead(meetingIDs: meetingIDs, authorization: authorization).sourceClassifications
        let narratives = await pageNarratives(snapshot.wiki, classifications: classifications)
        _ = try await store.publishWikiProjection(snapshot, narratives: narratives, authorization: authorization)
    }

    /// Pages that get a generated narrative per rebuild, the ones with the most claims first.
    static let narrativePageLimit = 24

    /// Best effort: a page whose generation fails or cites none of its claims keeps its claims alone.
    private func pageNarratives(_ wiki: KnowledgeWikiSnapshot, classifications: [KnowledgeClassification]) async -> [KnowledgeWikiNarrative] {
        guard let llm = compilation.narrativeModel(classifications: classifications),
              let pages = try? KnowledgeWikiProjector.project(wiki) else { return [] }
        let ranked = pages.sorted { $0.sections.flatMap(\.entries).count > $1.sections.flatMap(\.entries).count }
        var narratives: [KnowledgeWikiNarrative] = []
        for page in ranked.prefix(Self.narrativePageLimit) {
            guard !Task.isCancelled else { break }
            guard let request = KnowledgeNarrativePrompt.request(page),
                  let text = try? await withResourceReservation(.knowledgeGeneration(onDevice: llm.provider.kind == .appleOnDevice), {
                      try await llm.chat(systemPrompt: KnowledgeNarrativePrompt.systemPrompt,
                                         messages: [ChatMessage(role: .user, content: request.userPrompt)])
                  }),
                  let narrative = KnowledgeNarrativePrompt.parse(text, entityID: page.entity.id, references: request.references) else { continue }
            narratives.append(narrative)
        }
        return narratives
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
