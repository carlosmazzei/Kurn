import AgentHarness
import Foundation
import KurnCore
import Testing
@testable import Kurn

/// K5.1 `get_coverage`: the segments the latest compilation examined, per recording, authorized
/// like every knowledge tool before and after its own read, and never carrying content.
@MainActor
struct ChatKnowledgeCoverageToolTests {
    private nonisolated static let review = UUID(), planning = UUID()
    private nonisolated static let first = UUID(), second = UUID(), third = UUID()

    private nonisolated static func read(classification: KnowledgeClassification = .internal,
                                         complete: Bool = true) -> KnowledgeCoverageRead {
        KnowledgeCoverageRead(revision: 7, isComplete: complete, meetings: [
            .init(meetingID: review, recordings: [
                .init(recordingID: first, totalSegments: 40, examinedSegments: 38, state: .current),
                .init(recordingID: second, totalSegments: 10, examinedSegments: 0, state: .sourceChanged),
            ], classification: classification),
            .init(meetingID: planning, recordings: [
                .init(recordingID: third, totalSegments: 12, examinedSegments: 0, state: .missingCompilation),
            ], classification: .internal),
        ])
    }

    private static func source(consent: Bool = true, read coverage: KnowledgeCoverageRead = read()) -> ChatKnowledgeSource {
        ChatKnowledgeSource(
            read: { _, _ in throw KnowledgeWikiStoreError.scopeDenied },
            authorization: { ids in
                KnowledgeSourceAuthorization(featureEnabled: true, meetingIDs: ids, policies: [
                    KnowledgeProcessingPolicy(allowedRemoteProviderIDs: [AIProvider.openAI.id], maxRemoteClassification: .internal),
                ], sourceClassifications: [.internal])
            },
            remoteConsent: { _ in consent },
            coverage: { _ in coverage })
    }

    private func run(_ arguments: [String: JSONValue], source: ChatKnowledgeSource? = nil) async throws -> AgentToolOutput {
        let tools = ChatKnowledgeTools.make(source: source ?? Self.source(), meetings: [Self.review, Self.planning], provider: .openAI)
        return try await #require(tools.first { $0.spec.name == "get_coverage" }).execute(.object(arguments))
    }

    @Test func coverageListsEachRecordingWithTotalsAndTheRevision() async throws {
        let output = try await run([:])
        #expect(!output.isError)
        #expect(output.content.hasPrefix("coverage: 38 of 62 segments examined in 2 meetings; 1 of 3 recordings current; complete: yes"))
        #expect(output.content.contains("- meeting \(Self.review.uuidString) | recording \(Self.first.uuidString) | state: current | 38 of 40 segments"))
        #expect(output.content.contains("recording \(Self.second.uuidString) | state: sourceChanged | 0 of 10 segments"))
        #expect(output.content.contains("- meeting \(Self.planning.uuidString) | recording \(Self.third.uuidString) | state: missingCompilation"))
        #expect(output.content.hasSuffix("revision: 7; meetings: 2"))
        let incomplete = try await run([:], source: Self.source(read: Self.read(complete: false)))
        #expect(incomplete.content.contains("complete: no"))
    }

    @Test func oneMeetingAndPagesNarrowTheList() async throws {
        let one = try await run(["meetingID": .string(Self.planning.uuidString)])
        #expect(one.content.hasPrefix("coverage: 0 of 12 segments examined in 1 meetings; 0 of 1 recordings current"))
        #expect(!one.content.contains(Self.first.uuidString))
        let paged = try await run(["limit": .number(1), "offset": .number(1)])
        #expect(paged.content.contains(Self.second.uuidString) && !paged.content.contains("| recording \(Self.first.uuidString)"))
        #expect(try await run(["meetingID": .string(UUID().uuidString)]).isError)
        #expect(try await run(["meetingID": .string("nope")]).isError)
        #expect(try await run(["extra": .number(1)]).isError)
    }

    @Test func nothingIsSentWithoutConsentOrAfterAReclassification() async throws {
        let refused = try await run([:], source: Self.source(consent: false))
        #expect(refused.isError && !refused.content.contains("segments"))
        let reclassified = try await run([:], source: Self.source(read: Self.read(classification: .confidential)))
        #expect(reclassified.isError && reclassified.content == "Knowledge tool error: Knowledge is not authorized for these sources.")
        let partial = KnowledgeCoverageRead(revision: 1, isComplete: true, meetings: [Self.read().meetings[0]])
        #expect(try await run([:], source: Self.source(read: partial)).isError)
    }

    @Test func aSourceWithoutACoverageReadFailsClosed() async throws {
        let source = ChatKnowledgeSource(read: { _, _ in throw KnowledgeWikiStoreError.scopeDenied },
                                         authorization: Self.source().authorization, remoteConsent: { _ in true })
        let failed = try await run([:], source: source)
        #expect(failed.isError && failed.content == "Knowledge tool error: Knowledge is unavailable for these sources.")
    }
}
