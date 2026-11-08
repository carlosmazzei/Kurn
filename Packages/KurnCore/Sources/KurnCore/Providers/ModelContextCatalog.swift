import AgentHarness
import Foundation

/// Bundled capacity facts, reviewed against official model cards on 2026-11-08.
/// Availability still comes from the user's endpoint. No unrecognized future variant
/// inherits a capacity just because its name begins with a familiar model name.
public enum ModelContextCatalog {
    public static let version = "2026-11-08"

    public struct Entry: Sendable, Equatable {
        public let tokens: Int
        public let maxOutputTokens: Int
        public let limitKind: AgentContextResolution.LimitKind
        public let reference: String
    }

    public static func entry(for model: String) -> Entry? {
        let name = model.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        if let entry = entries[name] { return entry }
        // Only a documented date-shaped snapshot suffix may inherit an exact model's facts.
        guard name.count > 11 else { return nil }
        let suffix = String(name.suffix(11))
        guard suffix.range(of: #"^-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return entries[String(name.dropLast(11))]
    }

    private static let entries: [String: Entry] = {
        var result: [String: Entry] = [:]
        for model in ["gpt-6.1-terra", "gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.4", "gpt-5.4-pro"] {
            result[model] = Entry(tokens: 1_050_000, maxOutputTokens: 128_000, limitKind: .combined,
                                  reference: "https://developers.openai.com/api/docs/models/\(model)")
        }
        for model in ["gpt-5.4-mini", "gpt-5.2", "gpt-5.1", "gpt-5", "gpt-5-mini", "gpt-5-nano"] {
            result[model] = Entry(tokens: 400_000, maxOutputTokens: 128_000, limitKind: .combined,
                                  reference: "https://developers.openai.com/api/docs/models/\(model)")
        }
        for model in ["gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano"] {
            result[model] = Entry(tokens: 1_047_576, maxOutputTokens: 32_768, limitKind: .combined,
                                  reference: "https://developers.openai.com/api/docs/models/\(model)")
        }
        for model in ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-3.6-flash"] {
            result[model] = Entry(tokens: 1_048_576, maxOutputTokens: 65_536, limitKind: .input,
                                  reference: "https://ai.google.dev/gemini-api/docs/models/\(model)")
        }
        result["llama-3.3-70b-versatile"] = Entry(
            tokens: 131_072, maxOutputTokens: 32_768, limitKind: .combined,
            reference: "https://console.groq.com/docs/model/llama-3.3-70b-versatile")
        return result
    }()
}
