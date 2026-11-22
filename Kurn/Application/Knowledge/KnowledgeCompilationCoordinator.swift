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
    let settings: AppSettings
    @ObservationIgnored private let authorization: Authorization
    @ObservationIgnored private let resolveProvider: ProviderFactory.LLMResolver
    @ObservationIgnored private let isProviderUsable: ProviderFactory.UsabilityCheck
    @ObservationIgnored private let providerCircuitBreaker: ProviderCircuitBreaker
    /// Forced explicit compiles in flight — a second tap joins silently instead
    /// of enqueueing a duplicate extraction (a fresh generation can't dedupe).
    private var forcedCompilesInFlight: Set<UUID> = []
    private(set) var lastFailureCode: String?
    /// The meeting and reason of the most recent explicit compile refusal —
    /// the tab's "Last attempt failed" row reads this so a refusal surfaces
    /// identically whether the request came from the tab or the ⋯ menu.
    private(set) var lastExplicitFailure: (meetingID: UUID, code: String)?
    /// Live per-meeting progress the tab renders while a compile runs.
    private(set) var compilationProgress: [UUID: KnowledgeCompilationProgress] = [:]
    /// The just-finished compile's outcome per meeting — the tab shows it
    /// briefly ("N new facts", or the empty-answer note) and it self-clears.
    private(set) var compilationResults: [UUID: KnowledgeCompilationResult] = [:]

    func progress(for meetingID: UUID) -> KnowledgeCompilationProgress? {
        compilationProgress[meetingID]
    }

    func result(for meetingID: UUID) -> KnowledgeCompilationResult? {
        compilationResults[meetingID]
    }

    /// The most precise public code a thrown pipeline error carries — shared
    /// by the worker's log path and the explicit-failure row so they agree.
    private static func failureCode(_ error: any Error) -> String {
        (error as? AppError)?.logCode ?? (error as? KnowledgeStoreError)?.rawValue
            ?? (error as? KnowledgeExtractionError)?.rawValue ?? (error as? KnowledgeExtractionServiceError)?.rawValue
            ?? (error as? KnowledgeQueueError)?.rawValue ?? "compilation_failed"
    }

    private func markFailure(_ code: String, meetingID: UUID, trigger: ProviderAutomationTrigger) {
        lastFailureCode = code
        if trigger == .explicit { lastExplicitFailure = (meetingID, code) }
    }

    private func setProgress(_ meetingID: UUID, phase: KnowledgeCompilationPhase,
                             provider: AIProvider, model: String) {
        var entry = compilationProgress[meetingID]
            ?? KnowledgeCompilationProgress(startedAt: Date(), providerLabel: provider.displayName, modelLabel: model)
        entry.phase = phase
        entry.fraction = phase.fractionComplete
        compilationProgress[meetingID] = entry
    }

    /// Advances the bar inside the current recording's band as each
    /// extraction pass (block) finishes, so a long single recording moves.
    private func setPassProgress(_ meetingID: UUID, recording: Int, of recordings: Int, done: Int, total: Int) {
        guard var entry = compilationProgress[meetingID], total > 0 else { return }
        let band = 0.6 / Double(max(1, recordings))
        let start = 0.15 + band * Double(max(0, recording - 1))
        entry.fraction = max(entry.fraction, start + band * min(1, Double(done) / Double(total)))
        compilationProgress[meetingID] = entry
    }

    /// Stops this meeting's running knowledge update: the in-flight provider
    /// request is cancelled, nothing is published and no failure is shown.
    func stopUpdate(meetingID: UUID) {
        guard jobQueue.cancelRunning(kind: .extraction, meetingID: meetingID) else { return }
        compilationProgress[meetingID] = nil
        AppLog.knowledge.atNotice.notice("knowledge compile stop requested meeting=\(meetingID, privacy: .private)")
    }

    private func noteExtractedFacts(_ meetingID: UUID, count: Int) {
        guard var entry = compilationProgress[meetingID] else { return }
        entry.factsSoFar += count
        compilationProgress[meetingID] = entry
    }

    // A stable host-owned default policy, rather than minting a policy revision
    // on every launch. Local controls narrow this policy; corporate policy
    // administration remains a separate reviewed capability.
    static let localPolicyID = UUID(uuid: (0x84, 0xF1, 0x65, 0xB2, 0xC4, 0x9A, 0x47, 0x01, 0xA0, 0xCC, 0x1B, 0x00, 0x00, 0x00, 0x00, 0x01))

    init(queue: KnowledgeJobQueue, settings: AppSettings, authorization: Authorization? = nil,
         resolveProvider: @escaping ProviderFactory.LLMResolver = ProviderFactory.liveLLM,
         isProviderUsable: @escaping ProviderFactory.UsabilityCheck = ProviderFactory.liveUsability,
         providerCircuitBreaker: ProviderCircuitBreaker = .shared) {
        jobQueue = queue
        self.settings = settings
        self.providerCircuitBreaker = providerCircuitBreaker
        self.authorization = authorization ?? {
            KnowledgeExtractionAuthorization(featureEnabled: settings.knowledgeEnabled,
                policies: [Self.localPolicy(settings)], sourceClassifications: [.internal],
                userConsentedToRemote: settings.knowledgeProvider.map { settings.allowsCloud($0, for: .automatic) } ?? false)
        }
        self.resolveProvider = resolveProvider
        self.isProviderUsable = isProviderUsable
        queue.register(kind: .extraction, eligibility: { [weak self] work in self?.allowsQueuedCompilation(work) == true }) { [weak self] handle in
            guard let self else { throw CancellationError() }
            try await self.perform(handle)
        }
        observeControls()
    }

    /// The local policy follows the shared cloud-consent ledger (CLAUDE.md,
    /// "Cloud consent"): it names every remote provider the person allowed,
    /// for `.internal` sources, and allows `.export` only while Knowledge export
    /// is turned on (K6.2). Its revision stays the default's: the provider
    /// set changes no derived content, so a new grant must not hide Knowledge
    /// compiled under the previous set, and every egress is re-checked live
    /// against the ledger (extraction needs the automatic grant at submission,
    /// before each request and in queue eligibility; Ask the on-request one).
    static func localPolicy(_ settings: AppSettings) -> KnowledgeProcessingPolicy {
        let remote = settings.providers
            .filter { $0.kind != .appleOnDevice && settings.allowsCloud($0, for: .onRequest) }
            .map(\.id)
        let export = settings.knowledgeExportEnabled
        guard !remote.isEmpty || export else { return .defaultDeny(id: localPolicyID) }
        return KnowledgeProcessingPolicy(id: localPolicyID, revision: KnowledgeProcessingPolicy.defaultDeny().revision,
            allowedRemoteProviderIDs: Set(remote),
            allowedOperations: KnowledgeProcessingPolicy.onDeviceOperations.union(export ? [.export] : []),
            maxRemoteClassification: remote.isEmpty ? nil : .internal, exportAllowed: export)
    }

    /// Whether Ask may send knowledge to this provider: the on-request grant.
    func allowsRemoteAnswers(with provider: AIProvider) -> Bool {
        settings.allowsCloud(provider, for: .onRequest)
    }

    /// A rebuild's generation is an explicit operation identity retained by its
    /// caller across retries. Regular triggers never mint a new generation.
    @discardableResult
    /// `force` skips the already-current replay shortcut; only the explicit
    /// path may force (a deliberate "Update knowledge" tap recompiles even
    /// when the fingerprint is unchanged).
    func compile(meetingID: UUID, scope: String = "workspace", trigger: ProviderAutomationTrigger = .automatic,
                 force: Bool = false, rebuildGeneration: UUID? = nil,
                 expectedSource: KnowledgeCompilationExpectation? = nil) async -> KnowledgeJobQueue.Outcome {
        lastFailureCode = nil
        if trigger == .explicit { lastExplicitFailure = nil }
        if force, !forcedCompilesInFlight.insert(meetingID).inserted {
            AppLog.knowledge.atInfo.info("knowledge compile coalesced meeting=\(meetingID, privacy: .private) reason=already_updating")
            return .deferred
        }
        defer { if force { forcedCompilesInFlight.remove(meetingID) } }
        do {
            try Task.checkCancellation()
            let (provider, model) = try compileProvider(meetingID: meetingID, trigger: trigger,
                force: force, rebuildGeneration: rebuildGeneration)
            let authorize: @Sendable () async -> KnowledgeExtractionAuthorization = { [weak self] in
                guard let self else { return KnowledgeExtractionAuthorization(featureEnabled: false, policies: [], sourceClassifications: []) }
                return await self.submissionAuthorization(meetingID: meetingID, provider: provider, model: model)
            }
            let store = await jobQueue.writer()
            let snapshot = try await store.snapshot(meetingID: meetingID, scope: scope, provider: provider, authorization: authorize)
            if let expectedSource {
                guard snapshot.transcriptFingerprint == expectedSource.fingerprint,
                      snapshot.policyRevisionKey == expectedSource.policyRevisionKey else { throw KnowledgeSettingsError.stalePreview }
            }
            guard snapshot.recordings.contains(where: { !$0.segments.isEmpty }) else {
                markFailure("no_transcript", meetingID: meetingID, trigger: trigger)
                AppLog.knowledge.atNotice.notice("knowledge compile deferred meeting=\(meetingID, privacy: .private) reason=no_transcript")
                return .deferred
            }
            // A forced explicit update mints a fresh generation so the queue
            // does not join the identical completed job; it stays explicit.
            let generation = rebuildGeneration ?? (force ? UUID() : nil)
            let work = try KnowledgeQueuedWork.extraction(snapshot: snapshot, provider: provider, model: model,
                rebuildGeneration: generation?.uuidString.lowercased())
            // Validate completed provenance/current support before the queue's
            // terminal shortcut. A -> B -> A requires an explicit new generation.
            if !force, try await store.compilationReplay(work, authorization: authorize) != nil {
                AppLog.knowledge.atInfo.info("knowledge compile skipped meeting=\(meetingID, privacy: .private) reason=already_current")
                return .completed
            }
            AppLog.knowledge.atNotice.notice("knowledge compile submitted meeting=\(meetingID, privacy: .private) provider=\(provider.id, privacy: .public) model=\(model, privacy: .public) explicit=\(trigger == .explicit, privacy: .public)")
            let submitted = try await jobQueue.submit(work, explicit: trigger == .explicit)
            if submitted.code == "user_cancelled" {
                AppLog.knowledge.atNotice.notice("knowledge compile stopped by the user meeting=\(meetingID, privacy: .private)")
                return .deferred
            }
            if submitted.outcome != .completed {
                markFailure(submitted.code ?? "last_attempt_failed", meetingID: meetingID, trigger: trigger)
                AppLog.knowledge.atNotice.notice("knowledge compile \(submitted.outcome == .failed ? "failed" : "deferred", privacy: .public) meeting=\(meetingID, privacy: .private) code=\(submitted.code ?? "none", privacy: .public)")
            }
            return submitted.outcome
        } catch is CancellationError {
            return .deferred
        } catch let deferred as KnowledgeJobDeferred {
            markFailure(deferred.reason.rawValue, meetingID: meetingID, trigger: trigger)
            AppLog.knowledge.atNotice.notice("knowledge compile deferred meeting=\(meetingID, privacy: .private) reason=\(deferred.reason.rawValue, privacy: .public)")
            return .deferred
        } catch KnowledgeStoreError.policyDenied {
            markFailure("policy_denied", meetingID: meetingID, trigger: trigger)
            AppLog.knowledge.atNotice.notice("knowledge compile deferred meeting=\(meetingID, privacy: .private) reason=policy_denied")
            return .deferred
        } catch KnowledgeStoreError.sourceNotReady {
            markFailure("source_not_ready", meetingID: meetingID, trigger: trigger)
            AppLog.knowledge.atNotice.notice("knowledge compile deferred meeting=\(meetingID, privacy: .private) reason=source_not_ready")
            return .deferred
        } catch {
            // `submit` rethrows the worker's failure; keep its precise code
            // (e.g. the integrity gate's `invalid_schema`) for the inline row.
            markFailure(Self.failureCode(error), meetingID: meetingID, trigger: trigger)
            AppLog.knowledge.atError.error("knowledge compile failed meeting=\(meetingID, privacy: .private) code=\(self.lastFailureCode ?? "compilation_failed", privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            return .failed
        }
    }

    /// The shared refusal chain before any work is shaped — the deferred
    /// reasons map directly onto the inline row's localized vocabulary.
    private func compileProvider(meetingID: UUID, trigger: ProviderAutomationTrigger, force: Bool,
                                 rebuildGeneration: UUID?) throws -> (provider: AIProvider, model: String) {
        guard settings.knowledgeEnabled else { throw KnowledgeJobDeferred(reason: .featureDisabled) }
        guard let controls = settings.knowledgeControls, controls.allows(meetingID) else { throw KnowledgeJobDeferred(reason: .policyDenied) }
        guard !controls.isPaused else { throw KnowledgeJobDeferred(reason: .paused) }
        guard trigger == .explicit || controls.automaticCompilation else { throw KnowledgeJobDeferred(reason: .automaticDisabled) }
        guard rebuildGeneration == nil || trigger == .explicit else { throw KnowledgeStoreError.invalidJob }
        guard !force || trigger == .explicit else { throw KnowledgeStoreError.invalidJob }
        guard let provider = settings.knowledgeProvider else { throw KnowledgeJobDeferred(reason: .providerUnavailable) }
        let model = settings.summaryModel(for: provider)
        _ = try hostAuthorization(provider: provider, model: model)
        return (provider, model)
    }

    private func submissionAuthorization(meetingID: UUID, provider: AIProvider, model: String) -> KnowledgeExtractionAuthorization {
        guard settings.knowledgeControls?.allows(meetingID) == true else {
            return KnowledgeExtractionAuthorization(featureEnabled: false, policies: [], sourceClassifications: [])
        }
        return (try? hostAuthorization(provider: provider, model: model))
            ?? KnowledgeExtractionAuthorization(featureEnabled: false, policies: [], sourceClassifications: [])
    }

    func meetingReadAuthorization(meetingID: UUID) -> KnowledgeSourceAuthorization {
        browserReadAuthorization(meetingIDs: [meetingID])
    }

    func browserReadAuthorization(meetingIDs: Set<UUID>) -> KnowledgeSourceAuthorization {
        let auth = authorization()
        let controls = settings.knowledgeControls
        return KnowledgeSourceAuthorization(featureEnabled: auth.featureEnabled && settings.knowledgeEnabled && controls != nil,
            meetingIDs: Set(meetingIDs.filter { controls?.allows($0) == true }), policies: auth.policies, sourceClassifications: auth.sourceClassifications)
    }

    /// The model that writes page narratives: the Knowledge provider under the same host checks as
    /// extraction (a cloud provider only under its automatic grant), evaluated for `.pageNarrative`
    /// over the pages' classifications. Checked once when generation starts.
    func narrativeModel(classifications: [KnowledgeClassification]) -> LLMProvider? {
        guard let provider = settings.knowledgeProvider, isProviderUsable(provider) else { return nil }
        let model = settings.summaryModel(for: provider)
        guard let auth = try? hostAuthorization(provider: provider, model: model) else { return nil }
        let destination: KnowledgeDestination = provider.kind == .appleOnDevice ? .onDevice : .remote(providerID: provider.id)
        let request = KnowledgeProcessingRequest(operation: .pageNarrative, destination: destination,
            sourceClassifications: auth.sourceClassifications + classifications, userConsentedToRemote: auth.userConsentedToRemote)
        guard KnowledgePolicyEvaluator.evaluate(request, under: auth.policies, featureEnabled: auth.featureEnabled).isAllowed,
              let llm = try? resolveProvider(provider, model), llm.provider == provider else { return nil }
        return llm
    }

    private func hostAuthorization(provider: AIProvider, model: String) throws -> KnowledgeExtractionAuthorization {
        guard settings.knowledgeEnabled else { throw KnowledgeJobDeferred(reason: .featureDisabled) }
        guard let controls = settings.knowledgeControls else { throw KnowledgeJobDeferred(reason: .policyDenied) }
        guard !controls.isPaused else { throw KnowledgeJobDeferred(reason: .paused) }
        guard settings.knowledgeProvider == provider, settings.summaryModel(for: provider) == model else { throw KnowledgeWorkObsolete.providerChanged }
        // Independent of even an injected permissive policy: transcript
        // content reaches a cloud provider only under its automatic grant.
        guard settings.allowsCloud(provider, for: .automatic) else { throw KnowledgeJobDeferred(reason: .cloudReviewRequired) }
        var auth = authorization()
        auth.featureEnabled = auth.featureEnabled && settings.knowledgeEnabled
        guard auth.decision(for: provider).isAllowed else { throw KnowledgeJobDeferred(reason: .policyDenied) }
        return auth
    }

    private func currentSource(_ handle: KnowledgeJobHandle) async throws -> KnowledgeStoreSnapshot {
        try Task.checkCancellation()
        guard jobQueue.mayPublish(handle), let intent = handle.work.compilation else { throw CancellationError() }
        guard settings.knowledgeControls?.allows(handle.work.meetingID) == true else { throw KnowledgeJobDeferred(reason: .policyDenied) }
        _ = try hostAuthorization(provider: handle.work.provider, model: handle.work.model)
        guard handle.work.pipelineVersion == KnowledgeCompilationWork.extractorVersion else { throw KnowledgeWorkObsolete.pipelineChanged }
        let store = await jobQueue.writer()
        let current = try await store.snapshot(meetingID: handle.work.meetingID, scope: intent.scope,
            provider: handle.work.provider, authorization: { [weak self] in
                guard let self else { return KnowledgeExtractionAuthorization(featureEnabled: false, policies: [], sourceClassifications: []) }
                return await self.submissionAuthorization(meetingID: handle.work.meetingID, provider: handle.work.provider, model: handle.work.model)
            })
        guard settings.knowledgeControls?.allows(handle.work.meetingID) == true else { throw KnowledgeJobDeferred(reason: .policyDenied) }
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
        let runID = OperationID()
        let started = Date()
        let meetingID = handle.work.meetingID
        setProgress(meetingID, phase: .readingTranscript, provider: handle.work.provider, model: handle.work.model)
        // Success or failure, the row leaves once the run ends.
        defer { compilationProgress[meetingID] = nil }
        do {
            try await performCompilation(handle)
            await providerCircuitBreaker.recordSuccess(providerID: handle.work.provider.id)
            ReliabilityLog.record(ReliabilityEvent(operationID: runID, operation: "knowledge_compilation", outcome: .succeeded,
                elapsedSeconds: Date().timeIntervalSince(started)))
        } catch is CancellationError {
            if handle.work.provider.kind != .appleOnDevice {
                await providerCircuitBreaker.recordFailure(providerID: handle.work.provider.id, failure: .ambiguous)
            }
            ReliabilityLog.record(ReliabilityEvent(operationID: runID, operation: "knowledge_compilation", outcome: .cancelled,
                elapsedSeconds: Date().timeIntervalSince(started), code: "interrupted"))
            throw CancellationError()
        } catch let deferred as KnowledgeJobDeferred {
            AppLog.knowledge.atNotice.notice("knowledge compilation deferred reason=\(deferred.reason.rawValue, privacy: .public)")
            throw deferred
        } catch let obsolete as KnowledgeWorkObsolete {
            AppLog.knowledge.atNotice.notice("knowledge compilation obsolete reason=\(obsolete.rawValue, privacy: .public)")
            throw obsolete
        } catch {
            await providerCircuitBreaker.recordFailure(providerID: handle.work.provider.id, failure: ProviderCircuitFailure(error: error))
            let code = Self.failureCode(error)
            AppLog.knowledge.atError.error("knowledge compilation failed code=\(code, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            ReliabilityLog.record(ReliabilityEvent(operationID: runID, operation: "knowledge_compilation", outcome: .failed,
                elapsedSeconds: Date().timeIntervalSince(started), code: code))
            throw error
        }
    }

    private func performCompilation(_ handle: KnowledgeJobHandle) async throws {
        let meetingID = handle.work.meetingID
        do {
            let snapshot = try await currentSource(handle)
            guard isProviderUsable(handle.work.provider) else { throw KnowledgeJobDeferred(reason: .providerUnavailable) }
            guard await providerCircuitBreaker.allows(providerID: handle.work.provider.id,
                trigger: handle.isExplicit ? .explicit : .automatic) else { throw KnowledgeJobDeferred(reason: .providerBlocked) }
            let store = await jobQueue.writer()
            let data = try await jobQueue.progress(handle)
            var progress = try KnowledgeCompilationCheckpoint.restore(data, work: handle.work, snapshot: snapshot)
            let llm = try resolveProvider(handle.work.provider, handle.work.model)
            guard llm.provider == handle.work.provider else { throw KnowledgeWorkObsolete.providerChanged }
            let authorize: @Sendable () async -> KnowledgeExtractionAuthorization = { [weak self] in
                guard let self else { return KnowledgeExtractionAuthorization(featureEnabled: false, policies: [], sourceClassifications: []) }
                return await self.liveAuthorization(handle)
            }
            let pendingSources = snapshot.recordings.filter { source in
                !source.segments.isEmpty && !progress.recordings.contains(where: { $0.recordingID == source.id })
            }
            var extractedFacts = 0
            var discardedFacts = 0
            let usage = TokenUsageSink()
            for (index, source) in pendingSources.enumerated() {
                setProgress(meetingID, phase: .extracting(recording: index + 1, of: pendingSources.count),
                            provider: handle.work.provider, model: handle.work.model)
                _ = try await currentSource(handle)
                let context = KnowledgeExtractionContext(recordedAt: source.recordedAt.ISO8601Format(),
                    timeZone: handle.work.compilation?.timeZone ?? "UTC", kind: snapshot.contextKind)
                AppLog.knowledge.atInfo.info("knowledge extraction recording=\(source.id, privacy: .private) segments=\(source.segments.count, privacy: .public) provider=\(handle.work.provider.id, privacy: .public) model=\(handle.work.model, privacy: .public)")
                let result = try await KnowledgeExtractionService().extract(segments: source.segments, language: source.language,
                    context: context, llm: llm, budget: handle.work.provider.kind == .appleOnDevice ? .onDevice : .conservative,
                    authorization: authorize,
                    model: handle.work.model,
                    onPass: { [weak self] done, total in
                        await self?.setPassProgress(meetingID, recording: index + 1, of: pendingSources.count, done: done, total: total)
                    })
                // A clean empty answer and a gate rejection are different
                // events: the integrity check throws before this point, so
                // zero here means the model itself asserted nothing.
                let assertionCount = result.passes.reduce(0) { $0 + $1.assertions.count }
                if assertionCount == 0 {
                    AppLog.knowledge.atNotice.notice("knowledge extraction returned zero facts recording=\(source.id, privacy: .private) reason=model_empty")
                } else {
                    AppLog.knowledge.atInfo.info("knowledge extraction facts recording=\(source.id, privacy: .private) count=\(assertionCount, privacy: .public)")
                }
                extractedFacts += assertionCount
                discardedFacts += result.discardedFacts
                if let used = result.usage { usage.add(used) }
                noteExtractedFacts(meetingID, count: assertionCount)
                _ = try await currentSource(handle)
                progress.recordings.append(try KnowledgeRecordingCompilation(recordingID: source.id, result: result))
                try await jobQueue.checkpoint(KnowledgeStoreRows.authoritativeData(progress), for: handle)
            }
            // Refresh only the canonical revision at commit, while requiring the
            // same complete source/policy. Other meetings may have committed.
            setProgress(meetingID, phase: .checking, provider: handle.work.provider, model: handle.work.model)
            let current = try await currentSource(handle)
            setProgress(meetingID, phase: .publishing, provider: handle.work.provider, model: handle.work.model)
            let request = KnowledgeCommitRequest(snapshot: current, extractorVersion: handle.work.pipelineVersion, schemaVersion: 1,
                provider: handle.work.provider, compilations: progress.recordings, generation: handle.work.generation, lease: handle)
            let receipt = try await store.commit(request, authorization: authorize)
            AppLog.knowledge.atInfo.info("knowledge compilation published meeting=\(handle.work.meetingID, privacy: .private) facts=\(receipt.assertionCount, privacy: .public)")
            // The tab's transient result note; it self-clears after a few
            // seconds unless a newer compile replaced it first.
            let totalUsage = usage.total
            let cost = totalUsage.flatMap { ModelPricing.estimatedCostUSD(model: handle.work.model, usage: $0) }
            AppLog.knowledge.atNotice.notice("knowledge compilation usage promptTokens=\(totalUsage?.promptTokens ?? 0, privacy: .public) completionTokens=\(totalUsage?.completionTokens ?? 0, privacy: .public) costUSD=\(cost.map { String(format: "%.4f", $0) } ?? "unknown", privacy: .public) discardedFacts=\(discardedFacts, privacy: .public)")
            let publishResult = KnowledgeCompilationResult(factCount: receipt.assertionCount,
                                                           modelEmpty: extractedFacts == 0 && discardedFacts == 0, finishedAt: Date(),
                                                           discardedFacts: discardedFacts, usage: totalUsage, costUSD: cost)
            compilationResults[meetingID] = publishResult
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.compilationResults[meetingID] == publishResult else { return }
                self.compilationResults[meetingID] = nil
            }
        } catch KnowledgeExtractionServiceError.policyDenied {
            _ = try await currentSource(handle) // Preserve the precise deferral/obsolescence reason.
            throw KnowledgeJobDeferred(reason: .policyDenied)
        } catch KnowledgeStoreError.sourceChanged {
            throw KnowledgeWorkObsolete.sourceChanged
        } catch KnowledgeStoreError.policyChanged {
            throw KnowledgeWorkObsolete.policyChanged
        } catch KnowledgeQueueError.staleLease {
            throw KnowledgeWorkObsolete.sourceDeleted
        } catch KnowledgeStoreError.sourceMissing {
            throw KnowledgeWorkObsolete.sourceDeleted
        } catch KnowledgeStoreError.policyDenied {
            throw KnowledgeJobDeferred(reason: .policyDenied)
        } catch KnowledgeStoreError.sourceNotReady {
            throw KnowledgeJobDeferred(reason: .recording)
        }
    }

    private func allowsQueuedCompilation(_ work: KnowledgeQueuedWork) -> Bool {
        guard settings.knowledgeEnabled, let controls = settings.knowledgeControls, !controls.isPaused,
              controls.allows(work.meetingID), let provider = settings.knowledgeProvider,
              settings.allowsCloud(provider, for: .automatic), provider == work.provider else { return false }
        return true
    }

    private func observeControls() {
        withObservationTracking {
            _ = settings.knowledgeEnabled
            _ = settings.knowledgeControls
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.jobQueue.refresh(kind: .extraction)
                self.observeControls()
            }
        }
    }
}

/// What the Wiki tab renders while a compile runs: the phase (with its own
/// fraction bands), the writer labels and the facts extracted so far.
struct KnowledgeCompilationProgress: Equatable, Sendable {
    var phase: KnowledgeCompilationPhase = .readingTranscript
    var fraction: Double = 0
    let startedAt: Date
    let providerLabel: String
    let modelLabel: String
    var factsSoFar: Int = 0
}

/// The finished compile's one-line outcome, shown briefly under the facts.
struct KnowledgeCompilationResult: Equatable, Sendable {
    /// Assertions the commit published as new.
    let factCount: Int
    /// The model answered cleanly but asserted nothing at all.
    let modelEmpty: Bool
    let finishedAt: Date
    /// Well-formed facts dropped for breaking a domain rule.
    var discardedFacts = 0
    /// Vendor-reported tokens and their estimated cost, when known.
    var usage: TokenUsage?
    var costUSD: Double?
}
