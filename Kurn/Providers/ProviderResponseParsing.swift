//
//  ProviderResponseParsing.swift
//  Kurn
//

import Foundation
import KurnCore

extension LLMHTTP {
    /// Decode a summary response, extract its text content, and parse the shared
    /// JSON contract into a `SummaryResult`. Centralizes the decode→parse→error
    /// flow every provider's `summarize` shares. `isTruncated` inspects the
    /// vendor's finish/stop reason: a generation cut off by the output-token cap
    /// is syntactically broken JSON, so surface the specific truncation error
    /// instead of the confusing decode failure it would otherwise become. The
    /// first catch deliberately re-throws `AppError`s (e.g. the empty-content
    /// and `SummaryJSON.parse` failures) so they aren't re-wrapped by the
    /// generic `decodingError` catch.
    static func summaryResult<T: Decodable>(
        from data: Data,
        as type: T.Type,
        emptyMessage: String,
        isTruncated: (T) -> Bool = { _ in false },
        extractContent: (T) -> String?
    ) throws -> SummaryResult {
        do {
            let decoded = try JSONDecoder().decode(type, from: data)
            guard !isTruncated(decoded) else {
                throw AppError.summaryTruncated
            }
            guard let content = extractContent(decoded), !content.isEmpty else {
                throw AppError.decodingError(emptyMessage)
            }
            let json = try SummaryJSON.parse(content)
            return SummaryResult(sections: json.summarySections)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.decodingError(error.localizedDescription)
        }
    }

    /// Decode a chat response and extract its plain-text content. The
    /// text sibling of `summaryResult`: no JSON-section parsing, just the
    /// model's reply. Re-throws `AppError`s (e.g. the empty-content failure) so
    /// they aren't re-wrapped by the generic decode catch.
    static func textResult<T: Decodable>(
        from data: Data,
        as type: T.Type,
        emptyMessage: String,
        isTruncated: (T) -> Bool = { _ in false },
        extractContent: (T) -> String?
    ) throws -> String {
        do {
            let decoded = try JSONDecoder().decode(type, from: data)
            guard !isTruncated(decoded) else {
                throw AppError.generationTruncated
            }
            guard let content = extractContent(decoded)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else {
                throw AppError.decodingError(emptyMessage)
            }
            return content
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.decodingError(error.localizedDescription)
        }
    }
}

// MARK: - Shared response shape (OpenAI-compatible)

/// Chat Completions response shared by OpenAI and the OpenAI-compatible Groq API.
struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            // Reasoning models can return `content: null` when the output-token
            // budget is exhausted before visible text is produced. Refusals
            // likewise arrive separately from normal content.
            let content: String?
            let refusal: String?
        }
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]

    /// True when generation stopped because it hit the output-token cap, which
    /// leaves the JSON payload cut off mid-structure.
    var isTruncated: Bool { choices.first?.finishReason == "length" }
}

// `SummaryJSON` and `ModelJSON` live in KurnCore so their decoding contracts
// remain reusable without depending on the provider transport layer.
