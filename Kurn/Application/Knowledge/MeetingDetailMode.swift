import Foundation

enum MeetingDetailMode: String, Hashable, CaseIterable {
    case recordings, transcript, summary, knowledge, chat

    static func visible(knowledgeEnabled: Bool) -> [Self] { allCases.filter { knowledgeEnabled || $0 != .knowledge } }

    var systemImage: String {
        switch self {
        case .recordings: "mic"
        case .transcript: "text.alignleft"
        case .summary: "sparkles"
        case .knowledge: "book.pages"
        case .chat: "bubble.left.and.text.bubble.right"
        }
    }

    var title: String { NSLocalizedString("tab." + rawValue, comment: "Meeting detail mode") }
}
