//
//  SystemSpeechEngine.swift
//  Kurn
//
//  The two ways `ReadAloudController` can speak, behind one small protocol:
//  the on-device `AVSpeechSynthesizer` here, and cloud audio played back by
//  `CloudSpeechEngine`. Both take the whole list of chunks and a starting
//  index, so skipping is just "stop, start again at another index".
//

import AVFoundation
import Foundation
import KurnCore
import NaturalLanguage

@MainActor
protocol ReadAloudEngine: AnyObject {
    /// A chunk began playing (after any network fetch it needed).
    var onChunkStarted: ((Int) -> Void)? { get set }
    /// The last chunk finished.
    var onFinished: (() -> Void)? { get set }
    var onFailed: ((AppError) -> Void)? { get set }

    func start(_ chunks: [String], at index: Int)
    func pause()
    func resume()
    func stop()
}

/// Reads with the system voices: no key, no network, available offline on
/// every device — which is why it is the default.
@MainActor
final class SystemSpeechEngine: NSObject, ReadAloudEngine {
    var onChunkStarted: ((Int) -> Void)?
    var onFinished: (() -> Void)?
    var onFailed: ((AppError) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private let rate: Float
    /// Chunk index per queued utterance. Utterances are not `Sendable`, so
    /// the delegate hops to the main actor with their identity only.
    private var indices: [ObjectIdentifier: Int] = [:]
    private var lastIndex = 0

    init(voiceIdentifier: String, languageCode: String?, rate: Float) {
        self.voice = Self.voice(identifier: voiceIdentifier, languageCode: languageCode)
        self.rate = Self.utteranceRate(for: rate)
        super.init()
        synthesizer.delegate = self
    }

    func start(_ chunks: [String], at index: Int) {
        stop()
        guard chunks.indices.contains(index) else {
            onFinished?()
            return
        }
        lastIndex = chunks.count - 1
        for position in index..<chunks.count {
            let utterance = AVSpeechUtterance(string: chunks[position])
            utterance.voice = voice
            utterance.rate = rate
            // A beat between chunks, which are paragraph-sized.
            utterance.postUtteranceDelay = 0.25
            indices[ObjectIdentifier(utterance)] = position
            synthesizer.speak(utterance)
        }
    }

    func pause() { synthesizer.pauseSpeaking(at: .word) }

    func resume() { synthesizer.continueSpeaking() }

    func stop() {
        indices.removeAll()
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - Voice and rate

    /// The voice the user picked, when it is still installed; otherwise the
    /// best installed voice for the text's language, preferring the user's
    /// own region (a Brazilian reader gets a Brazilian voice for Portuguese)
    /// and then the highest quality tier.
    static func voice(identifier: String, languageCode: String?) -> AVSpeechSynthesisVoice? {
        if !identifier.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: identifier) {
            return chosen
        }
        guard let languageCode else { return nil }
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix(languageCode.lowercased())
        }
        let region = Locale.current.region?.identifier ?? ""
        let preferredTag = "\(languageCode)-\(region)".lowercased()
        return candidates.max { lhs, rhs in
            rank(lhs, preferredTag: preferredTag) < rank(rhs, preferredTag: preferredTag)
        } ?? AVSpeechSynthesisVoice(language: languageCode)
    }

    private static func rank(_ voice: AVSpeechSynthesisVoice, preferredTag: String) -> Int {
        let regionMatch = voice.language.lowercased() == preferredTag ? 10 : 0
        return regionMatch + voice.quality.rawValue
    }

    /// Map the app's playback multiplier onto `AVSpeechUtterance.rate`, whose
    /// scale is not linear: the default (0.5) is normal speech and the maximum
    /// (1.0) is far faster than 2×, so 2× lands halfway to the maximum.
    static func utteranceRate(for multiplier: Float) -> Float {
        let normal = AVSpeechUtteranceDefaultSpeechRate
        let fastest = AVSpeechUtteranceMaximumSpeechRate
        let slowest = AVSpeechUtteranceMinimumSpeechRate
        if multiplier >= 1 {
            return min(fastest, normal + (multiplier - 1) * (fastest - normal) * 0.5)
        }
        return max(slowest, normal - (1 - multiplier) * (normal - slowest))
    }

    /// ISO 639-1 code of the text's dominant language, or `nil` when the
    /// recognizer is not reasonably sure. Summaries are written in the
    /// meeting's language, which need not be the device's.
    static func dominantLanguage(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2_000)))
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first,
              best.value >= 0.5 else { return nil }
        // "zh-Hans"/"zh-Hant" → "zh": voices and vendors key on the base code.
        return best.key.rawValue.split(separator: "-").first.map(String.init)
    }
}

extension SystemSpeechEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let index = self.indices[id] else { return }
            self.onChunkStarted?(index)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let index = self.indices.removeValue(forKey: id) else { return }
            if index == self.lastIndex { self.onFinished?() }
        }
    }
}
