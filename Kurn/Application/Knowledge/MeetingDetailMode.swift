import Foundation
import Observation

enum MeetingDetailMode: String, Hashable, CaseIterable {
    case summary, transcript, recordings, knowledge

    static func visible(knowledgeEnabled: Bool) -> [Self] { allCases.filter { knowledgeEnabled || $0 != .knowledge } }

    var systemImage: String {
        switch self {
        case .recordings: "waveform"
        case .transcript: "text.alignleft"
        case .summary: "sparkles"
        case .knowledge: "book"
        }
    }

    var title: String { NSLocalizedString("tab." + rawValue, comment: "Meeting detail mode") }
}

/// Remembers which detail tab each meeting was left on, for the process
/// lifetime only: reopening a meeting returns to the Summary tab it opened
/// on unless the user explicitly chose another section. Injected from
/// `KurnApp`; optional in the environment so previews without it still work.
@MainActor @Observable
final class MeetingDetailTabMemory {
    private var tabs: [UUID: MeetingDetailMode] = [:]

    init() {}

    func tab(for meetingID: UUID) -> MeetingDetailMode? { tabs[meetingID] }

    func set(_ tab: MeetingDetailMode, for meetingID: UUID) { tabs[meetingID] = tab }
}
