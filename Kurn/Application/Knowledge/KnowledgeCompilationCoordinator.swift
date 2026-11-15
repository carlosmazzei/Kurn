import Foundation
import KurnCore
import Observation

/// Host producer for canonical extraction. No navigation, implicit backfill or
/// cloud activation: the disabled-by-default flag authorizes local work only.
@MainActor
@Observable
final class KnowledgeCompilationCoordinator {
    typealias Authorization = @MainActor @Sendable () -> KnowledgeExtractionAuthorization
    let jobQueue: KnowledgeJobQueue
    private let settings: AppSettings
    @ObservationIgnored private let authorization: Authorization
    @ObservationIgnored private let resolveProvider: ProviderFactory.LLMResolver
    @ObservationIgnored private let isProviderUsable: ProviderFactory.UsabilityCheck
    private(set) var lastFailureCode: String?

    // A stable host-owned default policy, rather than minting a policy revision
    // on every launch. Policy persistence/editing is part of K2.7.
    static let localPolicyID = UUID(uuid: (0x84, 0xF1, 0x65, 0xB2, 0xC4, 0x9A, 0x47, 0x01, 0xA0, 0xCC, 0x1B, 0x00, 0x00, 0x00, 0x00, 0x01))

    init(queue: KnowledgeJobQueue, settings: AppSettings, authorization: Authorization? = nil,
         resolveProvider: @escaping ProviderFactory.LLMResolver = ProviderFactory.liveLLM,
         isProviderUsable: @escaping ProviderFactory.UsabilityCheck = ProviderFactory.liveUsability) {
        jobQueue = queue
        self.settings = settings
        self.authorization = authorization ?? {
            KnowledgeExtractionAuthorization(featureEnabled: settings.knowledgeEnabled,
                policies: [.defaultDeny(id: Self.localPolicyID)], sourceClassifications: [.internal])
        }
        self.resolveProvider = resolveProvider
        self.isProviderUsable = isProviderUsable
        queue.register(kind: .extraction) { [weak self] handle in
            guard let self else { throw CancellationError() }
            try await self.perform(handle)
        }
    }

    /// A rebuild's generation is an explicit operation identity retained by its
    /// caller across retries. Regular triggers never mint a new generation.
    @discardableResult
    func compile(meetingID: UUID, scope: String = "workspace", trigger: ProviderAutomationTrigger = .automatic,
                 rebuildGeneration: UUID? = nil) async -> KnowledgeJobQueue.Outcome {
        lastFailureCode = nil
        do {
            try Task.checkCancellation()
            guard rebuildGeneration == nil || trigger == .explicit else { throw KnowledgeStoreError.invalidJob }
            let provider = settings.aiProvider
            let model = settings.summaryModel(for: provider)
            _ = try hostAuthorization(provider: provider, model: model)
            let authorize: @Sendable () async -> KnowledgeExtractionAuthorization = { [weak self] in
                guard let self else { return KnowledgeExtractionAuthorization(featureEnabled: false, policies: [], sourceClassifications: []) }
                return await self.submissionAuthorization(provider: provider, model: model)
            }
            let store = await jobQueue.writer()
            let snapshot = try await store.snapshot(meetingID: meetingID, scope: scope, provider: provider, authorization: authorize)
            guard snapshot.recordings.contains(where: { !$0.segments.isEmpty }) else { return .deferred }
            let work = try KnowledgeQueuedWork.extraction(snapshot: snapshot, provider: provider, model: model,
                rebuildGeneration: rebuildGeneration?.uuidString.lowercased())
            // Validate completed provenance/current support before the queue's
            // terminal shortcut. A -> B -> A requires an explicit new generation.
            if try await store.compilationReplay(work, authorization: authorize) != nil { return .completed }
            return try await jobQueue.submit(work, explicit: trigger == .explicit)
        } catch is CancellationError {
            return .deferred
        } catch let deferred as KnowledgeJobDeferred {
            lastFailureCode = deferred.reason.rawValue
            return .deferred
        } catch KnowledgeStoreError.policyDenied {
            lastFailureCode = "policy_denied"
            return .deferred
        } catch KnowledgeStoreError.sourceNotReady {
            lastFailureCode = "source_not_ready"
            return .deferred
        } catch {
            lastFailureCode = (error as? KnowledgeStoreError)?.rawValue ?? "compilation_failed"
            return .failed
        }
    }

    private func submissionAuthorization(provider: AIProvider, model: String) -> KnowledgeExtractionAuthorization {
        (try? hostAuthorization(provider: provider, model: model))
            ?? KnowledgeExtractionAuthorization(featureEnabled: false, policies: [], sourceClassifications: [])
    }

