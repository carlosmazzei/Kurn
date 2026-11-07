import Foundation
import Testing
@testable import KurnCore

struct ChatArtifactReferenceTests {
    @Test func mutationsCreateAndReviseCompactPerTurnReferences() throws {
        let first = ChatDocumentArtifact(title: "Minutes", markdown: "Private document body")
        let second = ChatDocumentArtifact(title: "Minutes", markdown: "Different body")
        let created = ChatArtifactReference.updating([], from: [], to: [first, second])
        #expect(created == [ChatArtifactReference(first), ChatArtifactReference(second)])
        let revised = ChatDocumentArtifact(id: first.id, title: "Renamed", markdown: "New body", version: 2)
        let updated = ChatArtifactReference.updating(created, from: [first, second], to: [revised, second])
        #expect(updated.map(\.version) == [2, 1])
        #expect(updated.map(\.title) == ["Renamed", "Minutes"])
        #expect(created[0].version == 1)
        let encoded = try JSONEncoder().encode(updated)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("body"))
        #expect(try JSONDecoder().decode([ChatArtifactReference].self, from: encoded) == updated)
        #expect(updated[0].label { _ in "Document: %@ v%d" } == "Document: Renamed v2")
        #expect(ChatArtifactReference.merging(created, with: [ChatArtifactReference(revised)]) == updated)
    }

    @Test func noChangesAndRemovedDocumentsKeepHistoricalReferences() {
        let artifact = ChatDocumentArtifact(title: "Report", markdown: "Body")
        let references = [ChatArtifactReference(artifact)]
        #expect(ChatArtifactReference.updating([], from: [], to: []).isEmpty)
        #expect(ChatArtifactReference.updating(references, from: [artifact], to: [artifact]) == references)
        #expect(ChatArtifactReference.updating(references, from: [artifact], to: []) == references)
    }
}
