//
//  WikiCoordinator.swift
//  Kurn
//
//  Owns building and persisting each meeting's LLM-generated wiki article. Mirrors
//  `SemanticIndexCoordinator`: transcription completion generates the just-finished
//  meeting's article, and a launch/foreground backfill sweeps meetings that have no
//  article yet (or one from a different provider/model). All SwiftData reads/writes
//  happen here on the main actor; the LLM call runs off-main in `WikiService`.
//
//  Unlike the on-device semantic index, wiki generation makes CLOUD LLM calls, so
//  it is OPT-IN (`AppSettings.wikiEnabled`, off by default), gated on an available
//  API key, generation is skipped when the transcript hasn't changed, and the
//  backfill processes only a small batch per foreground activation to bound cost.
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

    private let modelContext: ModelContext
    private let wikiService = WikiService()
    private let providerCircuitBreaker: ProviderCircuitBreaker

    /// App-wide settings, set by `KurnApp`; the coordinator respects the
    /// `wikiEnabled` toggle and reads the configured provider/model without
    /// threading settings through callers.
    var appSettings: AppSettings?

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

    init(
        modelContext: ModelContext,
        providerCircuitBreaker: ProviderCircuitBreaker = .shared
    ) {
        self.modelContext = modelContext
        self.providerCircuitBreaker = providerCircuitBreaker
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
        force: Bool = false
    ) async -> GenerationOutcome {
        let meetingID = meeting.id
        guard !generatingMeetingIDs.contains(meetingID), let settings = appSettings else {
            return .skipped
        }

        let provider = settings.aiProvider
        guard await providerCircuitBreaker.allows(providerID: provider.id, trigger: trigger) else {
            AppLog.transcription.atInfo.info("wiki: provider circuit blocked automatic generation")
            return .skipped
        }
        let model = settings.summaryModel(for: provider)
        let generator = Self.generatorIdentifier(provider: provider, model: model)

        let text = meeting.assembledTranscriptText()
        guard !text.isEmpty else { return .skipped }
        let hash = Self.contentHash(text)
        if !force, let existing = meeting.wikiArticle,
           existing.sourceContentHash == hash, existing.generatorModelIdentifier == generator {
            return .skipped // already up to date
        }

        generatingMeetingIDs.insert(meetingID)
        defer { generatingMeetingIDs.remove(meetingID) }

        let title = meeting.aiTitle ?? meeting.title
        // A checkpoint from an earlier interrupted staged run (H4), shared
        // with summary generation since both delegate the map stage to the
        // same `SummaryService.notesTemplate` — see `SummaryMapCheckpoint`'s
        // header. A structurally invalid one is treated the same as none.
        let resumeCheckpoint = meeting.summaryMapCheckpoint.flatMap { $0.isStructurallyValid ? $0 : nil }
        let runID = OperationID()
        let startedAt = Date()
        do {
            let markdown = try await wikiService.generate(
                transcriptText: text, meetingTitle: title, provider: provider, model: model,
                resume: resumeCheckpoint,
                onMapStageCompleted: { [weak self] checkpoint in
                    try await self?.storeSummaryMapCheckpointDurably(checkpoint, forMeetingID: meetingID)
                }
            )
            try Task.checkCancellation()
            guard !markdown.isEmpty, !Task.isCancelled else { return .skipped }
            // The staged run (if any) is fully done, so the checkpoint that
            // got it here no longer describes work still owed (H4).
            // `replaceArticle` below persists this alongside the new article.
            meeting.summaryMapCheckpoint = nil
            replaceArticle(
                of: meeting, markdown: markdown, hash: hash,
                generator: generator, title: title, date: meeting.createdAt
            )
            await providerCircuitBreaker.recordSuccess(providerID: provider.id)
            AppLog.transcription.atNotice.notice("wiki: generated meeting \(meetingID, privacy: .public)")
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "wiki_generation",
                outcome: .succeeded, elapsedSeconds: Date().timeIntervalSince(startedAt)
            ))
            return .generated
        } catch is CancellationError {
            // Leave any existing article in place; a later pass retries.
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "wiki_generation",
                outcome: .cancelled, elapsedSeconds: Date().timeIntervalSince(startedAt)
            ))
            return .skipped
        } catch {
            await providerCircuitBreaker.recordFailure(
                providerID: provider.id,
                failure: ProviderCircuitFailure(error: error)
            )
            let code = (error as? AppError)?.logCode ?? "unexpected"
            AppLog.transcription.atError.error("wiki: failed for meeting \(meetingID, privacy: .public) code=\(code, privacy: .public)")
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "wiki_generation",
                outcome: .failed, elapsedSeconds: Date().timeIntervalSince(startedAt), code: code
            ))
            // Only an explicit, user-initiated run surfaces its failure —
            // an automatic background attempt stays silent-but-logged, the
            // same "best-effort, never a user-facing error" contract
            // `TranscriptionViewModel.generateAITitle` documents for its own
            // automatic path.
            if trigger == .explicit {
                lastError = (error as? AppError) ?? .wikiGenerationFailed(error.localizedDescription)
            }
            return .failed
        }
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
        return settings.aiProvider.isUsable
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
        of meeting: Meeting,
        markdown: String,
        hash: String,
        generator: String,
        title: String,
        date: Date
    ) {
        if let existing = meeting.wikiArticle {
            existing.bodyMarkdown = markdown
            existing.meetingTitleSnapshot = title
            existing.meetingDate = date
            existing.sourceContentHash = hash
            existing.generatorModelIdentifier = generator
            existing.updatedAt = Date()
            persist()
            return
        }

        let article = WikiArticle(
            meeting: meeting,
            bodyMarkdown: markdown,
            meetingTitleSnapshot: title,
            meetingDate: date,
            sourceContentHash: hash,
            generatorModelIdentifier: generator
        )
        modelContext.insert(article)
        persist()
    }

    private func persist() {
        do {
            try modelContext.save()
        } catch {
            AppLog.persistence.atError.error("wiki: persist failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
        }
    }

    /// Persist a staged wiki run's map-stage progress so an interruption
    /// resumes from the last completed block instead of re-condensing — for
    /// a cloud provider, re-paying for — every block from the start (H4).
    /// Throws (rather than merely logging, as `persist()` above does) so a
    /// save failure gates forward progress: `SummaryMapRunner` awaits this
    /// before starting the next block, and a thrown error stops the run at
    /// the last durably-committed one — the same contract
    /// `TranscriptionViewModel`'s own `storeSummaryMapCheckpointDurably` has.
    ///
    /// Takes the meeting's id rather than the `Meeting` itself: `Meeting`
    /// isn't `Sendable`, and this is called from the `@Sendable` closure
    /// `generate` hands to `WikiService.generate`.
    private func storeSummaryMapCheckpointDurably(_ checkpoint: SummaryMapCheckpoint, forMeetingID meetingID: UUID) throws {
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })
        guard let meeting = try? modelContext.fetch(descriptor).first else { return }
        meeting.summaryMapCheckpoint = checkpoint
        do {
            try modelContext.save()
        } catch {
            throw AppError.persistenceFailed(error.localizedDescription)
        }
    }
}
