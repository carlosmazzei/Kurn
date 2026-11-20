//
//  WikiCoordinator.swift
//  Kurn
//
//  Observable facade and article producer for the durable KnowledgeJobQueue.
//  Single, automatic and bulk requests share admission, resource reservations,
//  checkpoint/retry semantics and recording/scene lifecycle handling. Existing
//  wiki consent stays independent of the disabled-by-default canonical engine.
//  Reads and article publication use the UI context; job persistence uses the
//  queue's one writer. Recovery recognizes a saved article before any paid retry.
//

import Foundation
import CryptoKit
import KurnCore
import Observation
import SwiftData

@MainActor
@Observable
final class WikiCoordinator {
    enum GenerationOutcome: Equatable {
        case generated
        case skipped
        case failed
    }

    /// Which bulk operation `bulkOperation` is currently tracking, so the
    /// Settings screen can label its progress correctly — the two differ only
    /// in which meetings are selected and whether an up-to-date article is
    /// force-regenerated, but the UI needs to say which one is running.
    enum BulkOperationKind: Equatable {
        case missingOnly
        case rebuildAll
    }

    let jobQueue: KnowledgeJobQueue
    private var clearedGeneration = ""
    private let modelContext: ModelContext
    private let wikiService: WikiService
    private let isProviderUsable: ProviderFactory.UsabilityCheck
    private let providerCircuitBreaker: ProviderCircuitBreaker

    /// App-wide settings, injected at construction; the coordinator respects
    /// the `wikiEnabled` toggle and reads the configured provider/model without
    /// threading settings through callers. `nil` (tests) reads as the feature
    /// being off.
    let appSettings: AppSettings?

    /// Meetings whose article is being generated, so the UI can reflect progress
    /// and repeat requests for the same meeting coalesce instead of racing.
    private(set) var generatingMeetingIDs: Set<UUID> = []

    /// Most recent failure from an *explicit* run (a per-meeting menu tap, a
    /// bulk Settings run), for a view to surface via `.errorAlert`. Never set
    /// by an automatic background failure — see `generate`'s catch block.
    var lastError: AppError?
    /// True while a backfill sweep is running, so it never overlaps itself.
    private(set) var isBackfilling = false

    /// Progress of an explicit, user-triggered bulk run (Settings → Wiki),
    /// as (kind, meetings completed so far, meetings selected for this run).
    /// `nil` when no bulk run is in flight. Unlike `isBackfilling`, this is
    /// read directly by the Settings view to show real "N of M" progress
    /// instead of a plain spinner.
    private(set) var bulkOperation: (kind: BulkOperationKind, completed: Int, total: Int)?

    /// Meetings generated per foreground backfill, bounding the number of paid
    /// LLM calls per activation. The rest are picked up on later activations.
    static let backfillBatchLimit = 5

    /// Bump the suffix to force every article to regenerate when the generation
    /// prompt/format changes.
    private static let promptVersion = "wiki-v1"

    /// `wikiService` and `isProviderUsable` are the LLM call and the
    /// Keychain/on-device check; tests replace both so a run needs neither a
    /// key nor a network.
    init(
        modelContext: ModelContext,
        appSettings: AppSettings? = nil,
        providerCircuitBreaker: ProviderCircuitBreaker = .shared,
        wikiService: WikiService = WikiService(),
        isProviderUsable: @escaping ProviderFactory.UsabilityCheck = ProviderFactory.liveUsability,
        jobQueue: KnowledgeJobQueue? = nil
    ) {
        self.modelContext = modelContext
        self.appSettings = appSettings
        self.providerCircuitBreaker = providerCircuitBreaker
        self.wikiService = wikiService
        self.isProviderUsable = isProviderUsable
        let queue = jobQueue ?? KnowledgeJobQueue(container: modelContext.container)
        self.jobQueue = queue
        queue.register(kind: .meetingArticle, recovery: { [weak self] work in
            try self?.hasCommitted(work) ?? false
        }, handler: { [weak self] handle in
            guard let self else { throw CancellationError() }
            try await self.performQueued(handle)
        })
    }

