//
//  ProviderHTTPTests+SpeechModels.swift
//  KurnTests
//
//  ElevenLabs' `/models` speech catalog behind the Read Aloud model picker.
//  An extension of `ProviderHTTPTests` rather than its own suite: it scripts
//  the process-global `MockURLProtocol`, and `.serialized` only orders tests
//  within one suite.
//

import Foundation
import Testing
@testable import Kurn

extension ProviderHTTPTests {

    @Test func elevenLabsSpeechModelsKeepOnlyTextToSpeechInListedOrder() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json([
                ["model_id": "eleven_v4", "can_do_text_to_speech": true],
                ["model_id": "eleven_english_sts_v2", "can_do_text_to_speech": false],
                ["model_id": "eleven_multilingual_v2", "can_do_text_to_speech": true],
                ["model_id": "eleven_v4", "can_do_text_to_speech": true],
                ["model_id": "no_flag"],
                ["can_do_text_to_speech": true]
            ])
        ])
        let service = ProviderModelsService(session: MockURLProtocol.session(), apiKey: "xi-secret")
        let models = await service.speechModels(for: .elevenLabs)
        #expect(models == ["eleven_v4", "eleven_multilingual_v2"])

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/models")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "xi-secret")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func elevenLabsSpeechModelsFallBackToSuggestionsOnFailure() async {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["detail": ["status": "invalid_api_key"]], status: 401)
        ])
        let service = ProviderModelsService(session: MockURLProtocol.session(), apiKey: "bad")
        let models = await service.speechModels(for: .elevenLabs)
        #expect(models == AIProvider.elevenLabs.suggestedSpeechModels)
    }

    @Test func elevenLabsSpeechModelsFallBackToSuggestionsWhenNoneSpeak() async {
        MockURLProtocol.enqueue([
            MockURLProtocol.json([
                ["model_id": "eleven_english_sts_v2", "can_do_text_to_speech": false]
            ])
        ])
        let service = ProviderModelsService(session: MockURLProtocol.session(), apiKey: "xi-secret")
        let models = await service.speechModels(for: .elevenLabs)
        #expect(models == AIProvider.elevenLabs.suggestedSpeechModels)
    }

    @Test func otherProvidersSpeechModelsAreTheSuggestionsWithoutARequest() async {
        MockURLProtocol.enqueue([])
        let service = ProviderModelsService(session: MockURLProtocol.session(), apiKey: "sk")
        let models = await service.speechModels(for: .openAI)
        #expect(models == AIProvider.openAI.suggestedSpeechModels)
        #expect(MockURLProtocol.capturedRequests.isEmpty)
    }
}
