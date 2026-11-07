import Foundation
import Testing
@testable import KurnCore

struct ChatArtifactPresentationTests {
    @Test func resolvesLatestVersionAndBoundsUnicodePreview() {
        let artifact = ChatDocumentArtifact(id: UUID(), title: "Report", markdown: String(repeating: "文", count: 400), version: 3)
        let reference = ChatArtifactReference(ChatDocumentArtifact(id: artifact.id, title: "Old", markdown: "Old", version: 1))
        #expect(ChatArtifactPresentation.latest(reference, in: []) == nil)
        #expect(ChatArtifactPresentation.latest(reference, in: [artifact]) == artifact)
        #expect(ChatArtifactPresentation.preview(artifact).unicodeScalars.count == 280)
        #expect(ChatArtifactPresentation.version(reference, latest: artifact, localize: { _ in "v%d (current v%d)" }) == "v1 (current v3)")
        #expect(ChatArtifactPresentation.version(ChatArtifactReference(artifact), latest: artifact, localize: { _ in "v%d" }) == "v3")
        let empty = ChatDocumentArtifact(id: UUID(), title: "Empty", markdown: "", version: 1)
        #expect(ChatArtifactPresentation.preview(empty).isEmpty)
    }
}
