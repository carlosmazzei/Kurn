import AgentHarness
import Foundation
import Testing
@testable import Kurn

/// Qualification against the real providers: one agent run per vendor whose key is set, through the
/// app's own clients and the harness, with a tool round trip. Skipped unless `KURN_LIVE_SMOKE=1`
/// (the `Live provider smoke` workflow sets it, with the keys from repository secrets), so CI never
/// calls a provider. It records how long the first streamed content took and the whole run took, in
/// `[live-smoke]` lines that carry no content: no prompt, answer, key or argument.
@MainActor
struct LiveProviderSmokeTests {
    struct Target: Sendable, CustomTestStringConvertible {
        let name: String
        let provider: AIProvider
        let keyVariable: String
        var testDescription: String { name }
    }

    nonisolated static let environment = ProcessInfo.processInfo.environment
    nonisolated static let isEnabled = environment["KURN_LIVE_SMOKE"] == "1"
    nonisolated static let targets = [
        Target(name: "openai", provider: .openAI, keyVariable: "OPENAI_API_KEY"),
        Target(name: "anthropic", provider: .anthropic, keyVariable: "ANTHROPIC_API_KEY"),
        Target(name: "google", provider: .google, keyVariable: "GEMINI_API_KEY")
    ]

    /// The app's client for `target`, with the model `KURN_LIVE_SMOKE_<NAME>_MODEL` names or the
    /// provider's default.
    static func client(_ target: Target, key: String, model: String) -> any AgentModel {
        switch target.provider.kind {
        case .anthropic: return AnthropicProvider(provider: target.provider, apiKey: key, model: model)
        case .googleGemini: return GoogleProvider(provider: target.provider, apiKey: key, model: model)
        default: return OpenAIProvider(provider: target.provider, apiKey: key, model: model)
        }
    }

    /// A tool whose answer the model cannot know without calling it.
    static let addTool = AgentTool(spec: AgentToolSpec(name: "add", description: "Adds two integers and returns the sum.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["a": .object(["type": .string("integer")]), "b": .object(["type": .string("integer")])]),
            "required": .array([.string("a"), .string("b")]),
            "additionalProperties": .bool(false)
        ]))) { arguments in
        guard case .object(let values) = arguments, case .number(let a)? = values["a"], case .number(let b)? = values["b"] else {
            return AgentToolOutput(content: "Invalid arguments.", summary: "Invalid", isError: true)
        }
        // An offset the model cannot guess proves the result came from the tool.
        return AgentToolOutput(content: String(Int(a + b) + 1_000), summary: "Added")
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000) + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    @Test(.enabled(if: isEnabled), .timeLimit(.minutes(3)), arguments: targets)
    func aRunCallsAToolAndAnswers(target: Target) async throws {
        guard let key = Self.environment[target.keyVariable], !key.isEmpty else {
            print("[live-smoke] provider=\(target.name) skipped=no_key")
            return
        }
        let model = Self.environment["KURN_LIVE_SMOKE_\(target.name.uppercased())_MODEL"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? target.provider.defaultModel
        let harness = NativeHarness(model: Self.client(target, key: key, model: model), limits: AgentLimits(maxTurns: 4, maxToolCalls: 4))
        let clock = ContinuousClock()
        let started = clock.now
        var firstContent: Duration?
        var toolCalls = 0
        var outcome: AgentRunOutcome?
        for try await event in harness.run(systemPrompt: "You are a calculator. Always use the add tool to add numbers.",
                                           history: [], prompt: "What is 17 plus 25? Use the tool, then reply with the number only.",
                                           tools: [Self.addTool], maxOutputTokens: 1_024) {
            switch event {
            case .textDelta(let text) where !text.isEmpty: firstContent = firstContent ?? started.duration(to: clock.now)
            case .modelContent: firstContent = firstContent ?? started.duration(to: clock.now)
            case .toolFinished(_, _, _, let isError): toolCalls += 1; #expect(!isError)
            case .runFinished(let finished): outcome = finished
            default: break
            }
        }
        let total = started.duration(to: clock.now)
        let finished = try #require(outcome)
        print("[live-smoke] provider=\(target.name) model=\(model)"
              + " first_content_ms=\(firstContent.map(Self.milliseconds).map(String.init) ?? "none")"
              + " total_ms=\(Self.milliseconds(total)) tool_calls=\(toolCalls) stop=\(finished.stopReason.rawValue)"
              + " input_tokens=\(finished.totalUsage.inputTokens) output_tokens=\(finished.totalUsage.outputTokens)"
              + " cache_read_tokens=\(finished.totalUsage.cacheReadTokens.map(String.init) ?? "unreported")")
        #expect(finished.stopReason == .completed)
        #expect(toolCalls >= 1)
        #expect(finished.finalText.contains("1042"))
    }

    @Test func targetsMapToTheAppsClients() {
        #expect(Self.client(Self.targets[0], key: "k", model: "m") is OpenAIProvider)
        #expect(Self.client(Self.targets[1], key: "k", model: "m") is AnthropicProvider)
        #expect(Self.client(Self.targets[2], key: "k", model: "m") is GoogleProvider)
        #expect(Self.milliseconds(.milliseconds(1_250)) == 1_250)
    }

    @Test func theAddToolAddsWithItsOffsetAndRejectsBadArguments() async throws {
        let sum = try await Self.addTool.execute(.object(["a": .number(17), "b": .number(25)]))
        #expect(sum.content == "1042" && !sum.isError)
        #expect(try await Self.addTool.execute(.object(["a": .string("x")])).isError)
    }
}
