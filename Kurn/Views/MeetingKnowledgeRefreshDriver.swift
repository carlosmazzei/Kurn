import Combine
import CoreData
import SwiftUI

/// Store-save notifications are invalidation signals only: no live model or
/// notification payload crosses into the read DTO. Reads never save anything.
struct MeetingKnowledgeRefreshDriver: View {
    let meetingID: UUID
    let model: MeetingKnowledgeViewModel
    let refreshID: Int
    @Environment(AppSettings.self) private var settings
    @Environment(KnowledgeCompilationCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var phase
    @State private var revision = 0

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task(id: "\(meetingID):\(revision):\(refreshID)") {
                if revision > 0 {
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                }
                await model.load(meetingID: meetingID, isEnabled: { settings.knowledgeEnabled }, reader: {
                    try await coordinator.readMeetingKnowledge(meetingID: meetingID)
                })
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave).receive(on: RunLoop.main)) { _ in
                refresh()
            }
            .onChange(of: phase) { _, phase in if phase == .active { refresh() } }
            .onDisappear { model.invalidate() }
    }

    private func refresh() {
        model.invalidate()
        revision += 1
    }
}
