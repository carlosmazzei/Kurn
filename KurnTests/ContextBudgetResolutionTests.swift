//
//  ContextBudgetResolutionTests.swift
//  KurnTests
//
//  Which budget a (provider, model) pair gets — the window the provider
//  reported, else the known family window, else the conservative default,
//  and always the on-device budget for Apple's model — and the store that
//  remembers reported windows.
//

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
        store.record(["on-device": 1_000_000], providerID: AIProvider.appleOnDevice.id)
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
        store.record(["GPT-4o": 64_000], providerID: AIProvider.openAI.id)
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
        ModelContextWindowStore(defaults: defaults).record(["llama-x": 131_072], providerID: "groq")
        #expect(ModelContextWindowStore(defaults: defaults).window(providerID: "groq", model: "llama-x") == 131_072)
    }

    @Test func recordingMergesAndOverwritesPerModel() throws {
        let store = try isolatedStore()
        store.record(["a": 1_000, "b": 2_000], providerID: "p")
        store.record(["a": 3_000], providerID: "p")
        #expect(store.window(providerID: "p", model: "a") == 3_000)
        #expect(store.window(providerID: "p", model: "b") == 2_000)
    }

    @Test func nonPositiveWindowsAndEmptyIdsAreIgnored() throws {
        let store = try isolatedStore()
        store.record(["a": 4_000], providerID: "p")
        store.record(["a": 0, "b": -1, "": 9_000], providerID: "p")
        #expect(store.window(providerID: "p", model: "a") == 4_000)
        #expect(store.window(providerID: "p", model: "b") == nil)
        #expect(store.window(providerID: "p", model: "") == nil)
    }

    @Test func anEmptyStoreKnowsNothing() throws {
        #expect(try isolatedStore().window(providerID: "p", model: "a") == nil)
    }
}
