//
//  PipelineEvaluationMatrix.swift
//  KurnTests
//
//  The cross product of pipeline stage choices the public-dataset harness
//  scores, so "does cleanup help" and "which diarizer is better" have a number
//  instead of a guess. Four axes, matching what a user can actually toggle:
//  ASR preprocessing (audio cleanup), VAD, diarization, and transcription
//  engine.
//
//  `languageDetection` and `diarizationPreprocessingEnabled` are held fixed
//  (`.byTranscriber`, `true`) rather than swept: the dataset already carries
//  its language, so re-detecting it only adds noise to the measurement, and
//  diarization preprocessing is a smaller, separate knob from the four the
//  original request asked about.
//
//  `.whisperAPI` (cloud Whisper — OpenAI, Groq) is opt-in and additive, not
//  part of the base 24. Every other engine here is on-device and free to run
//  unattended; a cloud engine sends the recording to a third party and costs
//  money per call, so it must never be exercised just because the matrix
//  exists. It is included only for providers whose API key secret
//  (`OPENAI_API_KEY` / `GROQ_API_KEY`) is actually set in the environment —
//  see `.github/workflows/pipeline-eval.yml`, which wires those from repo
//  secrets a maintainer opts into, and
//  `PublicDatasetEvaluationHarnessTests.seedCloudProviderKeysFromEnvironment`,
//  which is what makes the key reach `ProviderFactory` the same way a real
//  user's Settings-entered key would.
//

import Foundation
@testable import Kurn

enum PipelineEvaluationMatrix {

    /// One entry in the matrix: a configuration plus a short, stable label used
    /// in report output and CSV rows. The label is derived from the enum raw
    /// values so it never drifts from the configuration it names.
    struct Entry: Sendable {
        var label: String
        var configuration: PipelineConfiguration
    }

    /// The on-device combinations, expanded for every whisper.cpp model in
    /// `whisperCppModelsFromEnvironment()` when the transcription engine is
    /// `.whisperCpp`, plus for each cloud provider found in
    /// `cloudProvidersFromEnvironment()` 8 more (preprocessing x VAD x
    /// diarization) using `.whisperAPI` against that provider. Fixed order so
    /// successive runs are diffable.
    static let all: [Entry] = build(
        whisperCppModels: whisperCppModelsFromEnvironment(),
        cloudProviders: cloudProvidersFromEnvironment()
    )

    /// Whisper.cpp models to sweep when the transcription engine is
    /// `.whisperCpp`. Defaults to `[.small]`; set
    /// `KURN_PUBLIC_EVAL_WHISPERCPP_MODELS` to `all` or a comma-separated list
    /// such as `base,small` to run more than one (the CI workflow passes this
    /// as `TEST_RUNNER_KURN_PUBLIC_EVAL_WHISPERCPP_MODELS`).
    static func whisperCppModelsFromEnvironment() -> [WhisperCppModel] {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["KURN_PUBLIC_EVAL_WHISPERCPP_MODELS"], !raw.isEmpty else {
            return [.default]
        }
        let tokens = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if tokens == ["all"] {
            return WhisperCppModel.allCases
        }
        return WhisperCppModel.allCases.filter { tokens.contains($0.rawValue.lowercased()) }
    }

    /// Cloud Whisper providers to add to the matrix, decided by which API key
    /// secret is present — never by hardcoding a provider as always-on. Can be
    /// forced off by setting `KURN_PUBLIC_EVAL_INCLUDE_CLOUD=false` (the CI
    /// workflow passes this as `TEST_RUNNER_KURN_PUBLIC_EVAL_INCLUDE_CLOUD`).
    static func cloudProvidersFromEnvironment() -> [AIProvider] {
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["KURN_PUBLIC_EVAL_INCLUDE_CLOUD"],
           raw.lowercased() == "false" {
            return []
        }
        var providers: [AIProvider] = []
        if let key = environment["OPENAI_API_KEY"], !key.trimmingCharacters(in: .whitespaces).isEmpty {
            providers.append(.openAI)
        }
        if let key = environment["GROQ_API_KEY"], !key.trimmingCharacters(in: .whitespaces).isEmpty {
            providers.append(.groq)
        }
        return providers
    }

    /// How a pipeline entry resolves its ASR: on-device engine with an optional
    /// whisper.cpp model variant, or a cloud Whisper provider.
    private enum ASRChoice {
        case onDevice(WhisperCppModel?)
        case cloud(AIProvider)
    }

