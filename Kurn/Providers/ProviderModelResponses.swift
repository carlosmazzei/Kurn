import AgentHarness
import Foundation

protocol ProviderModelPage: Decodable {
    var nextPageItem: URLQueryItem? { get }
}

struct OpenAIModelListResponse: ProviderModelPage {
    struct Model: Decodable {
        struct TopProvider: Decodable {
            let contextLength: Int?
            let maxCompletionTokens: Int?
            enum CodingKeys: String, CodingKey {
                case contextLength = "context_length"
                case maxCompletionTokens = "max_completion_tokens"
            }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                contextLength = values.positiveInt(.contextLength)
                maxCompletionTokens = values.positiveInt(.maxCompletionTokens)
            }
        }
        let id: String
        let active: Bool?
        let limits: AgentModelLimits

        enum CodingKeys: String, CodingKey {
            case id, active
            case contextWindow = "context_window"
            case contextLength = "context_length"
            case maxCompletionTokens = "max_completion_tokens"
            case topProvider = "top_provider"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            active = try? values.decodeIfPresent(Bool.self, forKey: .active)
            let advertised = values.positiveInt(.contextWindow) ?? values.positiveInt(.contextLength)
            let routed = try? values.decodeIfPresent(TopProvider.self, forKey: .topProvider)
            let context = [advertised, routed?.contextLength].compactMap { $0 }.filter { $0 > 0 }.min()
            let output = [values.positiveInt(.maxCompletionTokens), routed?.maxCompletionTokens]
                .compactMap { $0 }.filter { $0 > 0 }.min()
            limits = AgentModelLimits(contextWindowTokens: context, maxOutputTokens: output)
        }
    }
    let data: [Model]
    var nextPageItem: URLQueryItem? { nil }
}

struct AnthropicModelListResponse: ProviderModelPage {
    struct Model: Decodable {
        let id: String
        let limits: AgentModelLimits
        enum CodingKeys: String, CodingKey {
            case id
            case maxInputTokens = "max_input_tokens"
            case maxTokens = "max_tokens"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            limits = AgentModelLimits(contextWindowTokens: values.positiveInt(.maxInputTokens),
                                      maxOutputTokens: values.positiveInt(.maxTokens), limitKind: .input)
        }
    }
    let data: [Model]
    let hasMore: Bool?
    let lastID: String?
    enum CodingKeys: String, CodingKey { case data; case hasMore = "has_more"; case lastID = "last_id" }

    var nextPageItem: URLQueryItem? {
        hasMore == true ? URLQueryItem(name: "after_id", value: lastID) : nil
    }
}

struct GoogleModelListResponse: ProviderModelPage {
    struct Model: Decodable {
        let name: String
        let supportedGenerationMethods: [String]
        let limits: AgentModelLimits
        /// Whether the model supports thinking, when the listing says so.
        let thinking: Bool?
        var requestID: String { name.hasPrefix("models/") ? String(name.dropFirst(7)) : name }
        enum CodingKeys: String, CodingKey { case name, supportedGenerationMethods, inputTokenLimit, outputTokenLimit, thinking }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decode(String.self, forKey: .name)
            supportedGenerationMethods = try values.decode([String].self, forKey: .supportedGenerationMethods)
            limits = AgentModelLimits(contextWindowTokens: values.positiveInt(.inputTokenLimit),
                                      maxOutputTokens: values.positiveInt(.outputTokenLimit), limitKind: .input)
            thinking = try? values.decodeIfPresent(Bool.self, forKey: .thinking)
        }
    }
    let models: [Model]
    let nextPageToken: String?
    var nextPageItem: URLQueryItem? { nextPageToken.map { URLQueryItem(name: "pageToken", value: $0) } }
}

private extension KeyedDecodingContainer {
    func positiveInt(_ key: Key) -> Int? {
        guard let value = try? decodeIfPresent(Int.self, forKey: key), value > 0, value <= 100_000_000 else { return nil }
        return value
    }
}
