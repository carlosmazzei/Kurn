//
//  KnowledgeStoreVocabularyTests.swift
//  KurnCoreTests
//
//  The persisted vocabularies of the canonical store's jobs, review items and
//  events: their raw values are on disk, so the tests pin them.
//

import Foundation
import Testing
@testable import KurnCore

struct KnowledgeStoreVocabularyTests {
    @Test func rawValuesAreThePersistedVocabulary() {
        #expect(KnowledgeJobKind.allCases.map(\.rawValue) == ["extraction", "meetingArticle", "projection", "deletion"])
        #expect(KnowledgeJobState.allCases.map(\.rawValue) == ["pending", "running", "deferred", "succeeded", "failed", "cancelled"])
        #expect(KnowledgeReviewItemKind.allCases.map(\.rawValue) == [
            "ambiguousIdentity", "conflict", "invalidCitation", "uncertainDate", "mergeCandidate", "unknownTerm"
        ])
        #expect(KnowledgeReviewItemState.allCases.map(\.rawValue) == ["open", "resolved", "dismissed"])
        #expect(KnowledgeEventKind.allCases.map(\.rawValue) == [
            "created", "statusChanged", "assigned", "dueDateChanged", "metricReported",
            "superseded", "reopened", "merged", "contextLinked"
        ])
    }

    @Test func onlySucceededFailedAndCancelledJobsAreFinal() {
        let final = KnowledgeJobState.allCases.filter(\.isFinal)
        #expect(final == [.succeeded, .failed, .cancelled])
    }

    @Test func roundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode([KnowledgeJobState.deferred])
        #expect(String(decoding: data, as: UTF8.self) == "[\"deferred\"]")
        #expect(try JSONDecoder().decode([KnowledgeJobState].self, from: data) == [.deferred])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([KnowledgeEventKind].self, from: Data("[\"lastMeetingWins\"]".utf8))
        }
    }
}
