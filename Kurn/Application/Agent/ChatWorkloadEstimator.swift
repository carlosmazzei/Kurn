import AgentHarness
import Foundation
import KurnCore

/// Counts only authorized on-device content. It never reads remote sources or logs their text.
@MainActor
enum ChatWorkloadEstimator {
    static func estimate(meetings: [Meeting], scope: ChatSourceScope) -> AgentWorkload {
        var units = 0
        var pages = 0
        // UTF-8 bytes conservatively bound scalar count, while transcript item limits
        // can require more pages even when the text itself is short.
        func textPages(_ text: String) -> Int { max(1, (text.utf8.count + 7_999) / 8_000) }
        for meeting in meetings {
            let parts = scope.parts(for: meeting.id)
            if parts.contains(.transcript) {
                units += 1
                let segments = meeting.recordings.flatMap { $0.transcript?.segments ?? [] }
                let bytes = segments.reduce(0) { $0 + $1.text.utf8.count }
                pages += max(1, max((bytes + 7_999) / 8_000, (segments.count + 9) / 10))
            }
            if parts.contains(.summary), let summary = meeting.latestSummary {
                units += 1
                pages += textPages(SummaryService.markdownText(from: summary.sections))
            }
            if parts.contains(.wiki), let wiki = meeting.wikiArticle {
                units += 1
                pages += textPages(wiki.bodyMarkdown)
            }
            if parts.contains(.attachments), !meeting.attachments.isEmpty {
                units += 1
                pages += (meeting.attachments.count + 49) / 50
                for attachment in meeting.attachments {
                    if let text = attachment.extractedText { pages += textPages(text) }
                }
            }
        }
        return AgentWorkload(sourceCount: meetings.count, readableParts: units, estimatedReadPages: pages)
    }
}
