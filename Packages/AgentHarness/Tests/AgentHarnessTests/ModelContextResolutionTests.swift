import Foundation
import Testing
@testable import AgentHarness

struct ModelContextResolutionTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: ["gpt-6.1-terra", "gpt-6.1-sol", "gpt-6-astra", "gpt-6-luna", "gpt-5.4", "gpt-5.4-2026-03-05"])
    func largeModelsDoNotFallBackTo32k(model: String) {
        let resolved = ModelContextWindows.resolve(model: model, now: now)
        #expect(resolved.contextWindowTokens == 1_050_000)
        #expect(resolved.maxOutputTokens == 128_000)
        #expect(resolved.source == .fixedTable)
        #expect(resolved.catalogVersion == ModelContextCatalog.version)
        #expect(resolved.fetchedAt == nil)
        #expect(!AgentContextPolicy(contextWindow: resolved.contextWindowTokens).needsCompactionForTest(33_000))
    }

    @Test func exactVariantsAndUnknownModelsKeepTheirOwnCapacity() {
        #expect(ModelContextWindows.knownWindow(forModel: "gpt-5.4-mini") == 400_000)
        #expect(ModelContextWindows.knownWindow(forModel: "gpt-4.1-mini") == 1_047_576)
        #expect(ModelContextCatalog.entry(for: "gemini-2.5-flash")?.limitKind == .input)
        #expect(ModelContextCatalog.entry(for: "llama-3.3-70b-versatile")?.maxOutputTokens == 32_768)
        for name in ["gpt-6.1-terra-future", "gpt-5.4-unknown", "gpt-5.9", "custom-alias", ""] {
            let value = ModelContextWindows.resolve(model: name, now: now)
            #expect(value.contextWindowTokens == 32_768)
            #expect(value.source == .fixedFallback)
            #expect(value.reason == .unknownModel)
        }
    }

    @Test func smallerAPIWindowWinsAndPreservesItsEvidence() throws {
        let limits = AgentModelLimits(contextWindowTokens: 64_000, maxOutputTokens: 2_000,
                                      limitKind: .input, fetchedAt: now.addingTimeInterval(-60))
        let value = ModelContextWindows.resolve(model: "gpt-6.1-terra", reported: limits, now: now)
        #expect(value.contextWindowTokens == 64_000)
        #expect(value.maxOutputTokens == 2_000)
        #expect(value.limitKind == .input)
        #expect(value.source == .api)
        #expect(value.isCached)
        #expect(value.reason == .reported)
        #expect(value.fetchedAt == limits.fetchedAt)
        #expect(value.catalogVersion == nil)
        let copy = try JSONDecoder().decode(AgentContextResolution.self, from: JSONEncoder().encode(value))
        #expect(copy == value)
    }

    @Test(arguments: [-301.0, 86_400.0, 172_800.0])
    func expiredOrFutureMetadataIsNotFresh(age: TimeInterval) {
        let limits = AgentModelLimits(contextWindowTokens: 8_192, fetchedAt: now.addingTimeInterval(-age))
        let table = ModelContextWindows.resolve(model: "gpt-6.1-terra", reported: limits, now: now)
        #expect(table.source == .fixedTable)
        #expect(table.contextWindowTokens == 1_050_000)
        #expect(table.reason == .expiredMetadata)
        let unknown = ModelContextWindows.resolve(model: "private-model", reported: limits, now: now)
        #expect(unknown.source == .fixedFallback)
        #expect(unknown.reason == .expiredMetadata)
    }

    @Test func missingFieldsAndInvalidCountsAreIndependent() {
        let outputOnly = AgentModelLimits(contextWindowTokens: 0, maxOutputTokens: 1_000, fetchedAt: now)
        let value = ModelContextWindows.resolve(model: "gpt-6.1-terra", reported: outputOnly, now: now)
        #expect(value.source == .fixedTable)
        #expect(value.maxOutputTokens == 1_000)
        #expect(AgentModelLimits(contextWindowTokens: -1, maxOutputTokens: 100_000_001).contextWindowTokens == nil)
        #expect(AgentModelLimits(contextWindowTokens: -1, maxOutputTokens: 100_000_001).maxOutputTokens == nil)
        let fallback = ModelContextWindows.resolve(model: "unknown", reported: outputOnly, now: now)
        #expect(fallback.maxOutputTokens == 1_000)
    }
}

private extension AgentContextPolicy {
    func needsCompactionForTest(_ tokens: Int) -> Bool { tokens > compactionThreshold }
}
