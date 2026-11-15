import Foundation
import Testing
@testable import KurnCore

private struct LegacyDomainFixture: Decodable {
    let fixtureVersion: Int
    let baselineCommit: String
    let scopes: [ChatSourceScope]
    let artifacts: [ChatDocumentArtifact]
    let references: [ChatArtifactReference]
    let legacyWikiScope: ChatSourceScope

    static func load() throws -> Self {
        let url = try #require(Bundle.module.url(forResource: "nh01-domain-v1", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        #expect(fixture.fixtureVersion == 1)
        #expect(fixture.baselineCommit == "6ec656b93c6cf59cbc3dc32f9bd08e1abb1517ed")
        return fixture
    }
}

struct ChatContractFixtureTests {
    @Test func selectedPartsEmptyOverridesAndLegacyDefaultsSurviveRoundTrip() throws {
        let fixture = try LegacyDomainFixture.load()
        #expect(fixture.scopes.map(\.kind) == [.meetings, .library, .tags, .folders])
        let selected = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000101"))
        let excluded = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000102"))
        let scope = fixture.scopes[0]
        #expect(scope.selectedIDs == [selected, excluded])
        #expect(scope.parts == [.summary, .attachments])
        #expect(scope.parts(for: selected) == [.transcript])
        #expect(scope.parts(for: excluded).isEmpty)
        #expect(fixture.legacyWikiScope.parts == ChatSourceScope.defaultParts.union([.wiki]))
        #expect(try JSONDecoder().decode([ChatSourceScope].self, from: JSONEncoder().encode(fixture.scopes)) == fixture.scopes)
    }

    @Test func artifactBodiesAndHistoricalReferencesKeepIndependentVersions() async throws {
        let fixture = try LegacyDomainFixture.load()
        let original = try #require(fixture.artifacts.first)
        #expect(original.version == 3)
        #expect(original.markdown == "# Decisões\n\nFirst\u{2028}Second\u{2029}Third")
        #expect(fixture.references.map(\.version) == [1, 3])
        #expect(fixture.references.map(\.title) == ["Initial report", "Relatório 🧭"])
        let workspace = try ChatDocumentWorkspace(artifacts: fixture.artifacts)
        let updated = try await workspace.append(original.id, markdown: "More facts")
        #expect(updated.id == original.id && updated.version == 4)
        #expect(updated.markdown == original.markdown + "\n\nMore facts")
        #expect(fixture.references.map(\.version) == [1, 3])
        #expect(try JSONDecoder().decode([ChatArtifactReference].self, from: JSONEncoder().encode(fixture.references)) == fixture.references)
    }

    @Test func invalidArtifactSnapshotsAreRejectedBeforeRestoration() throws {
        let fixture = try LegacyDomainFixture.load()
        let artifact = try #require(fixture.artifacts.first)
        let invalid = ChatDocumentArtifact(id: artifact.id, title: artifact.title, markdown: artifact.markdown, version: 0)
        #expect(throws: ChatDocumentError.self) { try ChatDocumentWorkspace(artifacts: [invalid]) }
        #expect(throws: ChatDocumentError.self) { try ChatDocumentWorkspace(artifacts: [artifact, artifact]) }
    }
}
