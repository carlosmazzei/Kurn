import SwiftUI

/// Shown where an agent-capable provider is required but the configured one
/// cannot chat: a full empty state with a direct route into provider
/// settings. The composer is hidden entirely wherever this renders.
struct ChatArtifactProviderNotice: View {
    /// The meeting this chat is scoped to; `nil` for the library-wide Ask —
    /// the description then stays generic.
    var meetingTitle: String?
    @State private var showingSettings = false

    var body: some View {
        ContentUnavailableView {
            Label(NSLocalizedString("chat.provider.title", comment: "Connect an AI provider"),
                  systemImage: "icloud.slash")
        } description: {
            Text(meetingTitle.map {
                String(format: NSLocalizedString(
                    "chat.provider.subtitle.meeting",
                    comment: "Provider notice description for a meeting-scoped chat"), $0)
            } ?? NSLocalizedString("chat.provider.subtitle", comment: "Provider notice description"))
        } actions: {
            Button(NSLocalizedString("chat.provider.setup", comment: "Set up provider")) {
                showingSettings = true
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.ink)
            .foregroundStyle(Theme.onInk)
            .accessibilityIdentifier("chat.artifact.provider.settings")
        }
        .accessibilityIdentifier("chat.artifact.provider.notice")
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                ProvidersSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(NSLocalizedString("common.done", comment: "Done")) {
                                showingSettings = false
                            }
                        }
                    }
            }
        }
    }
}
