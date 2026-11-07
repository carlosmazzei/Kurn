import KurnCore
import SwiftData
import SwiftUI

struct ChatSourceSheet: View {
    let meeting: Meeting?
    @Binding var scope: ChatSourceScope
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query(sort: \Folder.name) private var folders: [Folder]
    @State private var search = ""

    private var resolved: [Meeting] {
        SourceScopeResolver.resolve(scope, meetings: meetings, tags: tags, folders: folders).meetings
    }

    private var validation: ChatSourceScopeEditor.Validation? {
        ChatSourcePresentation.validation(scope, resolvedMeetingIDs: Set(resolved.map(\.id)), wikiEnabled: settings.wikiEnabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let meeting {
                    Section(NSLocalizedString("chat.sources.mode.meetings", comment: "Meetings")) {
                        Label(meeting.title, systemImage: "lock.fill")
                        Text(NSLocalizedString("chat.sources.locked", comment: "Locked meeting"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section(NSLocalizedString("chat.sources.title", comment: "Sources")) {
                        Picker(NSLocalizedString("chat.sources.mode", comment: "Selection mode"), selection: modeBinding) {
                            ForEach([ChatSourceScope.Kind.meetings, .tags, .folders, .library], id: \.self) { kind in
                                Text(NSLocalizedString(ChatSourcePresentation.modeKey(kind), comment: "Source mode")).tag(kind)
                            }
                        }
                        .accessibilityIdentifier("chat.sources.mode")
                        sourceRows
                    }
                }
                Section(NSLocalizedString("chat.sources.parts", comment: "Global parts")) {
                    ChatPartToggles(parts: partsBinding(), wikiEnabled: settings.wikiEnabled, identifier: "chat.sources.global")
                }
                if meeting == nil {
                    Section(NSLocalizedString("chat.sources.overrides", comment: "Per-meeting parts")) {
                        ForEach(resolved) { item in overrideRow(item) }
                    }
                }
                if let validation {
                    Section { ChatSourceValidationView(validation: validation) }
                }
            }
            .navigationTitle(NSLocalizedString("chat.sources.title", comment: "Sources"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                        .accessibilityIdentifier("chat.sources.done")
                }
            }
            .accessibilityIdentifier("chat.sources.sheet")
        }
    }

    private var modeBinding: Binding<ChatSourceScope.Kind> {
        Binding(get: { scope.kind }, set: { kind in
            var selection = scope
            selection.kind = kind
            selection.selectedIDs = []
            scope = selection
        })
    }

    @ViewBuilder private var sourceRows: some View {
        switch scope.kind {
        case .meetings:
            TextField(NSLocalizedString("chat.sources.search", comment: "Search meetings"), text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("chat.sources.search")
            ForEach(meetings.filter { $0.hasAnyTranscript && ChatSourcePresentation.matchesSearch(search, title: $0.title) }) { item in
                selectionRow(id: item.id, title: item.title, symbol: "text.quote")
            }
        case .tags:
            ForEach(tags) { tag in selectionRow(id: tag.id, title: tag.name, symbol: "tag") }
        case .folders:
            ForEach(folders) { folder in selectionRow(id: folder.id, title: folder.name, symbol: folder.iconName) }
        case .library:
            Label(NSLocalizedString("chat.sources.library.detail", comment: "All transcribed meetings"), systemImage: "books.vertical")
        }
    }

    private func selectionRow(id: UUID, title: String, symbol: String) -> some View {
        Button {
            var selection = scope
            if !selection.selectedIDs.insert(id).inserted { selection.selectedIDs.remove(id) }
            scope = selection
        } label: {
            HStack {
                Image(systemName: symbol).accessibilityHidden(true)
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: scope.selectedIDs.contains(id) ? "checkmark.circle.fill" : "circle")
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(scope.selectedIDs.contains(id) ? .isSelected : [])
        .accessibilityIdentifier("chat.sources.select.\(id.uuidString)")
    }

    private func overrideRow(_ item: Meeting) -> some View {
        DisclosureGroup {
            Toggle(NSLocalizedString("chat.sources.use_global", comment: "Use global parts"), isOn: Binding(
                get: { scope.partOverrides[item.id] == nil },
                set: { useGlobal in
                    var selection = scope
                    selection.partOverrides[item.id] = useGlobal ? nil : selection.parts
                    scope = selection
                }
            ))
            .accessibilityIdentifier("chat.sources.use_global.\(item.id.uuidString)")
            if scope.partOverrides[item.id] != nil {
                ChatPartToggles(parts: partsBinding(for: item.id), wikiEnabled: settings.wikiEnabled,
                                identifier: "chat.sources.override.\(item.id.uuidString)")
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                if scope.partOverrides[item.id] != nil {
                    Text(NSLocalizedString("chat.sources.custom", comment: "Custom parts"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func partsBinding(for id: UUID? = nil) -> Binding<Set<ChatSourcePart>> {
        Binding(get: { id.map { scope.parts(for: $0) } ?? scope.parts }, set: { parts in
            var selection = scope
            if let id { selection.partOverrides[id] = parts } else { selection.parts = parts }
            scope = selection
        })
    }
}

private struct ChatPartToggles: View {
    @Binding var parts: Set<ChatSourcePart>
    let wikiEnabled: Bool
    let identifier: String

    var body: some View {
        ForEach(ChatSourcePart.allCases, id: \.self) { part in
            Toggle(NSLocalizedString(ChatSourcePresentation.partKey(part), comment: "Source part"), isOn: Binding(
                get: { (part != .wiki || wikiEnabled) && parts.contains(part) },
                set: { enabled in
                    if enabled { parts.insert(part) } else { parts.remove(part) }
                }
            ))
            .disabled(part == .wiki && !wikiEnabled)
            .accessibilityIdentifier("\(identifier).\(part.rawValue)")
        }
        if !wikiEnabled {
            Text(NSLocalizedString("chat.sources.wiki_disabled", comment: "Wiki setting is off"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct ChatSourceValidationView: View {
    let validation: ChatSourceScopeEditor.Validation

    var body: some View {
        Label(NSLocalizedString(ChatSourcePresentation.validationKey(validation), comment: "Select valid sources"),
              systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("chat.sources.validation")
    }
}
