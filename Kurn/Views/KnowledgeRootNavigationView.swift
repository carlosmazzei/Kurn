import Combine
import SwiftUI
import UIKit

/// The reviewed four-destination layout, enabled with knowledgeEnabled. Each
/// destination owns its stack; tab changes retain the meetings controls and
/// the app-owned library conversation rather than presenting another chat.
struct KnowledgeRootNavigationView: View {
    @State private var tab: AppRootDestination
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var keyboardVisible = false
    @State private var rootBarHeight: CGFloat = 76
    @State private var selection: LibrarySelection = .allMeetings
    let initialKnowledgeSourceIDs: Set<UUID>

    init(initialTab: AppRootDestination = .meetings, initialKnowledgeSourceIDs: Set<UUID> = []) {
        _tab = State(initialValue: initialTab)
        self.initialKnowledgeSourceIDs = initialKnowledgeSourceIDs
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                destinations
                if !keyboardVisible {
                    rootBar(showTitles: geometry.size.width >= 360 && !dynamicTypeSize.isAccessibilitySize)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rootBarHeight = $0 }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
    }

    private var destinations: some View {
        TabView(selection: $tab) {
            ZStack {
                NavigationStack { MeetingsListView(selection: $selection, usesRootTabs: true) }
            }
            .hostsRecordingMiniBar()
            .toolbar(.hidden, for: .tabBar)
            .padding(.bottom, keyboardVisible ? 0 : rootBarHeight)
            .tabItem { Label(AppRootDestination.meetings.title, systemImage: AppRootDestination.meetings.systemImage) }
            .tag(AppRootDestination.meetings)

            KnowledgeLibraryDestination(initialMeetingIDs: initialKnowledgeSourceIDs)
                .hostsRecordingMiniBar()
                .toolbar(.hidden, for: .tabBar)
                .padding(.bottom, keyboardVisible ? 0 : rootBarHeight)
                .tabItem { Label(AppRootDestination.knowledge.title, systemImage: AppRootDestination.knowledge.systemImage) }
                .tag(AppRootDestination.knowledge)

            ZStack {
                NavigationStack {
                    MeetingChatView(meeting: nil)
                        .navigationTitle(NSLocalizedString("chat.ask.title", comment: "Ask across meetings"))
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .hostsRecordingMiniBar()
            .toolbar(.hidden, for: .tabBar)
            .padding(.bottom, keyboardVisible ? 0 : rootBarHeight)
            .tabItem { Label(AppRootDestination.ask.title, systemImage: AppRootDestination.ask.systemImage) }
            .tag(AppRootDestination.ask)

            ZStack { NavigationStack { DocumentsListView() } }
                .hostsRecordingMiniBar()
                .toolbar(.hidden, for: .tabBar)
                .padding(.bottom, keyboardVisible ? 0 : rootBarHeight)
                .tabItem { Label(AppRootDestination.documents.title, systemImage: AppRootDestination.documents.systemImage) }
                .tag(AppRootDestination.documents)
        }
    }

    /// A native tab bar has no slot for a separate capture action. Keep the
    /// four destination stacks, but give their controls and the prominent
    /// recorder separate system-glass groups. Each tab reserves the measured
    /// bar height inside its host: an outer safe-area inset does not reach
    /// nested UIKit navigation stacks and lets chat/audio overlays cover it.
    private func rootBar(showTitles: Bool) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    ForEach(AppRootDestination.allCases, id: \.self) { destination in
                        Button { tab = destination } label: {
                            VStack(spacing: 3) {
                                Image(systemName: destination.systemImage)
                                    .font(.system(size: 22, weight: .semibold))
                                    .accessibilityHidden(true)
                                if showTitles {
                                    Text(destination.title)
                                        .font(Theme.caption2Emphasized)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .contentShape(Rectangle())
                            .background {
                                if tab == destination { Capsule().fill(.tint.opacity(0.15)) }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(tab == destination ? Color.accentColor : Theme.textPrimary)
                        .accessibilityLabel(destination.title)
                        .accessibilityAddTraits(tab == destination ? .isSelected : [])
                        .accessibilityIdentifier("root.destination.\(destination.rawValue)")
                    }
                }
                .padding(4)
                .glassEffect(.regular, in: .capsule)

                RecordingActionButton()
                    .font(.system(size: 26, weight: .semibold))
                    .labelStyle(.iconOnly)
                    .controlSize(.large)
                    .buttonBorderShape(.circle)
                    .fixedSize()
            }
        }
        .frame(maxWidth: 600)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

}
