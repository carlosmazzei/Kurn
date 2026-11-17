import Foundation
import KurnCore
import Observation

@MainActor @Observable
final class KnowledgeSettingsViewModel {
    enum SettingsAction: Hashable { case preview, coverage, pages }
    struct SettingsOperations {
        var preview: @MainActor (Set<UUID>, Bool) async throws -> KnowledgeBackfillPlan
        var coverage: @MainActor (Set<UUID>) async throws -> KnowledgeScopedMaintenanceReport
        var pages: @MainActor (Set<UUID>) async throws -> Void
    }
    private(set) var plan: KnowledgeBackfillPlan?
    private(set) var coverage: KnowledgeScopedMaintenanceReport?
    private(set) var isBusy = false
    var error: AppError?
    @ObservationIgnored private var requestID = UUID()

    func invalidate() {
        requestID = UUID()
        plan = nil; coverage = nil; error = nil; isBusy = false
    }

    func perform(_ action: SettingsAction, meetingIDs: Set<UUID>, rebuild: Bool, settings: AppSettings, operations: SettingsOperations) async {
        guard !Task.isCancelled else { return }
        invalidate()
        let request = requestID
        guard settings.knowledgeEnabled, let controls = settings.knowledgeControls,
              !meetingIDs.isEmpty, meetingIDs.count <= 16, meetingIDs.allSatisfy(controls.allows) else { reportError(); return }
        isBusy = true
        defer { if requestID == request { isBusy = false } }
        do {
            switch action {
            case .preview:
                let result = try await operations.preview(meetingIDs, rebuild)
                guard current(request, controls: controls, settings: settings) else { return }
                guard result.controls == controls, result.read.meetingIDs == meetingIDs,
                      result.read.sources.count == meetingIDs.count else { reportError(); return }
                plan = result
            case .coverage:
                let result = try await operations.coverage(meetingIDs)
                guard current(request, controls: controls, settings: settings) else { return }
                guard result.scope == "workspace", result.sources.count == meetingIDs.count,
                      Set(result.sources.map(\.meetingID)) == meetingIDs else { reportError(); return }
                coverage = result
            case .pages:
                try await operations.pages(meetingIDs)
            }
        } catch { if current(request, controls: controls, settings: settings) { reportError() } }
    }

    func reportError() { error = .resourceUnavailable(NSLocalizedString("knowledge.settings.failed", comment: "Knowledge operation failed")) }

    private func current(_ request: UUID, controls: KnowledgeControls, settings: AppSettings) -> Bool {
        requestID == request && !Task.isCancelled && settings.knowledgeEnabled && settings.knowledgeControls == controls
    }
}
