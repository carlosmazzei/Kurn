//
//  SettingsSections.swift
//  Kurn
//
//  Section builders and actions split out of `SettingsView` into an extension to
//  keep that file under SwiftLint's length limit: the recognition-pipeline and
//  recording/diagnostics sections, the engine-selection consent gating, the
//  downloaded-models section, and the storage/reset actions. Members are
//  `internal` (not `private`) so the `body` in `SettingsView.swift` can call them
//  across files.
//

import SwiftData
import SwiftUI

extension SettingsView {

    @ViewBuilder
    func transcriptionSection(settings: AppSettings) -> some View {
        Section {
            // Transcription engine (the stage that turns audio into text).
            Picker(
                NSLocalizedString("pipeline.transcription_engine", comment: "Transcription engine"),
                selection: Binding(
                    get: { settings.transcriptionEngine },
                    set: { selectTranscriptionEngine($0, settings: settings) }
                )
            ) {
                ForEach(TranscriptionEngine.allCases) { engine in
                    Text(engine.displayName)
                        .tag(engine)
                        .disabled(engine == .whisperAPI && !hasAnyTranscriptionProvider)
                }
            }
            .disabled(downloadingModel != nil)

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

            Picker(
                NSLocalizedString("settings.default_language", comment: "Default language"),
                selection: Binding(
                    get: { settings.defaultLanguage },
                    set: { settings.defaultLanguage = $0 }
                )
            ) {
                ForEach(MeetingLanguage.allCases) { Text($0.displayName).tag($0) }
            }

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
                    set: { selectVADEngine($0, settings: settings) }
                )
            ) {
                ForEach(VADEngine.allCases) { Text($0.displayName).tag($0) }
            }
            .disabled(downloadingModel != nil)

            // Language detection.
            Picker(
                NSLocalizedString("pipeline.language_detection", comment: "Language detection"),
                selection: Binding(
                    get: { settings.languageDetectionEngine },
                    set: { selectLanguageDetectionEngine($0, settings: settings) }
                )
            ) {
                ForEach(LanguageDetectionEngine.allCases) { Text($0.displayName).tag($0) }
            }
            .disabled(downloadingModel != nil)

            // Speaker diarization.
            Picker(
                NSLocalizedString("settings.diarization_engine", comment: "Diarization engine"),
                selection: Binding(
                    get: { settings.diarizationEngine },
                    set: { engine in
                        if engine == .fluidAudio && !settings.fluidAudioDiarizationModelsConsented {
                            pendingDiarizationEngine = engine
                            showingDiarizationConsent = true
                        } else {
                            settings.diarizationEngine = engine
                        }
                    }
                )
            ) {
                ForEach(DiarizationEngine.allCases) { Text($0.displayName).tag($0) }
            }
            .disabled(downloadingModel != nil)

            // Dedicated diarization cleanup. This controls only the
            // diarization input; the ASR cleanup toggle above controls only the
            // transcription path.
            Toggle(
                NSLocalizedString("settings.diarization_preprocessing", comment: "Diarization audio cleanup"),
                isOn: Binding(
                    get: { settings.diarizationPreprocessingEnabled },
                    set: { settings.diarizationPreprocessingEnabled = $0 }
                )
            )
            .disabled(downloadingModel != nil)

