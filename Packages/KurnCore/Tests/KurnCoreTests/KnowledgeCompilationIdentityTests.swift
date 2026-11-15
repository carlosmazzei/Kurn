import Foundation
import Testing
@testable import KurnCore

struct KnowledgeCompilationIdentityTests {
    private let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let fingerprint = String(repeating: "a", count: 64)

    @Test func keyIsStableReversibleAndUnambiguous() throws {
        let identity = try KnowledgeCompilationIdentity(scope: "workspace:/á|1", meetingID: meetingID,
            transcriptFingerprint: fingerprint, extractorVersion: "extractor:1/2")
        let key = try identity.idempotencyKey()
        #expect(KnowledgeCompilationIdentity(idempotencyKey: key) == identity)
        #expect(try identity.idempotencyKey() == key)
        let changed = try KnowledgeCompilationIdentity(scope: "workspace", meetingID: meetingID,
            transcriptFingerprint: fingerprint, extractorVersion: "/á|1:extractor:1/2")
        #expect(try changed.idempotencyKey() != key)
    }

    @Test func everyIdentityPartDistinguishesWork() throws {
        let base = try KnowledgeCompilationIdentity(scope: "s", meetingID: meetingID, transcriptFingerprint: fingerprint, extractorVersion: "v1")
        let variants = try [
            KnowledgeCompilationIdentity(scope: "other", meetingID: meetingID, transcriptFingerprint: fingerprint, extractorVersion: "v1"),
            KnowledgeCompilationIdentity(scope: "s", meetingID: UUID(), transcriptFingerprint: fingerprint, extractorVersion: "v1"),
            KnowledgeCompilationIdentity(scope: "s", meetingID: meetingID, transcriptFingerprint: String(repeating: "b", count: 64), extractorVersion: "v1"),
            KnowledgeCompilationIdentity(scope: "s", meetingID: meetingID, transcriptFingerprint: fingerprint, extractorVersion: "v2"),
            KnowledgeCompilationIdentity(scope: "s", meetingID: meetingID, transcriptFingerprint: fingerprint, extractorVersion: "v1", schemaVersion: 2)
        ]
        let key = try base.idempotencyKey()
        for item in variants { #expect(try item.idempotencyKey() != key) }
    }

    @Test func malformedIdentitiesAndKeysFailClosed() {
        for scope in ["", " \n"] {
            #expect(throws: KnowledgeCompilationIdentityError.invalidIdentity) {
                try KnowledgeCompilationIdentity(scope: scope, meetingID: meetingID, transcriptFingerprint: fingerprint, extractorVersion: "v1")
            }
        }
        for text in ["short", String(repeating: "G", count: 64)] {
            #expect(throws: KnowledgeCompilationIdentityError.invalidIdentity) {
                try KnowledgeCompilationIdentity(scope: "s", meetingID: meetingID, transcriptFingerprint: text, extractorVersion: "v1")
            }
        }
        #expect(throws: KnowledgeCompilationIdentityError.invalidIdentity) {
            try KnowledgeCompilationIdentity(scope: "s", meetingID: meetingID, transcriptFingerprint: fingerprint, extractorVersion: " ")
        }
        #expect(throws: KnowledgeCompilationIdentityError.invalidIdentity) {
            try KnowledgeCompilationIdentity(scope: "s", meetingID: meetingID, transcriptFingerprint: fingerprint, extractorVersion: "v1", schemaVersion: 0)
        }
        for key in ["", "legacy:key", "knowledge.compile.v2:eA==", "knowledge.compile.v1:!", "knowledge.compile.v1:W10="] {
            #expect(KnowledgeCompilationIdentity(idempotencyKey: key) == nil)
        }
    }
    @Test func generatedKeysPreserveLegacyIdentityAndScopeWhileDistinguishingRebuilds() throws {
        let legacy = try KnowledgeCompilationIdentity(scope: "workspace", meetingID: meetingID,
            transcriptFingerprint: fingerprint, extractorVersion: "v1")
        let first = try KnowledgeCompilationIdentity(scope: "workspace", meetingID: meetingID,
            transcriptFingerprint: fingerprint, extractorVersion: "v1", generation: "provider/model/policy:1")
        let rebuild = try KnowledgeCompilationIdentity(scope: "workspace", meetingID: meetingID,
            transcriptFingerprint: fingerprint, extractorVersion: "v1", generation: "provider/model/policy:1/rebuild:2")
        #expect(try legacy.idempotencyKey().hasPrefix("knowledge.compile.v1:"))
        #expect(try first.idempotencyKey().hasPrefix("knowledge.compile.v2:"))
        #expect(try first.idempotencyKey() != rebuild.idempotencyKey())
        #expect(try KnowledgeCompilationIdentity(idempotencyKey: first.idempotencyKey()) == first)
        #expect(try KnowledgeCompilationIdentity(idempotencyKey: legacy.idempotencyKey()) == legacy)
        #expect(throws: KnowledgeCompilationIdentityError.invalidIdentity) {
            try KnowledgeCompilationIdentity(scope: "workspace", meetingID: meetingID,
                transcriptFingerprint: fingerprint, extractorVersion: "v1", generation: " ")
        }
    }

}
