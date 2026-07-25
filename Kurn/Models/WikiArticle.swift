//
//  WikiArticle.swift
//  Kurn
//
//  A persisted, LLM-generated "wiki" of one meeting: dense, structured,
//  timestamped notes condensed from the whole transcript (decisions, action
//  items, key facts, numbers, names). Unlike a `Summary`, it's not user-facing —
//  it exists to be fed into the library-wide chat's synthesis path, where a
//  handful of condensed articles fit the model's context in a way whole
//  transcripts never could, so questions that span or aggregate across meetings
//  can actually be answered.
//
//  Like `SemanticChunk`, it lives in the one app SwiftData store, so its text is
//  encrypted at rest by `ModelStoreProtection` (`.completeUnlessOpen`). One
//  article per meeting; rebuilt (not appended) whenever the transcript or the
//  generating model changes, tracked by `sourceContentHash` /
//  `generatorModelIdentifier` — the wiki analogue of `SemanticChunk`'s
//  `modelIdentifier` staleness check.
//

import Foundation
import SwiftData

@Model
final class WikiArticle {
    @Attribute(.unique) var id: UUID
    /// Owning meeting. The inverse `Meeting.wikiArticle` is `.cascade`, so
    /// deleting a meeting removes its article with the rest of its data.
    var meeting: Meeting?
    /// The condensed notes as markdown — the only consumer is the synthesis
    /// prompt (plain text), so markdown is stored directly rather than a
    /// re-decodable section structure.
    var bodyMarkdown: String
    /// Meeting title captured at generation time, so an article is a
    /// self-contained synthesis input (headed by its own title without joining
    /// back to `Meeting` off the main actor).
    var meetingTitleSnapshot: String
    /// Meeting date captured at generation time, for the same reason.
    var meetingDate: Date
    /// SHA-256 (hex) of the assembled transcript this article was built from.
    /// Regeneration is skipped when the current transcript hashes the same.
    var sourceContentHash: String
    /// "<provider>:<model>:wiki-v1" — a backfill regenerates articles whose
    /// generator no longer matches the configured provider/model, and the
    /// `wiki-vN` tag forces a rebuild when the generation prompt changes.
    var generatorModelIdentifier: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        meeting: Meeting? = nil,
        bodyMarkdown: String,
        meetingTitleSnapshot: String,
        meetingDate: Date,
        sourceContentHash: String,
        generatorModelIdentifier: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.meeting = meeting
        self.bodyMarkdown = bodyMarkdown
        self.meetingTitleSnapshot = meetingTitleSnapshot
        self.meetingDate = meetingDate
        self.sourceContentHash = sourceContentHash
        self.generatorModelIdentifier = generatorModelIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// A `Sendable` snapshot of the article, safe to hand to the off-main
    /// synthesis path. Built on the main actor (it reads the model).
    var snapshot: WikiArticleSnapshot {
        WikiArticleSnapshot(
            meetingID: meeting?.id ?? UUID(),
            title: meetingTitleSnapshot,
            date: meetingDate,
            bodyMarkdown: bodyMarkdown
        )
    }
}

/// A main-actor snapshot of one `WikiArticle`, safe to reason over off-main in
/// the library-wide chat synthesis path.
struct WikiArticleSnapshot: Sendable {
    var meetingID: UUID
    var title: String
    var date: Date
    var bodyMarkdown: String
}
