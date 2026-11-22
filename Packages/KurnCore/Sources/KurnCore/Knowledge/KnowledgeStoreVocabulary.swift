//
//  KnowledgeStoreVocabulary.swift
//  KurnCore
//
//  The closed vocabularies the canonical store persists beside the assertion
//  vocabularies of `KnowledgeVocabulary.swift`: what a knowledge job does and
//  where it stands, what the review inbox holds, and what kind of event a
//  timeline is projected from. Raw values are persisted (CLAUDE.md, "Knowledge
//  Engine decisions"), so they never change once shipped; a value the store
//  cannot read back is a schema error, never a free string.
//

import Foundation

/// The work a knowledge job does. One queue schedules all of them.
public enum KnowledgeJobKind: String, Codable, Sendable, CaseIterable {
    /// Assertions, entities and evidence compiled from one transcript revision.
    case extraction
    /// The per-meeting article (`WikiArticle`), the episodic layer.
    case meetingArticle
    /// Pages, timeline and graph rebuilt from a canonical revision.
    case projection
    /// Removing what a deleted source supported.
    case deletion
}

/// Where a knowledge job stands. Cancelled, failed and deferred are distinct,
/// as for transcription (H-I6): a deferral waits for resources or a recording
/// to end and is retried; a failure has a code and a bounded retry count.
public enum KnowledgeJobState: String, Codable, Sendable, CaseIterable {
    case pending, running, deferred, succeeded, failed, cancelled

    /// Whether the job will not run again without a new request.
    public var isFinal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        case .pending, .running, .deferred: false
        }
    }
}

/// What an item in the review inbox asks the user to decide.
public enum KnowledgeReviewItemKind: String, Codable, Sendable, CaseIterable {
    case ambiguousIdentity, conflict, invalidCitation, uncertainDate, mergeCandidate, unknownTerm
}

/// Where a review item stands. A resolution can be undone, so it never
/// deletes the item.
public enum KnowledgeReviewItemState: String, Codable, Sendable, CaseIterable {
    case open, resolved, dismissed
}

/// The kind of change an event records; states are projections of events
/// (spec §5.3), never stored as the latest mention.
public enum KnowledgeEventKind: String, Codable, Sendable, CaseIterable {
    case created, statusChanged, assigned, dueDateChanged, metricReported
    case superseded, reopened, merged, contextLinked
}