    // MARK: - Single meeting

    /// Build (or rebuild) `meeting`'s wiki article. Skips the LLM call when the
    /// transcript and generator both match the existing article, so a redundant
    /// trigger is cheap. Best-effort: an offline/no-key/transient failure leaves
    /// any existing article in place and is retried on a later pass.
    @discardableResult
    func generate(
        _ meeting: Meeting,
        trigger: ProviderAutomationTrigger = .automatic,
        force: Bool = false,
        localOnly: Bool = false
    ) async -> GenerationOutcome {
        let meetingID = meeting.id
        if trigger == .explicit { lastError = nil }
        guard !generatingMeetingIDs.contains(meetingID), let settings = appSettings,
              settings.wikiEnabled || trigger == .explicit else { return .skipped }
        let provider = settings.aiProvider
        guard !localOnly || provider.kind == .appleOnDevice else { return .skipped }
        let model = settings.summaryModel(for: provider)
        let generator = Self.generatorIdentifier(provider: provider, model: model)
        let text = meeting.assembledContextText()
        guard !text.isEmpty else { return .skipped }
        let hash = Self.contentHash(text)
        if !force, let article = meeting.wikiArticle,
           article.sourceContentHash == hash, article.generatorModelIdentifier == generator { return .skipped }
        generatingMeetingIDs.insert(meetingID)
        defer { generatingMeetingIDs.remove(meetingID) }
        do {
            let work = try KnowledgeQueuedWork.article(meetingID: meetingID, generator: generator, provider: provider,
                model: model, fingerprint: hash, force: force, explicit: trigger == .explicit, generation: clearedGeneration,
                priorArticleVersion: meeting.wikiArticle.map(Self.articleVersion))
            let outcome = try await jobQueue.submit(work, explicit: trigger == .explicit, restartCompleted: true)
            switch outcome {
            case .completed: return .generated
            case .deferred: return .skipped
            case .failed: return .failed
            }
        } catch {
            if trigger == .explicit, lastError == nil { lastError = (error as? AppError) ?? .wikiGenerationFailed(error.localizedDescription) }
            return .failed
        }
    }

