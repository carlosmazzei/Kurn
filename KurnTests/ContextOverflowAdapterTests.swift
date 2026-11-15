import Testing
import KurnCore
@testable import Kurn

struct ContextOverflowAdapterTests {
    @Test func vendorOverflowMessagesAreRecognised() {
        let messages = [
            "This model's maximum context length is 128000 tokens. However, your messages resulted in 130000 tokens.",
            "prompt is too long: 210000 tokens > 200000 maximum",
            "The input token count (1100000) exceeds the maximum number of tokens allowed (1048576).",
            "Please reduce the length of the messages or completion.",
            "request_too_large: Request exceeds the maximum size",
            "Input is too long for requested model.",
            "This model's maximum prompt length is 131072 but the request contains 537812 tokens.",
            "prompt token count of 140000 exceeds the limit of 128000",
            "the request exceeds the available context size, try increasing it",
            "tokens to keep from the initial prompt is greater than the context length",
            "Your request exceeded model token limit: 262144 (requested: 300000)",
            "prompt too long; exceeded max context length by 500 tokens",
            "finish_reason: model_context_window_exceeded"
        ]
        for message in messages {
            #expect(AppError.apiError(statusCode: 400, message: message).isContextOverflow)
        }
        #expect(AppError.apiError(statusCode: 422, message: "context_length_exceeded").isContextOverflow)
    }

    @Test func payloadTooLargeIsAlwaysOverflow() {
        #expect(AppError.apiError(statusCode: 413, message: "Request too large for model").isContextOverflow)
    }

    @Test func otherFailuresAreNotOverflow() {
        #expect(!AppError.apiError(statusCode: 400, message: "invalid model").isContextOverflow)
        #expect(AppError.apiError(statusCode: 0, message: "Your input exceeds the context window of this model.")
            .isContextOverflow)
        #expect(!AppError.apiError(statusCode: 0, message: "Stream error").isContextOverflow)
        #expect(!AppError.apiError(statusCode: 500, message: "context length").isContextOverflow)
        #expect(!AppError.apiError(statusCode: 429, message: "rate limited").isContextOverflow)
        #expect(!AppError.summaryTruncated.isContextOverflow)
        #expect(!AppError.apiError(statusCode: 400, message: "ThrottlingException: Too many tokens, please wait")
            .isContextOverflow)
        #expect(!AppError.apiError(statusCode: 413, message: "Rate limit: too many requests").isContextOverflow)
    }
}
