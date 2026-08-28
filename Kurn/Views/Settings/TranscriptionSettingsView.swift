//
//  TranscriptionSettingsView.swift
//  Kurn
//
//  The recognition pipeline: which engine turns audio into text, and the stages
//  around it (cleanup, voice-activity detection, language detection, speaker
//  diarization). Split into "engine and language" and "advanced pipeline" so the
//  choice most people make isn't buried under six stage pickers.
//

import KurnCore
import SwiftUI

struct TranscriptionSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelDownloadController.self) private var downloads

    /// Bumped by the root when an API key changes, so the Whisper provider rows
    /// re-read Keychain state.
    let keyRevision: Int

    private var transcriptionProviders: [AIProvider] {
        _ = keyRevision
        return settings.configuredTranscriptionProviders
    }

    private var hasAnyTranscriptionProvider: Bool { !transcriptionProviders.isEmpty }

    /// Recomputed whenever `keyRevision` bumps (the root counter shared with
    /// `WikiSettingsView`, incremented on any provider key add/remove) — the
    /// correction stage reuses the summary provider, so its toggle must react
    /// to the same key changes.
    private var hasSummaryProviderKey: Bool {
        _ = keyRevision
        return settings.aiProvider.isUsable
    }

    /// The reason the correction toggle is disabled, when it is. Names the
    /// specific on-device unavailability reason rather than always suggesting
    /// an API key, which would be the wrong instruction for that provider.
    private var correctionUnavailableFooter: String {
        if settings.aiProvider.kind == .appleOnDevice, let reason = OnDeviceModelAvailability.unavailableReason {
            return reason
        }
        return NSLocalizedString("settings.correction_needs_key", comment: "AI transcription correction needs an API key")
    }

    var body: some View {
        Form {
            engineSection
            pipelineSection
            correctionSection
        }
        .navigationTitle(NSLocalizedString("settings.transcription", comment: "Transcription"))
        .modelDownloadAlerts(downloads, settings: settings)
    }

    // MARK: - Engine and language

    @ViewBuilder
    private var engineSection: some View {
        Section {
            Picker(
                NSLocalizedString("pipeline.transcription_engine", comment: "Transcription engine"),
                selection: Binding(
                    get: { settings.transcriptionEngine },
                    set: {
                        downloads.selectTranscriptionEngine(
                            $0, settings: settings, transcriptionProviders: transcriptionProviders
                        )
                    }
                )
            ) {
                ForEach(TranscriptionEngine.allCases) { engine in
                    Text(engine.displayName)
                        .tag(engine)
                        .disabled(engine == .whisperAPI && !hasAnyTranscriptionProvider)
                }
            }
            .disabled(downloads.isDownloading)

            // Cloud transcription provider + model, chosen independently of the
            // summary provider. Only shown for the Whisper engine.
            if settings.transcriptionEngine == .whisperAPI {
                Picker(
                    NSLocalizedString("settings.transcription_provider", comment: "Transcription provider"),
                    selection: Binding(
                        get: { settings.transcriptionProviderID },
                        set: { settings.transcriptionProviderID = $0 }
                    )
                ) {
                    ForEach(transcriptionProviders) { provider in
                        Text(provider.displayName).tag(provider.id)
                    }
                }
                TranscriptionModelPicker(
                    settings: settings,
                    provider: settings.transcriptionProvider,
                    revision: keyRevision
                )
            }

            // Which GGML weight file the on-device Whisper engine loads. Each
            // variant is a separate download, so switching can trigger one.
            if settings.transcriptionEngine == .whisperCpp {
                Picker(
                    NSLocalizedString("settings.whisper_cpp.model", comment: "Whisper model size"),
                    selection: Binding(
                        get: { settings.whisperCppModel },
                        set: { downloads.selectWhisperCppModel($0, settings: settings) }
                    )
                ) {
                    ForEach(WhisperCppModel.allCases) { model in
                        Text(verbatim: "\(model.displayName) · \(Self.sizeLabel(model))").tag(model)
                    }
                }
                .disabled(downloads.isDownloading)
                Text(NSLocalizedString("settings.whisper_cpp.model_footer", comment: "Whisper model size help"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Picker(
                NSLocalizedString("settings.default_language", comment: "Default language"),
                selection: Binding(
                    get: { settings.defaultLanguage },
                    set: { settings.defaultLanguage = $0 }
                )
            ) {
                ForEach(MeetingLanguage.allCases) { lang in
                    LanguagePickerRow(language: lang, engine: settings.transcriptionEngine).tag(lang)
                }
            }

            if downloads.downloadingModel == .onDeviceASR || Self.isDownloadingWhisperCpp(downloads) {
                ModelDownloadProgressRow(progress: downloads.downloadProgress)
            }
        } header: {
            Text(NSLocalizedString("settings.recognition_pipeline", comment: "Recognition pipeline"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString(
                    hasAnyTranscriptionProvider
                        ? "settings.whisper_provider_key_footer"
                        : "settings.whisper_provider_key_missing_footer",
                    comment: "Whisper transcription provider key dependency"
                ))
                Text(NSLocalizedString("settings.language_support_footer", comment: "Explains the unsupported-language warning icon"))
            }
        }
    }

    /// Approximate download size, so the cost of a variant is visible before
    /// picking it.
    private static func sizeLabel(_ model: WhisperCppModel) -> String {
        ByteCountFormatter.string(fromByteCount: model.approximateBytes, countStyle: .file)
    }

    private static func isDownloadingWhisperCpp(_ downloads: ModelDownloadController) -> Bool {
        if case .whisperCppASR = downloads.downloadingModel { return true }
        return false
    }

    // MARK: - Advanced stages

    @ViewBuilder
    private var pipelineSection: some View {
        Section {
            // Audio cleanup/normalization.
            Toggle(
                NSLocalizedString("pipeline.preprocessing", comment: "Audio cleanup"),
                isOn: Binding(
                    get: { settings.preprocessingEngine == .standardDSP },
                    set: { enabled in
                        settings.preprocessingEngine = enabled ? .standardDSP : .none
                    }
                )
            )

            // Voice-activity detection.
            Picker(
                NSLocalizedString("pipeline.vad", comment: "Voice activity detection"),
                selection: Binding(
                    get: { settings.vadEngine },
                    set: { downloads.selectVADEngine($0, settings: settings) }
                )
            ) {
                ForEach(VADEngine.allCases) { Text($0.displayName).tag($0) }
            }
            .disabled(downloads.isDownloading)

            // Language detection.
            Picker(
                NSLocalizedString("pipeline.language_detection", comment: "Language detection"),
                selection: Binding(
                    get: { settings.languageDetectionEngine },
                    set: { downloads.selectLanguageDetectionEngine($0, settings: settings) }
                )
            ) {
                ForEach(LanguageDetectionEngine.allCases) { Text($0.displayName).tag($0) }
            }
            .disabled(downloads.isDownloading)

            // Speaker diarization.
            Picker(
                NSLocalizedString("settings.diarization_engine", comment: "Diarization engine"),
                selection: Binding(
                    get: { settings.diarizationEngine },
                    set: { downloads.selectDiarizationEngine($0, settings: settings) }
                )
            ) {
                ForEach(DiarizationEngine.allCases) { Text($0.displayName).tag($0) }
            }
            .disabled(downloads.isDownloading)

            // Dedicated diarization cleanup. This controls only the diarization
            // input; the ASR cleanup toggle above controls only the
            // transcription path.
            Toggle(
                NSLocalizedString("settings.diarization_preprocessing", comment: "Diarization audio cleanup"),
                isOn: Binding(
                    get: { settings.diarizationPreprocessingEnabled },
                    set: { settings.diarizationPreprocessingEnabled = $0 }
                )
            )
            .disabled(downloads.isDownloading)

            // Pinned speaker count for the neural (FluidAudio) engine. On
            // far-field/single-mic audio its clustering step collapses everyone
            // into one speaker; pinning the count re-clusters the raw speaker
            // embeddings into exactly that many. Left at Auto, the engine
            // decides and the app re-clusters on its own if it collapsed.
            // Hidden for the heuristic engine, which auto-detects.
            if settings.diarizationEngine == .fluidAudio {
                Stepper(
                    value: Binding(
                        get: { settings.fluidAudioSpeakerCount },
                        set: { settings.fluidAudioSpeakerCount = $0 }
                    ),
                    in: 0...10
                ) {
                    HStack {
                        Text(NSLocalizedString("settings.diarization_speaker_count", comment: "Number of speakers"))
                        Spacer()
                        Text(
                            settings.fluidAudioSpeakerCount == 0
                                ? NSLocalizedString("settings.diarization_speaker_count_auto", comment: "Auto")
                                : "\(settings.fluidAudioSpeakerCount)"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .disabled(downloads.isDownloading)
                Text(NSLocalizedString("settings.diarization_speaker_count_footer", comment: "Speaker count help"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if downloads.downloadingModel == .diarization
                || downloads.downloadingModel == .sherpaOnnxDiarization
                || downloads.downloadingModel == .vad {
                ModelDownloadProgressRow(progress: downloads.downloadProgress)
            }
        } header: {
            Text(NSLocalizedString("settings.pipeline_advanced", comment: "Advanced pipeline"))
        }
    }

    // MARK: - AI correction

    @ViewBuilder
    private var correctionSection: some View {
        Section {
            Toggle(
                NSLocalizedString("settings.correction", comment: "AI transcription correction toggle"),
                isOn: Binding(
                    get: { settings.correctionEnabled && hasSummaryProviderKey },
                    set: { settings.correctionEnabled = $0 }
                )
            )
            .disabled(!hasSummaryProviderKey)
        } header: {
            Text(NSLocalizedString("settings.correction_title", comment: "AI transcription correction section title"))
        } footer: {
            Text(hasSummaryProviderKey
                ? NSLocalizedString("settings.correction_footer", comment: "AI transcription correction footer")
                : correctionUnavailableFooter)
        }
    }
}
