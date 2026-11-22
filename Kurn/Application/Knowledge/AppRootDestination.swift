import Foundation

enum AppRootDestination: String, CaseIterable, Hashable {
    case meetings, knowledge, ask, documents

    var title: String {
        switch self {
        case .meetings: NSLocalizedString("knowledge.browser.meetings", comment: "Meetings")
        case .knowledge: NSLocalizedString("knowledge.browser.title", comment: "Knowledge")
        case .ask: NSLocalizedString("knowledge.browser.ask", comment: "Ask")
        case .documents: NSLocalizedString("documents.title", comment: "Documents")
        }
    }

    var systemImage: String {
        switch self {
        case .meetings: "mic"
        case .knowledge: "book"
        case .ask: "bubble.left.and.bubble.right"
        case .documents: "doc.text"
        }
    }
}
