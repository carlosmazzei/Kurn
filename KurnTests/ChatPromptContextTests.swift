import AgentHarness
import Foundation
import Testing
@testable import Kurn

/// The chat prompt's user context (today's date, time zone, locale) and the reasoning level a
/// request carries for a provider and model.
struct ChatPromptContextTests {
    private let now = Date(timeIntervalSince1970: 1_794_700_800) // 2026-11-15T00:00:00Z

    @Test func theUserContextIsTheLocalDayInEnglish() throws {
        let saoPaulo = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        let text = HarnessChatService.userContext(now: now, timeZone: saoPaulo, locale: Locale(identifier: "pt_BR"))
        // Midnight UTC is still the evening before in São Paulo.
        #expect(text.contains("today is Saturday, 2026-11-14"))
        #expect(text.contains("America/Sao_Paulo, UTC-03:00") && text.contains("locale pt_BR"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(HarnessChatService.userContext(now: now, timeZone: tokyo, locale: Locale(identifier: "ja_JP"))
            .contains("Sunday, 2026-11-15 (time zone Asia/Tokyo, UTC+09:00"))
    }

    @Test func theContextSitsBetweenTheInstructionsAndTheDocuments() throws {
        let prompt = try HarnessChatService.system(artifacts: [], now: now, timeZone: .gmt, locale: Locale(identifier: "en_US"))
        #expect(prompt.sections.map(\.name) == ["instructions", "user_context", "documents"])
        #expect(prompt.sections[0].text == HarnessChatService.instructions)
        // Another day changes only the context section.
        let tomorrow = try HarnessChatService.system(artifacts: [], now: now.addingTimeInterval(86_400), timeZone: .gmt,
                                                     locale: Locale(identifier: "en_US"))
        #expect(prompt.patch(to: tomorrow).changes.map(\.name) == ["user_context"])
    }

    @Test func aLevelIsSentOnlyWhereTheModelCanTakeIt() {
        let gpt = ChatReasoningPreference.capabilities(provider: .openAI, model: "gpt-5.4")
        #expect(ChatReasoningPreference.api(for: .openAI) == "openAIResponses")
        #expect(ChatReasoningPreference.level(.high, provider: .openAI, capabilities: gpt) == .high)
        #expect(ChatReasoningPreference.level(nil, provider: .openAI, capabilities: gpt) == nil)
        // A model known not to reason gets none.
        let older = ChatReasoningPreference.capabilities(provider: .openAI, model: "gpt-4.1-mini")
        #expect(!ChatReasoningPreference.isOffered(provider: .openAI, capabilities: older))
        #expect(ChatReasoningPreference.level(.low, provider: .openAI, capabilities: older) == nil)
        // An official vendor with an unknown model is offered; a compatible endpoint is not.
        let claude = ChatReasoningPreference.capabilities(provider: .anthropic, model: "claude-sonnet-4-5")
        #expect(claude.reasoning == .unknown && ChatReasoningPreference.isOffered(provider: .anthropic, capabilities: claude))
        let groq = ChatReasoningPreference.capabilities(provider: .groq, model: "llama-3.3-70b-versatile")
        #expect(ChatReasoningPreference.api(for: .groq) == "openAI")
        #expect(!ChatReasoningPreference.isOffered(provider: .groq, capabilities: groq))
    }

    @Test func theStoredChoiceRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "ChatPromptContextTests"))
        defaults.removePersistentDomain(forName: "ChatPromptContextTests")
        #expect(ChatReasoningPreference.stored(defaults) == nil)
        defaults.set("medium", forKey: AppSettings.Keys.chatReasoningLevel)
        #expect(ChatReasoningPreference.stored(defaults) == .medium)
        defaults.set("extreme", forKey: AppSettings.Keys.chatReasoningLevel)
        #expect(ChatReasoningPreference.stored(defaults) == nil)
        #expect(ChatReasoningPreference.level(for: .openAI, model: "gpt-5.4", defaults: defaults) == nil)
        defaults.set("low", forKey: AppSettings.Keys.chatReasoningLevel)
        #expect(ChatReasoningPreference.level(for: .openAI, model: "gpt-5.4", defaults: defaults) == .low)
    }

    @Test func theFactorySetsTheLevelOnEachVendorsClient() throws {
        let openAI = ProviderFactory.applying(.high, to: OpenAIProvider(apiKey: "k"))
        #expect((openAI as? OpenAIProvider)?.reasoning == .high)
        let anthropic = ProviderFactory.applying(.low, to: AnthropicProvider(apiKey: "k"))
        #expect((anthropic as? AnthropicProvider)?.reasoning == .low)
        let google = ProviderFactory.applying(.medium, to: GoogleProvider(apiKey: "k"))
        #expect((google as? GoogleProvider)?.reasoning == .medium)
    }
}
