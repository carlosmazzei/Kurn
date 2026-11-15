import Foundation
import Testing
@testable import KurnCore

@Suite struct ChatDocumentEditTests {
    @Test func plansCreationReplacementAndAppendWithoutMutatingOriginalValues() throws {
        let first = try ChatDocumentEdit.create(title: "Report", markdown: "Initial").applying(to: [])
        #expect(first.artifact.version == 1 && first.artifacts == [first.artifact])
        let second = try ChatDocumentEdit.update(first.artifact.id, title: "Revised", markdown: "Replacement").applying(to: first.artifacts)
        #expect(second.artifact.title == "Revised" && second.artifact.markdown == "Replacement" && second.artifact.version == 2)
        let third = try ChatDocumentEdit.append(first.artifact.id, markdown: "Appendix").applying(to: second.artifacts)
        #expect(third.artifact.markdown == "Replacement\n\nAppendix" && third.artifact.version == 3)
        #expect(first.artifact.markdown == "Initial")
        let preserved = try ChatDocumentEdit.update(first.artifact.id, title: nil, markdown: "Body").applying(to: second.artifacts)
        #expect(preserved.artifact.title == "Revised")
    }

    @Test func rejectsUnknownIDsInvalidBodiesAndOverflowBeforePublishing() throws {
        let original = ChatDocumentArtifact(title: "Report", markdown: "Initial")
        for edit in [ChatDocumentEdit.append(UUID(), markdown: "Text"), .update(UUID(), title: nil, markdown: "Text"),
                     .append(original.id, markdown: "  "), .update(original.id, title: "", markdown: "Text"),
                     .create(title: "Title", markdown: "")] {
            #expect(throws: (any Error).self) { try edit.applying(to: [original]) }
        }
        let maximum = ChatDocumentArtifact(id: original.id, title: "Report", markdown: "Text", version: Int.max)
        #expect(throws: (any Error).self) { try ChatDocumentEdit.append(maximum.id, markdown: "Next").applying(to: [maximum]) }
    }

    @Test func restoreBringsBackAnEarlierVersionAsANewOne() throws {
        let first = try ChatDocumentEdit.create(title: "Report", markdown: "Initial").applying(to: [])
        let second = try ChatDocumentEdit.update(first.artifact.id, title: "Revised", markdown: "Replacement").applying(to: first.artifacts)
        let restored = try ChatDocumentEdit.restore(first.artifact).applying(to: second.artifacts)
        #expect(restored.artifact == ChatDocumentArtifact(id: first.artifact.id, title: "Report", markdown: "Initial", version: 3))
        #expect(restored.artifacts == [restored.artifact])
        // Undoing the undo brings the replacement back, again as a newer version.
        let redone = try ChatDocumentEdit.restore(second.artifact).applying(to: restored.artifacts)
        #expect(redone.artifact.markdown == "Replacement" && redone.artifact.version == 4)
        #expect(throws: (any Error).self) { try ChatDocumentEdit.restore(second.artifact).applying(to: second.artifacts) }
        #expect(throws: (any Error).self) {
            try ChatDocumentEdit.restore(ChatDocumentArtifact(title: "Other", markdown: "Text")).applying(to: second.artifacts)
        }
    }
}
