import Foundation
import Testing
import KurnCore

/// The public document use case is usable without importing an agent runtime.
struct ChatDocumentWorkspaceTests {
    @Test func domainCommandsPreserveIdentityAndReopenTheLatestRevision() async throws {
        let workspace = ChatDocumentWorkspace()
        let created = try await workspace.create(title: "Minutes", markdown: "First")
        let appended = try await workspace.append(created.id, markdown: "Second")
        #expect(appended.id == created.id)
        #expect(appended.version == 2)
        #expect(appended.markdown == "First\n\nSecond")
        let updated = try await workspace.update(created.id, markdown: "Final", title: "Final minutes")
        let restored = try ChatDocumentWorkspace(artifacts: await workspace.snapshot())
        #expect(try await restored.read(created.id) == updated)
        #expect(updated.version == 3)
    }

    @Test func failedDomainMutationRetainsThePreviousDocument() async throws {
        let workspace = ChatDocumentWorkspace()
        let created = try await workspace.create(title: "Minutes", markdown: "Body")
        await #expect(throws: ChatDocumentError.self) {
            try await workspace.update(created.id, markdown: " ", title: nil)
        }
        #expect(await workspace.snapshot() == [created])
        await #expect(throws: ChatDocumentError.self) { try await workspace.read(UUID()) }
    }
}
