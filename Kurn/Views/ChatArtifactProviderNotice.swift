import SwiftUI

struct ChatArtifactProviderNotice: View {
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(NSLocalizedString("chat.artifact.cloud_required", comment: "Document provider requirement"), systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat.artifact.provider.notice")
            Button { showingSettings = true } label: {
                Label(NSLocalizedString("chat.artifact.configure_provider", comment: "Configure provider"), systemImage: "gearshape")
            }
            .accessibilityIdentifier("chat.artifact.provider.settings")
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
        }
    }
}
