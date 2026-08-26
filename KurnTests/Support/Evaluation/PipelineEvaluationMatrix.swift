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
        cloudProviders: cloudProvidersFromEnvironment(),
        transcriptionEngines: transcriptionEnginesFromEnvironment()
    )

    /// On-device transcription engines to sweep. Defaults to every on-device
    /// engine (today's behavior). Set `KURN_PUBLIC_EVAL_ENGINES` to `none` to
    /// exclude all on-device engines (useful when only a cloud provider via
    /// `cloud_providers` is wanted) or to a comma-separated subset such as
    /// `fluidAudioParakeet` to scope a dispatch to one engine — a full sweep
    /// across every axis, doubled again by `correction`, is expensive (real
    /// GitHub Actions minutes and real LLM API calls), so a targeted run
    /// should not have to pay for engines nobody asked about.
    static func transcriptionEnginesFromEnvironment() -> [TranscriptionEngine] {
        let onDeviceEngines = TranscriptionEngine.allCases.filter { $0 != .whisperAPI }
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["KURN_PUBLIC_EVAL_ENGINES"], !raw.isEmpty else {
            return onDeviceEngines
        }
        let tokens = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if tokens == ["none"] { return [] }
        if tokens == ["all"] { return onDeviceEngines }
        return onDeviceEngines.filter { tokens.contains($0.rawValue.lowercased()) }
    }

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

    /// Cloud Whisper providers to add to the matrix. Decided by the
    /// `KURN_PUBLIC_EVAL_CLOUD_PROVIDERS` environment variable:
    /// - `none` -> no cloud providers
    /// - `openai`/`groq` -> only that provider (key must still be present)
    /// - `both` or `auto` (default) -> every provider whose API key secret is
    ///   present in the environment. This is never hardcoded as always-on.
    ///
    /// The CI workflow passes this as `TEST_RUNNER_KURN_PUBLIC_EVAL_CLOUD_PROVIDERS`.
    static func cloudProvidersFromEnvironment() -> [AIProvider] {
        let environment = ProcessInfo.processInfo.environment
        let mode = environment["KURN_PUBLIC_EVAL_CLOUD_PROVIDERS"]?.lowercased() ?? "auto"
        guard mode != "none" else { return [] }

        let includeOpenAI = mode == "openai" || mode == "both" || mode == "auto"
        let includeGroq = mode == "groq" || mode == "both" || mode == "auto"

        var providers: [AIProvider] = []
        if includeOpenAI, let key = environment["OPENAI_API_KEY"], !key.trimmingCharacters(in: .whitespaces).isEmpty {
            providers.append(.openAI)
        }
        if includeGroq, let key = environment["GROQ_API_KEY"], !key.trimmingCharacters(in: .whitespaces).isEmpty {
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
        cloudProviders: [AIProvider],
        transcriptionEngines: [TranscriptionEngine]
    ) -> [Entry] {
        var entries: [Entry] = []
        for preprocessing in PreprocessingEngine.allCases {
            for vad in VADEngine.allCases {
                for diarization in DiarizationEngine.allCases {
                    for transcription in transcriptionEngines {
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
            sherpaOnnxConsented: diarization == .sherpaOnnx,
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
        case .sherpaOnnxDiarization: return "sherpaOnnxDiarization"
        }
    }

    /// How `withCorrectionVariants` should fold correction into the matrix,
    /// decided by `KURN_PUBLIC_EVAL_CORRECTION`:
    /// - `off` (default/anything else) → no correction axis.
    /// - `on` → **pair**: every entry keeps its baseline row and gains a
    ///   corrected twin (doubles the matrix) — the apples-to-apples
    ///   baseline/corrected comparison when the baseline isn't already known.
    /// - `only` → every entry is **replaced** by its corrected version, no
    ///   baseline row. For a dispatch scoped to an engine/corpus whose
    ///   uncorrected baseline is already recorded (e.g. in
    ///   `docs/pipeline-evaluation.md`), re-measuring it would just spend the
    ///   same CI time and real LLM API cost a second time for no new
    ///   information.
    enum CorrectionMode: Sendable { case off, pair, only }

    static func correctionModeFromEnvironment() -> CorrectionMode {
        switch ProcessInfo.processInfo.environment["KURN_PUBLIC_EVAL_CORRECTION"]?.lowercased() {
        case "on": return .pair
        case "only": return .only
        default: return .off
        }
    }

    /// Correction provider to pair with `.llm` correction variants. Decided by
    /// `KURN_PUBLIC_EVAL_CORRECTION_PROVIDER` (default `openai`), and only
    /// returned when `correctionModeFromEnvironment()` isn't `.off` AND that
    /// provider's key secret is present in the environment — same rationale
    /// as `cloudProvidersFromEnvironment`: a correction pass sends transcript
    /// text to a third party and costs money per call, so it must never run
    /// just because the matrix exists.
    static func correctionProviderFromEnvironment() -> AIProvider? {
        guard correctionModeFromEnvironment() != .off else { return nil }
        let environment = ProcessInfo.processInfo.environment
        let providerID = environment["KURN_PUBLIC_EVAL_CORRECTION_PROVIDER"]?.lowercased() ?? "openai"
        switch providerID {
        case "openai":
            guard let key = environment["OPENAI_API_KEY"], !key.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return .openAI
        case "groq":
            guard let key = environment["GROQ_API_KEY"], !key.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return .groq
        default:
            return nil
        }
    }

    /// Applies `correctionModeFromEnvironment()` to `entries`: pairs each
    /// with a corrected twin (`.pair`), replaces each with its corrected
    /// version (`.only`), or leaves `entries` unchanged (`.off`, or no
    /// provider key present). Twin/replacement labels are suffixed
    /// `|corr=llm:<providerID>`, mirroring the `|asr=...` suffix convention.
    static func withCorrectionVariants(of entries: [Entry]) -> [Entry] {
        let mode = correctionModeFromEnvironment()
        guard mode != .off, let provider = correctionProviderFromEnvironment() else { return entries }

        func corrected(_ entry: Entry) -> Entry {
            var configuration = entry.configuration
            configuration.correction = .llm
            configuration.correctionConsented = true
            configuration.correctionProvider = provider
            configuration.correctionModel = provider.defaultModel
            return Entry(label: entry.label + "|corr=llm:\(provider.id)", configuration: configuration)
        }

        switch mode {
        case .off:
            return entries
        case .pair:
            var result: [Entry] = []
            result.reserveCapacity(entries.count * 2)
            for entry in entries {
                result.append(entry)
                result.append(corrected(entry))
            }
            return result
        case .only:
            return entries.map(corrected)
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
