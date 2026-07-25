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
import Observation
import SwiftData

@MainActor
@Observable
final class WikiCoordinator {
    private let modelContext: ModelContext
    private let wikiService = WikiService()

    /// App-wide settings, set by `KurnApp`; the coordinator respects the
    /// `wikiEnabled` toggle and reads the configured provider/model without
    /// threading settings through callers.
    var appSettings: AppSettings?

    /// Meetings whose article is being generated, so the UI can reflect progress
    /// and repeat requests for the same meeting coalesce instead of racing.
    private(set) var generatingMeetingIDs: Set<UUID> = []
    /// True while a backfill sweep is running, so it never overlaps itself.
    private(set) var isBackfilling = false

    /// Meetings generated per foreground backfill, bounding the number of paid
    /// LLM calls per activation. The rest are picked up on later activations.
    static let backfillBatchLimit = 5

    /// Bump the suffix to force every article to regenerate when the generation
    /// prompt/format changes.
    private static let promptVersion = "wiki-v1"

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Single meeting

    /// Generate `meeting`'s article only when the feature is enabled and a key is
    /// available. Called from the transcription success path.
    func generateIfEnabled(_ meeting: Meeting?) async {
        guard appSettings?.wikiEnabled ?? false, let meeting, hasProviderKey else { return }
        await generate(meeting)
    }

    /// Build (or rebuild) `meeting`'s wiki article. Skips the LLM call when the
    /// transcript and generator both match the existing article, so a redundant
    /// trigger is cheap. Best-effort: an offline/no-key/transient failure leaves
    /// any existing article in place and is retried on a later pass.
    func generate(_ meeting: Meeting) async {
        let meetingID = meeting.id
        guard !generatingMeetingIDs.contains(meetingID), let settings = appSettings else { return }

        let provider = settings.aiProvider
        let model = settings.summaryModel(for: provider)
        let generator = Self.generatorIdentifier(provider: provider, model: model)

        let text = meeting.assembledTranscriptText()
        guard !text.isEmpty else { return }
        let hash = Self.contentHash(text)
        if let existing = meeting.wikiArticle,
           existing.sourceContentHash == hash, existing.generatorModelIdentifier == generator {
            return // already up to date
        }

        generatingMeetingIDs.insert(meetingID)
        defer { generatingMeetingIDs.remove(meetingID) }

        let title = meeting.aiTitle ?? meeting.title
        do {
            let markdown = try await wikiService.generate(
                transcriptText: text, meetingTitle: title, provider: provider, model: model
            )
            guard !markdown.isEmpty else { return }
            replaceArticle(
                of: meeting, markdown: markdown, hash: hash,
                generator: generator, title: title, date: meeting.createdAt
            )
            AppLog.transcription.atNotice.notice("wiki: generated meeting \(meetingID, privacy: .public)")
        } catch is CancellationError {
            // Leave any existing article in place; a later pass retries.
        } catch {
            AppLog.transcription.atError.error("wiki: failed for meeting \(meetingID, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
            await generate(meeting)
        }
    }

    /// Delete every wiki article (Settings → Clear wiki).
    func clearWiki() {
        let all = (try? modelContext.fetch(FetchDescriptor<WikiArticle>())) ?? []
        for article in all { modelContext.delete(article) }
        persist()
    }

    /// Wipe and regenerate the wiki for every transcribed meeting (Settings →
    /// Rebuild wiki). User-triggered, so it processes all meetings rather than a
    /// batch, but still needs a key.
    func rebuildWiki() async {
        clearWiki()
        guard hasProviderKey else { return }
        let meetings = ((try? modelContext.fetch(FetchDescriptor<Meeting>())) ?? [])
            .filter(\.hasAnyTranscript)
        for meeting in meetings {
            if Task.isCancelled { return }
            await generate(meeting)
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

    /// Whether the configured summary provider has an API key available.
    private var hasProviderKey: Bool {
        guard let settings = appSettings else { return false }
        return KeychainManager.shared.hasValue(for: settings.aiProvider.keychainAccount)
    }

    private static func generatorIdentifier(provider: AIProvider, model: String) -> String {
        "\(provider.rawValue):\(model):\(promptVersion)"
    }

    private static func contentHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Replace a meeting's article wholesale (delete old, insert new), so a
    /// rebuild never leaves a stale one behind.
    private func replaceArticle(
        of meeting: Meeting,
        markdown: String,
        hash: String,
        generator: String,
        title: String,
        date: Date
    ) {
        if let existing = meeting.wikiArticle { modelContext.delete(existing) }
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
            AppLog.persistence.atError.error("wiki: persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