            // Minimum-speakers floor for the neural (FluidAudio) engine. On
            // far-field/single-mic audio its VBx step collapses everything into
            // one speaker; a non-zero floor forces a KMeans re-cluster to at
            // least this many. Hidden for the heuristic engine, which auto-detects.
            if settings.diarizationEngine == .fluidAudio {
                Stepper(
                    value: Binding(
                        get: { settings.fluidAudioMinSpeakers },
                        set: { settings.fluidAudioMinSpeakers = $0 }
                    ),
                    in: 0...10
                ) {
                    HStack {
                        Text(NSLocalizedString("settings.diarization_min_speakers", comment: "Minimum speakers"))
                        Spacer()
                        Text(
                            settings.fluidAudioMinSpeakers == 0
                                ? NSLocalizedString("settings.diarization_min_speakers_auto", comment: "Auto")
                                : "\(settings.fluidAudioMinSpeakers)"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .disabled(downloadingModel != nil)
            }

            if downloadingModel == .onDeviceASR || downloadingModel == .diarization || downloadingModel == .vad {
                modelDownloadProgressRow
            }
        } header: {
            Text(NSLocalizedString("settings.recognition_pipeline", comment: "Recognition pipeline"))
        } footer: {
            Text(NSLocalizedString(
                hasAnyTranscriptionProvider
                    ? "settings.whisper_provider_key_footer"
                    : "settings.whisper_provider_key_missing_footer",
                comment: "Whisper transcription provider key dependency"
            ))
        }
    }

    /// Apply a transcription-engine choice, intercepting the FluidAudio engine
    /// to trigger a one-time model download (and deferring the change until it
    /// succeeds). Whisper without an OpenAI key is ignored (the row is disabled).
    func selectTranscriptionEngine(_ engine: TranscriptionEngine, settings: AppSettings) {
        if engine == .whisperAPI {
            guard let first = transcriptionProviders.first else { return }
            // Point the transcription provider at a configured, capable provider
            // if the stored one is no longer valid.
            if !transcriptionProviders.contains(where: { $0.id == settings.transcriptionProviderID }) {
                settings.transcriptionProviderID = first.id
            }
        }
        if engine.requiredModelSet == .onDeviceASR && !settings.fluidAudioBatchASRModelsConsented {
            pendingTranscriptionEngine = engine
            showingBatchASRConsent = true
        } else {
            settings.transcriptionEngine = engine
        }
    }

    /// Apply a language-detection choice, intercepting the FluidAudio detector
    /// to trigger the same one-time on-device-ASR model download.
    func selectLanguageDetectionEngine(_ engine: LanguageDetectionEngine, settings: AppSettings) {
        if engine.requiredModelSet == .onDeviceASR && !settings.fluidAudioBatchASRModelsConsented {
            pendingLanguageDetectionEngine = engine
            showingBatchASRConsent = true
        } else {
            settings.languageDetectionEngine = engine
        }
    }

    /// Apply a VAD choice, intercepting the FluidAudio engine to trigger the
    /// one-time Silero VAD model download.
    func selectVADEngine(_ engine: VADEngine, settings: AppSettings) {
        if engine.requiredModelSet == .vad && !settings.fluidAudioVADModelsConsented {
            pendingVADEngine = engine
            showingVADConsent = true
        } else {
            settings.vadEngine = engine
        }
    }

    @ViewBuilder
    func recordingSection(settings: AppSettings) -> some View {
        Section {
            Picker(
                NSLocalizedString("settings.mic_pickup", comment: "Microphone"),
                selection: Binding(
                    get: { settings.micPickup },
                    set: { settings.micPickup = $0 }
                )
            ) {
                ForEach(MicPickup.allCases) { Text($0.displayName).tag($0) }
            }
            Picker(
                NSLocalizedString("settings.audio_quality", comment: "Audio quality"),
                selection: Binding(
                    get: { settings.audioQuality },
                    set: { settings.audioQuality = $0 }
                )
            ) {
                ForEach(AudioQuality.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle(
                NSLocalizedString("settings.live_transcription", comment: "Live transcription"),
                isOn: Binding(
                    get: { settings.liveTranscriptionEnabled },
                    set: { enabled in
                        if enabled && !settings.fluidAudioASRModelsConsented {
                            showingASRConsent = true
                        } else {
                            settings.liveTranscriptionEnabled = enabled
                        }
                    }
                )
            )
            .disabled(downloadingModel != nil)
            if downloadingModel == .liveTranscriptionASR {
                modelDownloadProgressRow
            }
            Toggle(
                NSLocalizedString("settings.require_auth_for_recordings", comment: "Require authentication for recordings"),
                isOn: Binding(
                    get: { settings.requireAuthForRecordings },
                    set: { settings.requireAuthForRecordings = $0 }
                )
            )
            Toggle(
                NSLocalizedString("settings.hide_live_activity_meeting_title", comment: "Hide meeting title on Lock Screen"),
                isOn: Binding(
                    get: { settings.hideLiveActivityMeetingTitle },
                    set: { settings.hideLiveActivityMeetingTitle = $0 }
                )
            )
        } header: {
            Text(NSLocalizedString("settings.recording", comment: "Recording"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("settings.mic_pickup_footer", comment: "Explains pickup modes"))
                Text(NSLocalizedString("settings.require_auth_for_recordings_footer", comment: "Explains authentication and at-rest encryption"))
                Text(NSLocalizedString("settings.hide_live_activity_meeting_title_footer", comment: "Explains Live Activity title redaction"))
            }
        }
    }

    @ViewBuilder
    func diagnosticsSection(settings: AppSettings) -> some View {
        Section {
            Picker(
                NSLocalizedString("settings.log_level", comment: "Logging level"),
                selection: Binding(
                    get: { settings.logLevel },
                    set: { settings.logLevel = $0 }
                )
            ) {
                ForEach(LogLevel.allCases) { Text($0.displayName).tag($0) }
            }
        } header: {
            Text(NSLocalizedString("settings.diagnostics", comment: "Diagnostics"))
        } footer: {
            Text(NSLocalizedString("settings.log_level_footer", comment: "Explains logging levels"))
        }
    }

    /// Indeterminate download indicator shown while a FluidAudio model set is
    /// being fetched. FluidAudio's high-level download API doesn't expose byte
    /// progress, so this is intentionally indeterminate.
    var modelDownloadProgressRow: some View {
        HStack {
            ProgressView()
            Text(NSLocalizedString("settings.model_download.downloading", comment: "Downloading model"))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    func refreshStorage() {
        storageText = AudioFileStore.formattedSize(AudioFileStore.totalAudioBytes())
    }

    func refreshCacheCleanupPreview() {
        Task { @MainActor in
            cacheCleanupPreview = await loadCacheCleanupPreview()
        }
    }

    func loadCacheCleanupPreview() async -> (files: Int, bytes: Int64) {
        await Task.detached(priority: .utility) {
            TempFileCleaner.reclaimableSpace()
        }.value
    }

    func deleteAllData() {
        try? modelContext.delete(model: Meeting.self)
        try? modelContext.save()
        AudioFileStore.deleteAllAudio()
        refreshStorage()
    }

    /// Downloaded on-device models the user can inspect and remove. Only groups
    /// actually present on disk are listed; deleting a known group frees its
    /// space and turns the matching feature off so it can be re-downloaded on
    /// demand. Unassociated FluidAudio folders are shown as a separate entry.
    @ViewBuilder
    var modelsSection: some View {
        Section {
            if installedModels.isEmpty {
                Text(NSLocalizedString("settings.models.none", comment: "No models downloaded"))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(installedModels) { model in
                    HStack {
                        Text(model.displayName)
                        Spacer()
                        Text(AudioFileStore.formattedSize(model.size))
                            .foregroundStyle(Theme.textSecondary)
                        Button {
                            pendingModelDeletion = model
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .tint(.red)
                        .disabled(downloadingModel != nil)
                    }
                }
            }
        } header: {
            Text(NSLocalizedString("settings.models", comment: "On-device models"))
        } footer: {
            Text(NSLocalizedString("settings.models_footer", comment: "Models footer"))
        }
    }

    /// Recompute installed model entries off the main thread.
    func refreshModelSizes() {
        Task { @MainActor in
            installedModels = await Task.detached {
                ModelStore.installedModels()
            }.value
        }
    }

    /// Delete a model entry from disk and turn off any feature that uses it so
    /// the UI reflects the removal and it can be re-downloaded later.
    func deleteModel(_ model: ModelStore.InstalledModel) {
        ModelStore.delete(model)
        guard let group = model.group else {
            pendingModelDeletion = nil
            refreshModelSizes()
            return
        }
        switch group {
        case .liveTranscription:
            settings.liveTranscriptionEnabled = false
            settings.fluidAudioASRModelsConsented = false
        case .onDeviceLanguage:
            settings.fluidAudioBatchASRModelsConsented = false
            // Turn off the engines that depend on the multilingual on-device
            // model so the UI doesn't point at a now-missing model.
            if settings.transcriptionEngine == .fluidAudioParakeet {
                settings.transcriptionEngine = .appleSpeech
            }
            if settings.languageDetectionEngine == .fluidAudioLID {
                settings.languageDetectionEngine = .byTranscriber
            }
        case .diarization:
            settings.fluidAudioDiarizationModelsConsented = false
            settings.diarizationEngine = .heuristic
        case .vad:
            settings.fluidAudioVADModelsConsented = false
            settings.vadEngine = .energyThreshold
        }
        pendingModelDeletion = nil
        refreshModelSizes()
    }

    var configuredProviders: [AIProvider] {
        _ = keyRevision
        return settings.providers.filter {
            KeychainManager.shared.hasValue(for: $0.keychainAccount)
        }
    }

    /// Configured providers that can run cloud (Whisper) transcription — the
    /// candidate list for the transcription-provider picker.
    var transcriptionProviders: [AIProvider] {
        _ = keyRevision
        return settings.providers.filter {
            $0.supportsTranscription && KeychainManager.shared.hasValue(for: $0.keychainAccount)
        }
    }

    /// Whether at least one transcription-capable provider has a key, gating the
    /// Whisper engine selection.
    var hasAnyTranscriptionProvider: Bool {
        !transcriptionProviders.isEmpty
    }

    func ensureSelectedProviderIsConfigured() {
        let providers = configuredProviders
        guard !providers.isEmpty else { return }
        if !providers.contains(where: { $0.id == settings.aiProviderID }) {
            settings.aiProviderID = providers[0].id
        }
    }

    func ensureWhisperSelectionIsAllowed() {
        guard settings.transcriptionEngine == .whisperAPI else { return }
        // Revert to on-device only when no transcription-capable provider has a
        // key; otherwise keep Whisper and repoint at a valid provider if the
        // selected one lost its key or was removed.
        let providers = transcriptionProviders
        if providers.isEmpty {
            settings.transcriptionEngine = .appleSpeech
        } else if !providers.contains(where: { $0.id == settings.transcriptionProviderID }) {
            settings.transcriptionProviderID = providers[0].id
        }
    }
}
