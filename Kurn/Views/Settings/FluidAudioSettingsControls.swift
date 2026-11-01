import KurnCore
import SwiftUI

private struct FluidAudioSelectedModelDownloadButton: View {
    let isInstalled: Bool
    let isSelectionEnabled: Bool
    let action: () -> Void

    var body: some View {
        let state = FluidAudioModelPresentation.downloadActionState(
            isInstalled: isInstalled,
            isSelectionEnabled: isSelectionEnabled
        )
        if state.isVisible {
            Button(NSLocalizedString("settings.fluid_audio.download_selected", comment: ""), action: action)
                .disabled(!state.isEnabled)
        }
    }
}

struct FluidAudioASRSettingsControls: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelDownloadController.self) private var downloads

    var body: some View {
        Picker(
            NSLocalizedString("settings.fluid_audio.asr_model", comment: ""),
            selection: Binding(
                get: { settings.fluidAudioASRModel },
                set: { downloads.selectFluidAudioASRModel($0, settings: settings) }
            )
        ) {
            ForEach(FluidAudioASRModel.allCases) { model in
                Text(verbatim: FluidAudioModelPresentation.modelLabel(name: model.displayName, approximateBytes: model.approximateBytes))
                    .tag(model)
                    .disabled(!FluidAudioModelPresentation.canSelectASRModel(
                        model,
                        language: settings.defaultLanguage,
                        isDownloading: downloads.isDownloading
                    ))
            }
        }
        .accessibilityIdentifier("settings.fluid_audio.asr_model")
        .disabled(downloads.isDownloading)
        FluidAudioSelectedModelDownloadButton(
            isInstalled: downloads.isFluidAudioASRInstalled(settings.fluidAudioASRModel),
            isSelectionEnabled: FluidAudioModelPresentation.canSelectASRModel(
                settings.fluidAudioASRModel,
                language: settings.defaultLanguage,
                isDownloading: downloads.isDownloading
            ),
            action: { downloads.selectFluidAudioASRModel(settings.fluidAudioASRModel, settings: settings) }
        )
        Text(NSLocalizedString("settings.fluid_audio.asr_english_only", comment: ""))
            .font(.footnote)
            .foregroundStyle(.secondary)
        Text(NSLocalizedString("settings.fluid_audio.asr_language_footer", comment: ""))
            .font(.footnote)
            .foregroundStyle(.secondary)
        if !settings.fluidAudioASRModel.supports(settings.defaultLanguage) {
            Text(NSLocalizedString("settings.fluid_audio.asr_language_unavailable", comment: ""))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct FluidAudioDiarizationSettingsControls: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelDownloadController.self) private var downloads

    var body: some View {
        Picker(
            NSLocalizedString("settings.fluid_audio.diarization_model", comment: ""),
            selection: Binding(
                get: { settings.fluidAudioDiarizationModel },
                set: { downloads.selectFluidAudioDiarizationModel($0, settings: settings) }
            )
        ) {
            ForEach(FluidAudioDiarizationModel.allCases) { model in
                Text(verbatim: FluidAudioModelPresentation.modelLabel(name: model.displayName, approximateBytes: model.approximateBytes))
                    .tag(model)
            }
        }
        .accessibilityIdentifier("settings.fluid_audio.diarization_model")
        .disabled(downloads.isDownloading)
        FluidAudioSelectedModelDownloadButton(
            isInstalled: downloads.isFluidAudioDiarizationInstalled(settings.fluidAudioDiarizationModel),
            isSelectionEnabled: !downloads.isDownloading,
            action: { downloads.selectFluidAudioDiarizationModel(settings.fluidAudioDiarizationModel, settings: settings) }
        )
        if settings.fluidAudioDiarizationModel == .pyannote {
            Picker(
                NSLocalizedString("settings.fluid_audio.segmentation_batch", comment: ""),
                selection: Binding(
                    get: { settings.fluidAudioSegmentationBatchSize },
                    set: { settings.fluidAudioSegmentationBatchSize = $0 }
                )
            ) {
                ForEach(FluidAudioSegmentationBatchSize.allCases) { batchSize in
                    Text(verbatim: FluidAudioModelPresentation.batchSizeLabel(batchSize)).tag(batchSize)
                }
            }
            .accessibilityIdentifier("settings.fluid_audio.segmentation_batch")
            .disabled(downloads.isDownloading)
            Text(NSLocalizedString("settings.fluid_audio.segmentation_batch_footer", comment: ""))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Text(NSLocalizedString("settings.fluid_audio.nemotron_diarization_footer", comment: ""))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct FluidAudioLiveSettingsControls: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelDownloadController.self) private var downloads

    var body: some View {
        Picker(
            NSLocalizedString("settings.fluid_audio.live_model", comment: ""),
            selection: Binding(
                get: { settings.fluidAudioLiveModel },
                set: { downloads.selectFluidAudioLiveModel($0, settings: settings) }
            )
        ) {
            ForEach(FluidAudioLiveModel.allCases) { model in
                Text(verbatim: FluidAudioModelPresentation.liveModelLabel(model))
                    .tag(model)
                    .disabled(!FluidAudioModelPresentation.canSelectLiveModel(
                        model,
                        language: settings.defaultLanguage,
                        isDownloading: downloads.isDownloading
                    ))
            }
        }
        .accessibilityIdentifier("settings.fluid_audio.live_model")
        .disabled(downloads.isDownloading)
        FluidAudioSelectedModelDownloadButton(
            isInstalled: FluidAudioModelPresentation.isLiveModelInstalled(
                settings.fluidAudioLiveModel,
                automaticInstalled: downloads.isAutomaticFluidAudioLiveInstalled,
                unifiedInstalled: downloads.isFluidAudioUnifiedStreamingInstalled
            ),
            isSelectionEnabled: FluidAudioModelPresentation.canSelectLiveModel(
                settings.fluidAudioLiveModel,
                language: settings.defaultLanguage,
                isDownloading: downloads.isDownloading
            ),
            action: { downloads.selectFluidAudioLiveModel(settings.fluidAudioLiveModel, settings: settings) }
        )
        if let guidance = FluidAudioModelPresentation.liveLanguageGuidance(.nemotronUnified, language: settings.defaultLanguage) {
            Text(verbatim: guidance)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        Text(NSLocalizedString("settings.fluid_audio.live_model_footer", comment: ""))
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