    private static func build(
        whisperCppModels: [WhisperCppModel],
        cloudProviders: [AIProvider]
    ) -> [Entry] {
        var entries: [Entry] = []
        for preprocessing in PreprocessingEngine.allCases {
            for vad in VADEngine.allCases {
                for diarization in DiarizationEngine.allCases {
                    for transcription in TranscriptionEngine.allCases where transcription != .whisperAPI {
                        if transcription == .whisperCpp {
                            for model in whisperCppModels {
                                entries.append(entry(
                                    preprocessing: preprocessing,
                                    vad: vad,
                                    diarization: diarization,
                                    transcription: transcription,
                                    asr: .onDevice(model)
                                ))
                            }
                        } else {
                            entries.append(entry(
                                preprocessing: preprocessing,
                                vad: vad,
                                diarization: diarization,
                                transcription: transcription,
                                asr: .onDevice(nil)
                            ))
                        }
                    }
                    for provider in cloudProviders {
                        entries.append(entry(
                            preprocessing: preprocessing,
                            vad: vad,
                            diarization: diarization,
                            transcription: .whisperAPI,
                            asr: .cloud(provider)
                        ))
                    }
                }
            }
        }
        return entries
    }

    private static func entry(
        preprocessing: PreprocessingEngine,
        vad: VADEngine,
        diarization: DiarizationEngine,
        transcription: TranscriptionEngine,
        asr: ASRChoice
    ) -> Entry {
        var configuration = PipelineConfiguration(
            preprocessing: preprocessing,
            vad: vad,
            languageDetection: .byTranscriber,
            diarization: diarization,
            diarizationConsented: diarization == .fluidAudio,
            transcription: transcription,
            diarizationPreprocessingEnabled: true
        )

        let asrLabel: String
        switch asr {
        case .onDevice(let model):
            if let model { configuration.whisperCppModel = model }
            let modelSuffix = model.map { "@\($0.rawValue)" } ?? ""
            asrLabel = "\(transcription.rawValue)\(modelSuffix)"
        case .cloud(let provider):
            configuration.transcriptionProvider = provider
            configuration.transcriptionModel = provider.defaultTranscriptionModel
            asrLabel = "\(transcription.rawValue):\(provider.id)"
        }

        // "|"-separated, not ","-separated: the label is embedded as a single
        // CSV field by the harness report, and a comma inside it would
        // silently shift every column after it.
        let label = [
            "prep=\(preprocessing.rawValue)",
            "vad=\(vad.rawValue)",
            "diar=\(diarization.rawValue)",
            "asr=\(asrLabel)"
        ].joined(separator: "|")
        return Entry(label: label, configuration: configuration)
    }

    /// Every `ModelSet` any entry in `all` needs, de-duplicated by the identity
    /// `ModelDownloadConsent` cares about. Used to prewarm every model the run
    /// will touch once, up front, rather than mid-run on whichever config hits
    /// it first. Cloud entries never appear here — `.whisperAPI` has no local
    /// model, so `requiredModelSet` is `nil` for them regardless of provider.
    static var requiredModelSets: [ModelSet] {
        var seen = Set<String>()
        var sets: [ModelSet] = []
        func add(_ set: ModelSet?) {
            guard let set else { return }
            let key = modelSetKey(set)
            guard seen.insert(key).inserted else { return }
            sets.append(set)
        }
        for entry in all {
            let config = entry.configuration
            add(config.vad.requiredModelSet)
            add(config.effectiveDiarization.requiredModelSet)
            add(config.transcription.requiredModelSet(whisperCppModel: config.whisperCppModel))
        }
        return sets
    }

    private static func modelSetKey(_ set: ModelSet) -> String {
        switch set {
        case .liveTranscriptionASR: return "liveTranscriptionASR"
        case .onDeviceASR: return "onDeviceASR"
        case .diarization: return "diarization"
        case .vad: return "vad"
        case .whisperCppASR(let model): return "whisperCppASR:\(model.rawValue)"
        }
    }

    /// A restricted subset for a quick smoke pass: cleanup on/off, VAD engine
    /// (energy-threshold vs FluidAudio Silero), and diarization on/off, holding
    /// transcription at `.whisperCpp` (never includes a cloud provider). `whisperCpp`
    /// is used instead of `appleSpeech` so the smoke pass is multilingual —
    /// Portuguese corpora do not have a supported Apple Speech locale on the
    /// simulator, and the goal is to exercise the preprocessing/VAD/diarization
    /// axes, not the ASR vendor.
    static let essential: [Entry] = all.filter {
        ($0.configuration.vad == .energyThreshold || $0.configuration.vad == .fluidAudio)
            && $0.configuration.transcription == .whisperCpp
    }
}
