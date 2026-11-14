import Foundation
import Testing
@testable import AgentHarness

/// The per-model capability snapshot (NH07, C03): what the bundled catalog and the provider know,
/// recorded with the run so a reopened conversation keeps the facts it was planned against.
@Suite struct AgentModelCapabilitiesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func anExactCatalogEntryGivesEveryFactAndTheVendorsCaching() {
        let gpt = ModelCapabilityCatalog.resolve(api: "openAIResponses", model: "gpt-5.4", reasoningEffort: "low", now: now)
        #expect(gpt.tools == .supported && gpt.reasoning == .supported && gpt.imageInput == .supported)
        #expect(gpt.promptCache == .automatic)
        #expect(gpt.reasoningEffort == "low")
        #expect(gpt.source == .catalog && gpt.catalogVersion == ModelCapabilityCatalog.version)
        #expect(gpt.version == AgentModelCapabilities.currentVersion)

        let older = ModelCapabilityCatalog.resolve(api: "openAIResponses", model: "gpt-4.1-mini", now: now)
        #expect(older.reasoning == .unsupported && older.tools == .supported)

        let gemini = ModelCapabilityCatalog.resolve(api: "gemini", model: "models/gemini-2.5-flash", now: now)
        #expect(gemini.reasoning == .supported && gemini.promptCache == .automatic)

        let groq = ModelCapabilityCatalog.resolve(api: "openAI", model: "llama-3.3-70b-versatile", now: now)
        #expect(groq.tools == .supported && groq.imageInput == .unsupported)
        // A compatible endpoint may or may not cache; the snapshot does not guess.
        #expect(groq.promptCache == .unknown)

        let noTools = ModelCapabilityCatalog.resolve(api: "openAIResponses", model: "o1-mini", now: now)
        #expect(noTools.tools == .unsupported)
    }

    @Test func onlyADatedSnapshotInheritsAnExactEntry() {
        let dated = ModelCapabilityCatalog.resolve(api: "openAIResponses", model: "gpt-4.1-2025-04-14", now: now)
        #expect(dated.source == .catalog && dated.tools == .supported)
        let variant = ModelCapabilityCatalog.resolve(api: "openAIResponses", model: "gpt-4o-search-preview", now: now)
        #expect(variant.source == .unknown && variant.tools == .unknown && variant.promptCache == .unknown)
        #expect(variant.catalogVersion == nil)
    }

    @Test func aClaudeFamilyRuleLeavesThinkingUnknown() {
        let claude = ModelCapabilityCatalog.resolve(api: "anthropic", model: "claude-sonnet-4-5", now: now)
        #expect(claude.source == .family && claude.tools == .supported && claude.imageInput == .supported)
        #expect(claude.reasoning == .unknown)
        #expect(claude.promptCache == .explicit)
        // A retired generation is not covered by the rule.
        #expect(ModelCapabilityCatalog.resolve(api: "anthropic", model: "claude-2.1", now: now).tools == .unknown)
    }

    @Test func freshProviderFactsOverrideTheCatalogAndQualifyAnAlias() {
        let reported = AgentReportedCapabilities(canonicalModelID: "gpt-5.4-2026-03-05", reasoning: false, fetchedAt: now)
        let value = ModelCapabilityCatalog.resolve(api: "openAIResponses", model: "my-alias", reported: reported, now: now)
        // The alias takes the canonical model's facts, and the provider's own report wins.
        #expect(value.canonicalModelID == "gpt-5.4-2026-03-05" && value.modelID == "my-alias")
        #expect(value.tools == .supported && value.reasoning == .unsupported)
        #expect(value.source == .api)

        // Expired metadata is not evidence: the alias stays unqualified and unknown.
        let stale = AgentReportedCapabilities(canonicalModelID: "gpt-5.4", reasoning: false,
                                              fetchedAt: now.addingTimeInterval(-ModelContextWindows.metadataLifetime - 1))
        let unqualified = ModelCapabilityCatalog.resolve(api: "openAIResponses", model: "my-alias", reported: stale, now: now)
        #expect(unqualified.canonicalModelID == nil && unqualified.tools == .unknown && unqualified.source == .unknown)

        // A canonical ID equal to the requested one is not an alias.
        let same = AgentReportedCapabilities(canonicalModelID: "gpt-5.4", fetchedAt: now)
        #expect(ModelCapabilityCatalog.resolve(api: "openAIResponses", model: "gpt-5.4", reported: same, now: now)
            .canonicalModelID == nil)
    }

    @Test func aSnapshotFromALaterVersionStillReads() throws {
        let json = #"{"version":3,"api":"gemini","modelID":"m","tools":"partial","reasoning":"supported","promptCache":"tiered","future":1}"#
        let value = try JSONDecoder().decode(AgentModelCapabilities.self, from: Data(json.utf8))
        #expect(value.version == 3 && value.tools == .unknown && value.reasoning == .supported)
        #expect(value.promptCache == .unknown && value.imageInput == .unknown && value.source == .unknown)

        let original = ModelCapabilityCatalog.resolve(api: "anthropic", model: "claude-opus-4-1", now: now)
        #expect(try JSONDecoder().decode(AgentModelCapabilities.self, from: JSONEncoder().encode(original)) == original)
    }

    @Test func theResolutionCarriesTheSnapshotAndOlderTracesHaveNone() throws {
        let capabilities = ModelCapabilityCatalog.resolve(api: "gemini", model: "gemini-2.5-pro", now: now)
        let resolution = ModelContextWindows.resolve(model: "gemini-2.5-pro", now: now).recordingCapabilities(capabilities)
        let decoded = try JSONDecoder().decode(AgentContextResolution.self, from: JSONEncoder().encode(resolution))
        #expect(decoded.capabilities == capabilities)

        let legacy = try JSONEncoder().encode(ModelContextWindows.resolve(model: "gemini-2.5-pro", now: now))
        #expect(!String(decoding: legacy, as: UTF8.self).contains("capabilities"))
        #expect(try JSONDecoder().decode(AgentContextResolution.self, from: legacy).capabilities == nil)
    }

    @Test func theRunStartRecordsTheSnapshot() async throws {
        let capabilities = ModelCapabilityCatalog.resolve(api: "anthropic", model: "claude-haiku-4-5", now: now)
        let resolution = ModelContextWindows.resolve(model: "claude-haiku-4-5", now: now).recordingCapabilities(capabilities)
        let store = SessionTestStore()
        try await store.appendHostEntry("question")
        let session = try AgentSession(sessionID: "session", store: store, appendMode: .branch)
        let run = try await session.start(harness: NativeHarness(model: ScriptedAgentModel([AgentTurnResponse(text: "A")])),
                                          systemPrompt: "", history: [], prompt: "Q", tools: [],
                                          contextResolution: resolution)
        do { for try await _ in run.events {} } catch {}
        _ = await session.waitUntilSettled()
        let branch = try #require(AgentRunBranch.all(in: await store.entries).first)
        #expect(branch.capabilities == capabilities)

        // A run started without a snapshot records none.
        let plain = SessionTestStore()
        try await plain.appendHostEntry("question")
        let other = try AgentSession(sessionID: "session", store: plain, appendMode: .branch)
        let second = try await other.start(harness: NativeHarness(model: ScriptedAgentModel([AgentTurnResponse(text: "A")])),
                                           systemPrompt: "", history: [], prompt: "Q", tools: [])
        do { for try await _ in second.events {} } catch {}
        _ = await other.waitUntilSettled()
        #expect(try #require(AgentRunBranch.all(in: await plain.entries).first).capabilities == nil)
    }
}
