import SwiftUI

struct FluidAudioModelDownloadConsent: ViewModifier {
    @Bindable var downloads: ModelDownloadController
    let settings: AppSettings

    func body(content: Content) -> some View {
        content.kurnDialog(
            isPresented: $downloads.showingFluidAudioModelConsent,
            iconSystemName: "arrow.down.circle.fill",
            iconTint: Theme.info,
            title: NSLocalizedString("settings.model_download.title", comment: ""),
            message: FluidAudioModelPresentation.consentMessage(
                modelName: downloads.pendingFluidAudioModelName,
                approximateBytes: downloads.pendingFluidAudioModelBytes
            ),
            primaryTitle: NSLocalizedString("settings.model_download.allow", comment: ""),
            primaryAction: { downloads.confirmFluidAudioModel(settings: settings) },
            secondaryTitle: NSLocalizedString("common.cancel", comment: ""),
            secondaryAction: { downloads.cancelFluidAudioModel() }
        )
    }
}

extension View {
    func fluidAudioModelDownloadConsent(_ downloads: ModelDownloadController, settings: AppSettings) -> some View {
        modifier(FluidAudioModelDownloadConsent(downloads: downloads, settings: settings))
    }
}