    private func hostAuthorization(provider: AIProvider, model: String) throws -> KnowledgeExtractionAuthorization {
        guard settings.knowledgeEnabled else { throw KnowledgeJobDeferred(reason: .featureDisabled) }
        guard settings.aiProvider == provider, settings.summaryModel(for: provider) == model else { throw KnowledgeWorkObsolete.providerChanged }
        // This is a release gate, independent of even an injected permissive
        // policy or wiki consent. No canonical transcript egress ships in K1.6.
        guard provider.kind == .appleOnDevice else { throw KnowledgeJobDeferred(reason: .cloudReviewRequired) }
        var auth = authorization()
        auth.featureEnabled = auth.featureEnabled && settings.knowledgeEnabled
        guard auth.decision(for: provider).isAllowed else { throw KnowledgeJobDeferred(reason: .policyDenied) }
        return auth
    }

    private func currentSource(_ handle: KnowledgeJobHandle) async throws -> KnowledgeStoreSnapshot {
        try Task.checkCancellation()
        guard jobQueue.mayPublish(handle), let intent = handle.work.compilation else { throw CancellationError() }
        let auth = try hostAuthorization(provider: handle.work.provider, model: handle.work.model)
        let store = await jobQueue.writer()
        let current = try await store.snapshot(meetingID: handle.work.meetingID, scope: intent.scope,
            provider: handle.work.provider, authorization: { auth })
        guard current.transcriptFingerprint == handle.work.sourceFingerprint else { throw KnowledgeWorkObsolete.sourceChanged }
        guard current.policyRevisionKey == intent.policyRevisionKey else { throw KnowledgeWorkObsolete.policyChanged }
        let latest = try hostAuthorization(provider: handle.work.provider, model: handle.work.model)
        guard KnowledgePolicyEvaluator.revisionKey(latest.policies) == intent.policyRevisionKey else { throw KnowledgeWorkObsolete.policyChanged }
        return current
    }

    /// Every service authorization boundary also refetches the authoritative
    /// source/context. Never assemble another prompt from a revoked snapshot.
    private func liveAuthorization(_ handle: KnowledgeJobHandle) async -> KnowledgeExtractionAuthorization {
        do {
            let source = try await currentSource(handle)
            var auth = try hostAuthorization(provider: handle.work.provider, model: handle.work.model)
            auth.sourceClassifications.append(source.contextClassification)
            return auth
        } catch {
            return KnowledgeExtractionAuthorization(featureEnabled: false, policies: [], sourceClassifications: [])
        }
    }

    private func perform(_ handle: KnowledgeJobHandle) async throws {
        do {
            let snapshot = try await currentSource(handle)
            guard isProviderUsable(handle.work.provider) else { throw KnowledgeJobDeferred(reason: .providerUnavailable) }
            let store = await jobQueue.writer()
            let data = try await jobQueue.progress(handle)
            var progress = try KnowledgeCompilationCheckpoint.restore(data, work: handle.work, snapshot: snapshot)
            let llm = try resolveProvider(handle.work.provider, handle.work.model)
            guard llm.provider == handle.work.provider else { throw KnowledgeWorkObsolete.providerChanged }
            let authorize: @Sendable () async -> KnowledgeExtractionAuthorization = { [weak self] in
                guard let self else { return KnowledgeExtractionAuthorization(featureEnabled: false, policies: [], sourceClassifications: []) }
                return await self.liveAuthorization(handle)
            }
            for source in snapshot.recordings where !source.segments.isEmpty && !progress.recordings.contains(where: { $0.recordingID == source.id }) {
                _ = try await currentSource(handle)
                let context = KnowledgeExtractionContext(recordedAt: source.recordedAt.ISO8601Format(),
                    timeZone: handle.work.compilation?.timeZone ?? "UTC", kind: snapshot.contextKind)
                let result = try await KnowledgeExtractionService().extract(segments: source.segments, language: source.language,
                    context: context, llm: llm, budget: .onDevice, authorization: authorize)
                _ = try await currentSource(handle)
                progress.recordings.append(try KnowledgeRecordingCompilation(recordingID: source.id, result: result))
                try await jobQueue.checkpoint(KnowledgeStoreRows.authoritativeData(progress), for: handle)
            }
            // Refresh only the canonical revision at commit, while requiring the
            // same complete source/policy. Other meetings may have committed.
            let current = try await currentSource(handle)
            let request = KnowledgeCommitRequest(snapshot: current, extractorVersion: handle.work.pipelineVersion, schemaVersion: 1,
                provider: handle.work.provider, compilations: progress.recordings, generation: handle.work.generation, lease: handle)
            _ = try await store.commit(request, authorization: authorize)
        } catch KnowledgeExtractionServiceError.policyDenied {
            _ = try await currentSource(handle) // Preserve the precise deferral/obsolescence reason.
            throw KnowledgeJobDeferred(reason: .policyDenied)
        } catch KnowledgeStoreError.sourceMissing {
            throw KnowledgeWorkObsolete.sourceDeleted
        } catch KnowledgeStoreError.policyDenied {
            throw KnowledgeJobDeferred(reason: .policyDenied)
        } catch KnowledgeStoreError.sourceNotReady {
            throw KnowledgeJobDeferred(reason: .recording)
        }
    }
}
