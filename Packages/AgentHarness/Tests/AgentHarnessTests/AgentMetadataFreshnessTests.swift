import Foundation
import Testing
@testable import AgentHarness

struct AgentMetadataFreshnessTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func partialResponsesDoNotRefreshAnOmittedField() {
        let old = now.addingTimeInterval(-90_000)
        let input = AgentModelLimits(contextWindowTokens: 64_000, maxOutputTokens: 2_000, limitKind: .input, fetchedAt: old)
        let output = AgentModelLimits(contextWindowTokens: nil, maxOutputTokens: 4_000, fetchedAt: now)
        let merged = input.merging(output, now: now)
        #expect(merged.contextWindowTokens == 64_000)
        #expect(merged.contextTimestamp == old)
        #expect(merged.outputTimestamp == now)
        #expect(merged.limitKind == .input)
        let resolution = ModelContextWindows.resolve(model: "gpt-6.1-terra", reported: merged, now: now, metadataRefresh: .failed)
        #expect(resolution.source == .fixedTable)
        #expect(resolution.reason == .expiredMetadata)
        #expect(resolution.maxOutputTokens == 4_000)
        #expect(resolution.metadataRefresh == .failed)
    }

    @Test func smallerFreshInputWinsWithoutResurrectingExpiredOutput() {
        let old = AgentModelLimits(contextWindowTokens: 1_050_000, maxOutputTokens: 256, fetchedAt: now.addingTimeInterval(-90_000))
        let next = AgentModelLimits(contextWindowTokens: 32_000, fetchedAt: now)
        let merged = old.merging(next, now: now)
        let value = ModelContextWindows.resolve(model: "gpt-6.1-terra", reported: merged, now: now, metadataRefresh: .fetched)
        #expect(value.contextWindowTokens == 32_000)
        #expect(value.maxOutputTokens == 128_000)
        #expect(value.source == .api)
        #expect(!value.isCached)
        #expect(value.fetchedAt == now)
    }

    @Test func lateResponsesCannotReplaceFreshFieldsButInvalidFutureDatesCanRecover() {
        let good = AgentModelLimits(contextWindowTokens: 32_000, maxOutputTokens: 2_000, fetchedAt: now)
        let earlier = AgentModelLimits(contextWindowTokens: 128_000, maxOutputTokens: 8_000, fetchedAt: now.addingTimeInterval(-10))
        #expect(good.merging(earlier, now: now).contextWindowTokens == 32_000)
        #expect(good.merging(earlier, now: now).maxOutputTokens == 2_000)
        let future = AgentModelLimits(contextWindowTokens: 1_000_000, fetchedAt: now.addingTimeInterval(90_000))
        #expect(future.merging(good, now: now).contextWindowTokens == 32_000)
        #expect(good.merging(future, now: now).contextWindowTokens == 32_000)
    }

    @Test func oldCacheDecodesAndNewRefreshProvenanceSurvivesReopening() throws {
        let old = #"{"contextWindowTokens":64000,"limitKind":"input","fetchedAt":800000000}"#
        let value = try JSONDecoder().decode(AgentModelLimits.self, from: Data(old.utf8))
        #expect(value.contextTimestamp == value.fetchedAt)
        let snapshot = ModelContextWindows.resolve(model: "alias", reported: value, now: value.fetchedAt, metadataRefresh: .cacheFresh)
        let decoded = try JSONDecoder().decode(AgentContextResolution.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.isCached)
        #expect(decoded.metadataRefresh == .cacheFresh)
        #expect(decoded == snapshot)
    }
}
