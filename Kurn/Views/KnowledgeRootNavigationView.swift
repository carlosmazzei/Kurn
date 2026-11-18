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
                    rootBar(showsRecordTitle: geometry.size.width >= 360 && !dynamicTypeSize.isAccessibilitySize)
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
    /// four destination stacks, but draw their controls the way the legacy
    /// bottom toolbar does (regular-weight icons, no titles beneath) in one
    /// glass capsule, and the recorder in its own, titled like the legacy
    /// toolbar's record button. Each tab reserves the measured bar height
    /// inside its host: an outer safe-area inset does not reach nested UIKit
    /// navigation stacks and lets chat/audio overlays cover it.
    private func rootBar(showsRecordTitle: Bool) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    ForEach(AppRootDestination.allCases, id: \.self) { destination in
                        Button { tab = destination } label: {
                            Image(systemName: destination.systemImage)
                                .font(.body)
                                .imageScale(.large)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(tab == destination ? Color.accentColor : Theme.textPrimary)
                        .accessibilityLabel(destination.title)
                        .accessibilityAddTraits(tab == destination ? .isSelected : [])
                        .accessibilityIdentifier("root.destination.\(destination.rawValue)")
                    }
                }
                .padding(.horizontal, 4)
                .glassEffect(.regular.interactive(), in: .capsule)

                RecordingActionButton()
                    .labelStyle(RootRecordLabelStyle(showsTitle: showsRecordTitle))
                    .controlSize(.large)
                    .fixedSize()
            }
        }
        .frame(maxWidth: 600)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

}

/// The legacy toolbar shows "Record" beside its icon; on a narrow screen or at
/// accessibility text sizes the title would squeeze the destinations, so only
/// the icon stays (the accessibility label still names the action).
private struct RootRecordLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        if showsTitle {
            Label(configuration)
                .labelStyle(.titleAndIcon)
        } else {
            Label(configuration)
                .labelStyle(.iconOnly)
        }
    }
}