    private func performQueued(_ handle: KnowledgeJobHandle) async throws {
        let work = handle.work
        guard let settings = appSettings, settings.wikiEnabled || work.explicitlyRequested else {
            throw KnowledgeJobDeferred(reason: .featureDisabled)
        }
        guard settings.aiProvider == work.provider, settings.summaryModel(for: work.provider) == work.model else {
            throw KnowledgeWorkObsolete.providerChanged
        }
        let requestedMeetingID = work.meetingID
        guard let meeting = try modelContext.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == requestedMeetingID })).first else {
            throw KnowledgeWorkObsolete.sourceDeleted
        }
        let text = meeting.assembledContextText()
        guard Self.contentHash(text) == work.sourceFingerprint else { throw KnowledgeWorkObsolete.sourceChanged }
        guard jobQueue.mayPublish(handle) else { throw CancellationError() }
        if !work.force, let article = meeting.wikiArticle,
           article.sourceContentHash == work.sourceFingerprint, article.generatorModelIdentifier == work.pipelineVersion { return }
        guard await providerCircuitBreaker.allows(providerID: work.provider.id, trigger: handle.isExplicit ? .explicit : .automatic) else {
            throw KnowledgeJobDeferred(reason: .providerBlocked)
        }
        guard handle.isExplicit || isProviderUsable(work.provider) else { throw KnowledgeJobDeferred(reason: .providerUnavailable) }
        let data = try await jobQueue.progress(handle)
        let checkpoint: SummaryMapCheckpoint?
        if let data {
            let decoded = JSONStorage.decodeAuthoritative(SummaryMapCheckpoint.self, from: data)
            guard let progress = decoded.decodedValue, progress.isStructurallyValid else { throw KnowledgeQueueError.unreadableCheckpoint }
            checkpoint = progress
        } else {
            checkpoint = meeting.summaryMapCheckpoint.flatMap { $0.isStructurallyValid ? $0 : nil }
        }
        let meetingID = meeting.id
        generatingMeetingIDs.insert(meetingID)
        defer { generatingMeetingIDs.remove(meetingID) }
        let runID = OperationID()
        let startedAt = Date()
        do {
            let markdown = try await wikiService.generate(transcriptText: text, meetingTitle: meeting.aiTitle ?? meeting.title,
                provider: work.provider, model: work.model, resume: checkpoint, onMapStageCompleted: { [weak self] checkpoint in
                    guard let self else { throw CancellationError() }
                    let bytes = try KnowledgeStoreRows.authoritativeData(checkpoint)
                    try await self.jobQueue.checkpoint(bytes, for: handle)
                })
            try Task.checkCancellation()
            guard jobQueue.mayPublish(handle) else { throw CancellationError() }
            guard settings.aiProvider == work.provider, settings.summaryModel(for: work.provider) == work.model else {
                throw KnowledgeWorkObsolete.providerChanged
            }
            guard settings.wikiEnabled || work.explicitlyRequested else { throw KnowledgeJobDeferred(reason: .featureDisabled) }
            let currentMeeting = try modelContext.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == requestedMeetingID })).first
            guard let currentMeeting, Self.contentHash(currentMeeting.assembledContextText()) == work.sourceFingerprint else {
                throw KnowledgeWorkObsolete.sourceChanged
            }
            guard !markdown.isEmpty else { throw AppError.wikiGenerationFailed(NSLocalizedString("error.provider_response_empty", comment: "Empty provider response")) }
            try replaceArticle(of: currentMeeting, markdown: markdown, hash: work.sourceFingerprint, generator: work.pipelineVersion,
                title: currentMeeting.aiTitle ?? currentMeeting.title, date: currentMeeting.createdAt)
            await providerCircuitBreaker.recordSuccess(providerID: work.provider.id)
            ReliabilityLog.record(ReliabilityEvent(operationID: runID, operation: "wiki_generation", outcome: .succeeded,
                elapsedSeconds: Date().timeIntervalSince(startedAt)))
        } catch is CancellationError {
            if work.provider.kind != .appleOnDevice {
                await providerCircuitBreaker.recordFailure(providerID: work.provider.id, failure: .ambiguous)
            }
            throw CancellationError()
        } catch KnowledgeQueueError.staleLease {
            throw KnowledgeWorkObsolete.sourceDeleted
        } catch let obsolete as KnowledgeWorkObsolete {
            throw obsolete
        } catch let deferred as KnowledgeJobDeferred {
            throw deferred
        } catch {
            if case AppError.persistenceFailed = error {} else {
                await providerCircuitBreaker.recordFailure(providerID: work.provider.id, failure: ProviderCircuitFailure(error: error))
            }
            let code = (error as? AppError)?.logCode ?? "unexpected"
            ReliabilityLog.record(ReliabilityEvent(operationID: runID, operation: "wiki_generation", outcome: .failed,
                elapsedSeconds: Date().timeIntervalSince(startedAt), code: code))
            if handle.isExplicit { lastError = (error as? AppError) ?? .wikiGenerationFailed(error.localizedDescription) }
            throw error
        }
    }

    /// The article is read-only outside generation. Capture its exact previous
    /// revision rather than comparing wall clocks (which can move backwards).
    private static func articleVersion(_ article: WikiArticle) -> String {
        let identity = article.id.uuidString + ":" + String(article.updatedAt.timeIntervalSinceReferenceDate.bitPattern) + ":" + article.bodyMarkdown
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func hasCommitted(_ work: KnowledgeQueuedWork) throws -> Bool {
        let context = ModelContext(modelContext.container)
        let meetingID = work.meetingID
        guard let meeting = try context.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })).first,
              let article = meeting.wikiArticle else { return false }
        return (!work.force || Self.articleVersion(article) != work.priorArticleVersion)
            && !article.bodyMarkdown.isEmpty && article.sourceContentHash == work.sourceFingerprint
            && article.generatorModelIdentifier == work.pipelineVersion
            && Self.contentHash(meeting.assembledContextText()) == work.sourceFingerprint
    }

    // MARK: - Backfill / maintenance

    /// Generate articles for meetings that have a transcript but no up-to-date
    /// article, at most `backfillBatchLimit` per call to bound cost. Skipped when
    /// the feature is off or no API key is available. Low priority, cancellable.
    func backfill() async {
        guard appSettings?.wikiEnabled ?? false, !isBackfilling,
              let settings = appSettings, hasProviderKey else { return }
        isBackfilling = true
        defer { isBackfilling = false }

        let generator = Self.generatorIdentifier(
            provider: settings.aiProvider, model: settings.summaryModel(for: settings.aiProvider)
        )
        let stale = ((try? modelContext.fetch(FetchDescriptor<Meeting>())) ?? [])
            .filter { needsWiki($0, generator: generator) }
            .prefix(Self.backfillBatchLimit)
        guard !stale.isEmpty else { return }
        AppLog.transcription.atNotice.notice("wiki: backfill \(stale.count, privacy: .public) meeting(s)")
        for meeting in stale {
            if Task.isCancelled { return }
            if await generate(meeting) == .failed { return }
        }
    }

    /// Delete every wiki article (Settings → Clear wiki).
    func clearWiki() {
        clearedGeneration = UUID().uuidString
        jobQueue.cancel(kind: .meetingArticle)
        let all = (try? modelContext.fetch(FetchDescriptor<WikiArticle>())) ?? []
        for article in all {
            article.meeting?.wikiArticle = nil
            article.meeting = nil
            modelContext.delete(article)
        }
        persist()
    }

    /// Regenerate the wiki for every transcribed meeting, even ones already
    /// up to date (Settings → Wiki → Rebuild All). Each existing article is
    /// replaced only after its new version is ready, so cancellation or
    /// provider failure never destroys the last copy. This is the expensive
    /// option — every meeting re-pays for a fresh LLM call — kept distinct
    /// from `generateMissing()` because "the wiki looks wrong, redo
    /// everything" and "I only opted in after some meetings already
    /// happened" are different requests with very different costs.
    func rebuildWiki() async {
        guard hasProviderKey else { return }
        let meetings = ((try? modelContext.fetch(FetchDescriptor<Meeting>())) ?? [])
            .filter(\.hasAnyTranscript)
        await runBulkGeneration(.rebuildAll, over: meetings, force: true)
    }

    /// Generate articles only for meetings that don't have an up-to-date one
    /// yet (Settings → Wiki → Generate Missing) — meetings whose article
    /// already matches the current generator are skipped entirely rather
    /// than re-paying for them, unlike `rebuildWiki()`. Unlike the
    /// background `backfill()`, this is explicit and unbounded: the user
    /// asked for every missing article now, not up to `backfillBatchLimit`
    /// per foreground activation.
    func generateMissing() async {
        guard hasProviderKey, let settings = appSettings else { return }
        let generator = Self.generatorIdentifier(
            provider: settings.aiProvider, model: settings.summaryModel(for: settings.aiProvider)
        )
        let meetings = ((try? modelContext.fetch(FetchDescriptor<Meeting>())) ?? [])
            .filter { needsWiki($0, generator: generator) }
        await runBulkGeneration(.missingOnly, over: meetings, force: false)
    }

    /// Shared loop behind `rebuildWiki()`/`generateMissing()`: runs `generate`
    /// over `meetings` in order, publishing `bulkOperation` after each one so
    /// the Settings screen can show real progress instead of a plain spinner.
    /// Bails at the first outright failure (a provider error, not a skip) the
    /// same way `backfill()` does, rather than burning through the rest of a
    /// list against a provider that just started failing.
    private func runBulkGeneration(_ kind: BulkOperationKind, over meetings: [Meeting], force: Bool) async {
        guard bulkOperation == nil, !meetings.isEmpty else { return }
        bulkOperation = (kind, 0, meetings.count)
        defer { bulkOperation = nil }
        for (index, meeting) in meetings.enumerated() {
            if Task.isCancelled { return }
            if await generate(meeting, trigger: .explicit, force: force) == .failed { return }
            bulkOperation = (kind, index + 1, meetings.count)
        }
    }

    /// Number of stored articles, for the Settings status row.
    func articleCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<WikiArticle>())) ?? 0
    }

    // MARK: - Helpers

    /// A meeting needs a (re)build when it has transcript text but no article, or
    /// its article was produced by a different provider/model/prompt version.
    /// Content drift (re-transcription) is caught by the completion path, which
    /// runs `generate` and compares the transcript hash there.
    private func needsWiki(_ meeting: Meeting, generator: String) -> Bool {
        guard meeting.hasAnyTranscript else { return false }
        guard let article = meeting.wikiArticle else { return true }
        return article.generatorModelIdentifier != generator
    }

    /// Whether the configured summary provider is usable right now (a Keychain
    /// key for a cloud vendor, or a runnable model for the on-device provider).
    private var hasProviderKey: Bool {
        guard let settings = appSettings else { return false }
        return isProviderUsable(settings.aiProvider)
    }

    private static func generatorIdentifier(provider: AIProvider, model: String) -> String {
        "\(provider.rawValue):\(model):\(promptVersion)"
    }

    private static func contentHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Replace a meeting's article contents. Keep the existing model instance
    /// when present because `Meeting.wikiArticle` is a one-to-one relationship;
    /// deleting and inserting a second article for the same meeting in one
    /// context turn can trip SwiftData's relationship target check.
    private func replaceArticle(
        of meeting: Meeting, markdown: String, hash: String, generator: String, title: String, date: Date
    ) throws {
        if let existing = meeting.wikiArticle {
            let oldMarkdown = existing.bodyMarkdown
            let oldTitle = existing.meetingTitleSnapshot
            let oldDate = existing.meetingDate
            let oldHash = existing.sourceContentHash
            let oldGenerator = existing.generatorModelIdentifier
            let oldUpdatedAt = existing.updatedAt
            existing.bodyMarkdown = markdown
            existing.meetingTitleSnapshot = title
            existing.meetingDate = date
            existing.sourceContentHash = hash
            existing.generatorModelIdentifier = generator
            existing.updatedAt = Date()
            do { try modelContext.save() } catch {
                existing.bodyMarkdown = oldMarkdown
                existing.meetingTitleSnapshot = oldTitle
                existing.meetingDate = oldDate
                existing.sourceContentHash = oldHash
                existing.generatorModelIdentifier = oldGenerator
                existing.updatedAt = oldUpdatedAt
                throw AppError.persistenceFailed(error.localizedDescription)
            }
            return
        }
        let article = WikiArticle(meeting: meeting, bodyMarkdown: markdown, meetingTitleSnapshot: title,
            meetingDate: date, sourceContentHash: hash, generatorModelIdentifier: generator)
        modelContext.insert(article)
        do { try modelContext.save() } catch {
            meeting.wikiArticle = nil
            article.meeting = nil
            modelContext.delete(article)
            throw AppError.persistenceFailed(error.localizedDescription)
        }
    }

    private func persist() {
        do {
            try modelContext.save()
        } catch {
            lastError = .persistenceFailed(error.localizedDescription)
            AppLog.persistence.atError.error("wiki: persist failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
        }
    }

}
