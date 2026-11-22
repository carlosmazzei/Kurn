import KurnCore
import SwiftData
import SwiftUI

struct KnowledgeScopeSettingsView: View {
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var controls: KnowledgeControls
    @State private var error: AppError?

    init(controls: KnowledgeControls) { _controls = State(initialValue: controls) }

    var body: some View {
        Form {
            Section {
                Toggle(KnowledgeSettingsCopy.text("all"), isOn: Binding(get: { controls.includedMeetingIDs == nil }, set: {
                    controls.setAllMeetings($0)
                }))
                .accessibilityIdentifier("knowledge.settings.all")
                ForEach(meetings) { meeting in
                    Button { controls.toggleMeeting(meeting.id) } label: {
                        HStack {
                            Image(systemName: controls.allows(meeting.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(controls.allows(meeting.id) ? Theme.link : Theme.textTertiary)
                                .accessibilityHidden(true)
                            Text(verbatim: meeting.title).foregroundStyle(Theme.textPrimary)
                        }
                    }
                    .accessibilityAddTraits(controls.allows(meeting.id) ? .isSelected : [])
                    .accessibilityIdentifier("knowledge.settings.source")
                }
            } footer: { Text(KnowledgeSettingsCopy.text("scope_detail")) }
        }
        .navigationTitle(KnowledgeSettingsCopy.text("scope"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("common.done", comment: "Done")) {
                    do { try settings.saveKnowledgeControls(controls); dismiss() }
                    catch { self.error = .persistenceFailed(KnowledgeSettingsCopy.text("failed")) }
                }
                .accessibilityIdentifier("knowledge.settings.scopeDone")
            }
        }
        .errorAlert($error)
    }

}

struct KnowledgeCoverageSection: View {
    let report: KnowledgeMaintenanceReport
    var body: some View {
        Section(KnowledgeSettingsCopy.text("coverage")) {
            Text(String(format: KnowledgeSettingsCopy.text("coverage_counts"), report.coverage.reduce(0) { $0 + $1.examinedSegments },
                report.coverage.reduce(0) { $0 + $1.totalSegments }))
            Text(KnowledgeSettingsCopy.text("coverage_detail"))
            if !report.isComplete || report.coverage.contains(where: { $0.state != .current }) { Text(KnowledgeSettingsCopy.text("needs_work")) }
        }
    }
}
