//
//  ContextBudgetResolutionTests.swift
//  KurnTests
//
//  Which budget a (provider, model) pair gets — the window the provider
//  reported, else the known family window, else the conservative default,
//  and always the on-device budget for Apple's model — and the store that
//  remembers reported windows.
//

import AgentHarness
import Foundation
import KurnCore
import Testing
@testable import Kurn

struct ContextBudgetResolutionTests {

    private func isolatedStore() throws -> ModelContextWindowStore {
        let suite = "ContextBudgetResolutionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return ModelContextWindowStore(defaults: defaults)
    }

    private func budget(forWindow window: Int) -> ContextBudget {
        .forContextWindow(window, reservedOutputTokens: LLMHTTP.summaryMaxOutputTokens)
    }

    @Test func theOnDeviceModelAlwaysGetsTheOnDeviceBudget() throws {
        let store = try isolatedStore()
        store.record(["on-device": 1_000_000], provider: .appleOnDevice)
        #expect(ContextBudget.resolve(provider: .appleOnDevice, model: "on-device", windows: store) == .onDevice)
    }

    @Test func anUnknownModelGetsTheConservativeBudget() throws {
        let budget = ContextBudget.resolve(provider: .openAI, model: "my-fine-tune", windows: try isolatedStore())
        #expect(budget == .conservative)
    }

    @Test func aKnownFamilyGetsItsPublishedWindow() throws {
        let store = try isolatedStore()
        #expect(ContextBudget.resolve(provider: .openAI, model: "gpt-4o-mini", windows: store) == budget(forWindow: 128_000))
        #expect(ContextBudget.resolve(provider: .anthropic, model: "claude-sonnet-4-5", windows: store) == budget(forWindow: 200_000))
    }

    @Test func aReportedWindowWinsOverTheTable() throws {
        let store = try isolatedStore()
        store.record(["gpt-4o": 64_000], provider: .openAI)
        #expect(ContextBudget.resolve(provider: .openAI, model: "gpt-4o", windows: store) == budget(forWindow: 64_000))
        // Scoped to the provider that reported it.
        #expect(ContextBudget.resolve(provider: .groq, model: "gpt-4o", windows: store) == budget(forWindow: 128_000))
    }

    @Test func theLiveResolverMatchesResolve() {
        #expect(ContextBudget.live(.appleOnDevice, "on-device") == .onDevice)
    }

    // MARK: - Store

    @Test func recordedWindowsSurviveANewStoreOverTheSameDefaults() throws {
        let suite = "ContextBudgetResolutionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        ModelContextWindowStore(defaults: defaults).record(["llama-x": 131_072], provider: .groq)
        #expect(ModelContextWindowStore(defaults: defaults).limits(for: .groq, model: "llama-x")?.contextWindowTokens == 131_072)
    }

    @Test func recordingMergesAndOverwritesPerModel() throws {
        let store = try isolatedStore()
        store.record(["a": 1_000, "b": 2_000], provider: .openAI)
        store.record(["a": 3_000], provider: .openAI)
        #expect(store.limits(for: .openAI, model: "a")?.contextWindowTokens == 3_000)
        #expect(store.limits(for: .openAI, model: "b")?.contextWindowTokens == 2_000)
    }

    @Test func nonPositiveWindowsAndEmptyIdsAreIgnored() throws {
        let store = try isolatedStore()
        store.record(["a": 4_000], provider: .openAI)
        store.record(["a": 0, "b": -1, "": 9_000], provider: .openAI)
        #expect(store.limits(for: .openAI, model: "a")?.contextWindowTokens == 4_000)
        #expect(store.limits(for: .openAI, model: "b") == nil)
        #expect(store.limits(for: .openAI, model: "") == nil)
    }

    @Test func anEmptyStoreKnowsNothing() throws {
        #expect(try isolatedStore().limits(for: .openAI, model: "a") == nil)
    }

    @Test func theAgentPlansAgainstTheRealWindowWithoutACap() throws {
        let store = try isolatedStore()
        #expect(store.agentContextWindow(for: .openAI, model: "gpt-5.4") == 1_050_000)
        #expect(store.agentContextWindow(for: .openAI, model: "my-fine-tune") == ModelContextWindows.unknownWindow)
        store.record(["gemini-2.5-pro": 1_048_576], provider: .google)
        #expect(store.agentContextWindow(for: .google, model: "gemini-2.5-pro") == 1_048_576)
    }

    @Test func endpointChangesAndExactModelIDsDoNotReuseAnotherCapacity() throws {
        let store = try isolatedStore()
        var provider = AIProvider.openAI
        store.record(["private-model": 200_000], provider: provider)
        #expect(store.resolution(for: provider, model: "private-model").source == .api)
        #expect(store.resolution(for: provider, model: "PRIVATE-model").source == .fixedFallback)
        provider.baseURLString = "https://another.example/v1"
        #expect(store.resolution(for: provider, model: "private-model").source == .fixedFallback)
    }

    @Test func endpointNormalizationIgnoresHostCaseAndTrailingSlash() throws {
        let store = try isolatedStore()
        var provider = AIProvider.openAI
        provider.baseURLString = "https://API.OPENAI.COM/v1/"
        store.record(["private-model": 64_000], provider: provider)
        provider.baseURLString = "https://api.openai.com/v1"
        #expect(store.resolution(for: provider, model: "private-model").contextWindowTokens == 64_000)
        #expect(store.resolution(for: provider, model: "private-model").source == .api)
    }

    @Test func timestampsExpireAndLegacyValuesDoNotPretendToBeAPIData() throws {
        let suite = "ContextBudgetResolutionTests.freshness.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(["openAI|gpt-6.1-terra": 32_768], forKey: "modelContextWindows.v1")
        let store = ModelContextWindowStore(defaults: defaults, now: { now })
        #expect(store.resolution(for: .openAI, model: "gpt-6.1-terra").source == .fixedTable)
        store.recordLimits(["gpt-6.1-terra": AgentModelLimits(contextWindowTokens: 64_000,
                                                             fetchedAt: now.addingTimeInterval(-86_401))], provider: .openAI)
        let expired = store.resolution(for: .openAI, model: "gpt-6.1-terra")
        #expect(expired.source == .fixedTable)
        #expect(expired.reason == .expiredMetadata)
        store.record(["gpt-6.1-terra": 64_000], provider: .openAI)
        #expect(store.resolution(for: .openAI, model: "gpt-6.1-terra").source == .api)
    }
}
