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
//  `.whisperAPI` (cloud transcription — OpenAI, Groq, ElevenLabs) is opt-in and additive, not
//  part of the base 36. Every other engine here is on-device and free to run
//  unattended; a cloud engine sends the recording to a third party and costs
//  money per call, so it must never be exercised just because the matrix
//  exists. It is included only for providers whose API key secret
//  (`OPENAI_API_KEY` / `GROQ_API_KEY` / `ELEVENLABS_API_KEY`) is actually set in the environment —
//  see `.github/workflows/pipeline-eval.yml`, which wires those from repo
//  secrets a maintainer opts into, and
//  `PublicDatasetEvaluationHarnessTests.seedCloudProviderKeysFromEnvironment`,
//  which is what makes the key reach `ProviderFactory` the same way a real
//  user's Settings-entered key would.
//

import Foundation
import KurnCore
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
    /// `cloudProvidersFromEnvironment()` one more per preprocessing x VAD x
    /// diarization x model (`cloudModelsFromEnvironment()`) using `.whisperAPI`
    /// against that provider. Fixed order so
    /// successive runs are diffable.
    static let all: [Entry] = build(
        whisperCppModels: whisperCppModelsFromEnvironment(),
        cloudProviders: cloudProvidersFromEnvironment(),
        transcriptionEngines: transcriptionEnginesFromEnvironment(),
        diarizationEngines: diarizationEnginesFromEnvironment(),
        cloudModels: cloudModelsFromEnvironment(),
        fluidAudioASRModels: fluidAudioASRModelsFromEnvironment(),
        fluidAudioDiarizationModels: fluidAudioDiarizationModelsFromEnvironment()
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
        // The cloud engine (`.whisperAPI`, which now covers any configured
        // provider with `supportsTranscription` — OpenAI, Groq, ElevenLabs,
        // …) is opt-in and additive, not part of the on-device base — see the
        // file header.
        let onDeviceEngines = TranscriptionEngine.allCases.filter { !$0.isCloudTranscription }
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["KURN_PUBLIC_EVAL_ENGINES"], !raw.isEmpty else {
            return onDeviceEngines
        }
        let tokens = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if tokens == ["none"] { return [] }
        if tokens == ["all"] { return onDeviceEngines }
        return onDeviceEngines.filter { tokens.contains($0.rawValue.lowercased()) }
    }

    static func diarizationEnginesFromEnvironment() -> [DiarizationEngine] {
        diarizationEngines(from: ProcessInfo.processInfo.environment["KURN_PUBLIC_EVAL_DIARIZATION_ENGINES"])
    }

    static func diarizationEngines(from raw: String?) -> [DiarizationEngine] {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return DiarizationEngine.allCases
        }
        let tokens = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if tokens == ["all"] { return DiarizationEngine.allCases }
        return DiarizationEngine.allCases.filter { tokens.contains($0.rawValue.lowercased()) }
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

    /// FluidAudio ASR models to sweep when the transcription engine is
    /// `.fluidAudioParakeet` (the stored engine ID for every FluidAudio ASR
    /// choice). Defaults to `[.parakeetV3]`, which is what every run recorded
    /// before the model axis existed measured; set
    /// `KURN_PUBLIC_EVAL_FLUIDAUDIO_ASR_MODELS` to `all` or a comma-separated
    /// list such as `nemotronUnified,bark3`. English-only models skip the
    /// Portuguese corpora instead of failing them.
    static func fluidAudioASRModelsFromEnvironment() -> [FluidAudioASRModel] {
        fluidAudioASRModels(from: ProcessInfo.processInfo.environment["KURN_PUBLIC_EVAL_FLUIDAUDIO_ASR_MODELS"])
    }

    static func fluidAudioASRModels(from raw: String?) -> [FluidAudioASRModel] {
        selection(from: raw, all: FluidAudioASRModel.allCases, default: [.default])
    }

    /// FluidAudio diarization models to sweep when the diarizer is
    /// `.fluidAudio`. Defaults to `[.pyannote]`; set
    /// `KURN_PUBLIC_EVAL_FLUIDAUDIO_DIARIZATION_MODELS` to `all` or
    /// `nemotron3`.
    static func fluidAudioDiarizationModelsFromEnvironment() -> [FluidAudioDiarizationModel] {
        fluidAudioDiarizationModels(
            from: ProcessInfo.processInfo.environment["KURN_PUBLIC_EVAL_FLUIDAUDIO_DIARIZATION_MODELS"]
        )
    }

    static func fluidAudioDiarizationModels(from raw: String?) -> [FluidAudioDiarizationModel] {
        selection(from: raw, all: FluidAudioDiarizationModel.allCases, default: [.default])
    }

    /// Blank → `default`, `all` → every case, otherwise the cases whose raw
    /// value appears in the comma-separated list, in declaration order.
    private static func selection<Model: RawRepresentable>(
        from raw: String?,
        all: [Model],
        default defaultModels: [Model]
    ) -> [Model] where Model.RawValue == String {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return defaultModels }
        let tokens = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if tokens == ["all"] { return all }
        return all.filter { tokens.contains($0.rawValue.lowercased()) }
    }

    /// Cloud transcription providers to add to the matrix. Decided by the
    /// `KURN_PUBLIC_EVAL_CLOUD_PROVIDERS` environment variable:
    /// - `none` -> no cloud providers
    /// - `openai`/`groq`/`elevenlabs`, or a comma-separated list of them ->
    ///   only those (each key must still be present)
    /// - `both` -> OpenAI and Groq, kept for dispatches recorded before
    ///   ElevenLabs existed
    /// - `auto` (default) -> every provider whose API key secret is present in
    ///   the environment. This is never hardcoded as always-on.
    ///
    /// The CI workflow passes this as `TEST_RUNNER_KURN_PUBLIC_EVAL_CLOUD_PROVIDERS`.
    static func cloudProvidersFromEnvironment() -> [AIProvider] {
        let environment = ProcessInfo.processInfo.environment
        return cloudProviders(
            from: environment["KURN_PUBLIC_EVAL_CLOUD_PROVIDERS"],
            environment: environment
        )
    }

    /// Each cloud provider the harness knows how to seed, with the secret that
    /// carries its key. Order is the matrix order.
    static let cloudProviderKeyVariables: [(provider: AIProvider, variable: String)] = [
        (.openAI, "OPENAI_API_KEY"),
        (.groq, "GROQ_API_KEY"),
        (.elevenLabs, "ELEVENLABS_API_KEY")
    ]

    static func cloudProviders(from raw: String?, environment: [String: String]) -> [AIProvider] {
        let mode = raw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard mode != "none" else { return [] }

        let requested: Set<String>
        switch mode {
        case "", "auto":
            requested = Set(cloudProviderKeyVariables.map { $0.provider.id.lowercased() })
        case "both":
            requested = [AIProvider.openAI.id.lowercased(), AIProvider.groq.id.lowercased()]
        default:
            requested = Set(mode.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }

        return cloudProviderKeyVariables.compactMap { candidate in
            guard requested.contains(candidate.provider.id.lowercased()),
                  let key = environment[candidate.variable],
                  !key.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return candidate.provider
        }
    }

    /// Transcription models to sweep per cloud provider, from
    /// `KURN_PUBLIC_EVAL_CLOUD_MODELS` — comma-separated `provider:model`
    /// pairs such as `openai:gpt-4o-transcribe,openai:whisper-1`. A provider
    /// with no pair runs its `defaultTranscriptionModel` only, which is what
    /// every run recorded before this variable existed measured.
    static func cloudModelsFromEnvironment() -> [String: [String]] {
        cloudModels(from: ProcessInfo.processInfo.environment["KURN_PUBLIC_EVAL_CLOUD_MODELS"])
    }

    static func cloudModels(from raw: String?) -> [String: [String]] {
        var models: [String: [String]] = [:]
        for pair in (raw ?? "").split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            let provider = parts[0].lowercased()
            if !(models[provider]?.contains(parts[1]) ?? false) {
                models[provider, default: []].append(parts[1])
            }
        }
        return models
    }

    /// How a pipeline entry resolves its ASR: on-device engine with an optional
    /// whisper.cpp model variant, or a cloud Whisper provider.
    private enum ASRChoice {
        case onDevice(WhisperCppModel?)
        case fluidAudio(FluidAudioASRModel)
        case cloud(AIProvider, model: String)
    }

    /// The ASR choices one on-device engine expands into.
    private static func asrChoices(
        for transcription: TranscriptionEngine,
        whisperCppModels: [WhisperCppModel],
        fluidAudioASRModels: [FluidAudioASRModel]
    ) -> [ASRChoice] {
        switch transcription {
        case .whisperCpp: return whisperCppModels.map { .onDevice($0) }
        case .fluidAudioParakeet: return fluidAudioASRModels.map { .fluidAudio($0) }
        default: return [.onDevice(nil)]
        }
    }

    static func build(
        whisperCppModels: [WhisperCppModel],
        cloudProviders: [AIProvider],
        transcriptionEngines: [TranscriptionEngine],
        diarizationEngines: [DiarizationEngine],
        cloudModels: [String: [String]] = [:],
        fluidAudioASRModels: [FluidAudioASRModel] = [.default],
        fluidAudioDiarizationModels: [FluidAudioDiarizationModel] = [.default]
    ) -> [Entry] {
        var entries: [Entry] = []
        for preprocessing in PreprocessingEngine.allCases {
            for vad in VADEngine.allCases {
                for diarization in diarizationEngines {
                    // Only `.fluidAudio` has a model axis; every other diarizer
                    // runs once, labelled exactly as before the axis existed.
                    let diarizationModels: [FluidAudioDiarizationModel?] = diarization == .fluidAudio
                        ? fluidAudioDiarizationModels.map { $0 }
                        : [nil]
                    for diarizationModel in diarizationModels {
                        let cell = Cell(
                            preprocessing: preprocessing,
                            vad: vad,
                            diarization: diarization,
                            diarizationModel: diarizationModel
                        )
                        entries += onDeviceEntries(
                            for: cell,
                            transcriptionEngines: transcriptionEngines,
                            whisperCppModels: whisperCppModels,
                            fluidAudioASRModels: fluidAudioASRModels
                        )
                        entries += cloudEntries(for: cell, cloudProviders: cloudProviders, cloudModels: cloudModels)
                    }
                }
            }
        }
        return entries
    }

    /// One preprocessing x VAD x diarization (x diarization model) cell, which
    /// the ASR axis then expands.
    private struct Cell {
        var preprocessing: PreprocessingEngine
        var vad: VADEngine
        var diarization: DiarizationEngine
        var diarizationModel: FluidAudioDiarizationModel?
    }

    private static func onDeviceEntries(
        for cell: Cell,
        transcriptionEngines: [TranscriptionEngine],
        whisperCppModels: [WhisperCppModel],
        fluidAudioASRModels: [FluidAudioASRModel]
    ) -> [Entry] {
        // `.transcriptionProviderNative` is honored only for a cloud
        // provider that returns its own speaker labels; everywhere
        // else `effectiveDiarization` quietly runs `.heuristic`. Those
        // cells would re-measure the heuristic diarizer under another
        // name — same number, double the cost, misleading label.
        guard cell.diarization != .transcriptionProviderNative else { return [] }
        return transcriptionEngines.flatMap { transcription in
            asrChoices(
                for: transcription,
                whisperCppModels: whisperCppModels,
                fluidAudioASRModels: fluidAudioASRModels
            ).map { entry(cell: cell, transcription: transcription, asr: $0) }
        }
    }

    private static func cloudEntries(
        for cell: Cell,
        cloudProviders: [AIProvider],
        cloudModels: [String: [String]]
    ) -> [Entry] {
        cloudProviders.flatMap { provider -> [Entry] in
            if cell.diarization == .transcriptionProviderNative, !provider.supportsNativeDiarization {
                return []
            }
            let models = cloudModels[provider.id.lowercased()] ?? [provider.defaultTranscriptionModel]
            return models.map { model in
                entry(cell: cell, transcription: .whisperAPI, asr: .cloud(provider, model: model))
            }
        }
    }

    private static func entry(cell: Cell, transcription: TranscriptionEngine, asr: ASRChoice) -> Entry {
        let preprocessing = cell.preprocessing
        let vad = cell.vad
        let diarization = cell.diarization
        let diarizationModel = cell.diarizationModel
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
        if let diarizationModel { configuration.fluidAudioDiarizationModel = diarizationModel }

        let asrLabel: String
        switch asr {
        case .onDevice(let model):
            if let model { configuration.whisperCppModel = model }
            let modelSuffix = model.map { "@\($0.rawValue)" } ?? ""
            asrLabel = "\(transcription.rawValue)\(modelSuffix)"
        case .fluidAudio(let model):
            configuration.fluidAudioASRModel = model
            // The harness downloads every model up front, which is the
            // consent this flag stands for in the app.
            configuration.fluidAudioASRConsented = true
            // Parakeet v3 stays unsuffixed so labels recorded before the
            // model axis existed still match.
            let modelSuffix = model == .default ? "" : "@\(model.rawValue)"
            asrLabel = "\(transcription.rawValue)\(modelSuffix)"
        case .cloud(let provider, let model):
            configuration.transcriptionProvider = provider
            configuration.transcriptionModel = model
            configuration.cloudTranscriptionConsented = true
            configuration.largeTransferPolicy = LargeTransferPolicy(
                allowsExpensiveAccess: true,
                allowsConstrainedAccess: true
            )
            // The model is named only when it is not the provider's default,
            // so labels recorded before models could be swept still match.
            let modelSuffix = model == provider.defaultTranscriptionModel ? "" : "@\(model)"
            asrLabel = "\(transcription.rawValue):\(provider.id)\(modelSuffix)"
        }

        // "|"-separated, not ","-separated: the label is embedded as a single
        // CSV field by the harness report, and a comma inside it would
        // silently shift every column after it.
        let diarizationSuffix = diarizationModel.map { $0 == .default ? "" : "@\($0.rawValue)" } ?? ""
        let label = [
            "prep=\(preprocessing.rawValue)",
            "vad=\(vad.rawValue)",
            "diar=\(diarization.rawValue)\(diarizationSuffix)",
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
            FluidAudioPipelineSelection.requiredModelSets(for: entry.configuration).forEach(add)
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
        case .fluidAudioASR(let model): return "fluidAudioASR:\(model.rawValue)"
        case .fluidAudioDiarization(let model): return "fluidAudioDiarization:\(model.rawValue)"
        case .fluidAudioUnifiedStreaming: return "fluidAudioUnifiedStreaming"
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
    static let essential: [Entry] = essentialEntries(from: all)

    static func essentialEntries(from entries: [Entry]) -> [Entry] {
        entries.filter {
            ($0.configuration.vad == .energyThreshold || $0.configuration.vad == .fluidAudio)
                && $0.configuration.transcription == .whisperCpp
        }
    }
}
