import AgentHarness
import Foundation
import KurnCore

/// `get_coverage` (K5.1): how much of each selected recording the latest compilation examined, the
/// K2.2 maintenance measure (`KnowledgeCoverageRead`). It reads counts and states, never content,
/// through its own store read, authorized like every knowledge tool before and after the read.
extension ChatKnowledgeTools {
    static func coverage(_ params: Parameters, source: ChatKnowledgeSource, meetings: Set<UUID>,
                         provider: AIProvider) async throws -> AgentToolOutput {
        let meeting = try params.optionalUUID("meetingID")
        if let meeting, !meetings.contains(meeting) { throw Invalid("Unknown meetingID.") }
        try await authorize(meetings, source: source, provider: provider)
        let read = try await source.coverage(meetings)
        try Task.checkCancellation()
        guard read.meetingIDs == meetings else { throw Invalid("Knowledge is not authorized for these sources.") }
        try await authorize(meetings, source: source, provider: provider, classifications: read.sourceClassifications)
        let shown = read.meetings.filter { item in meeting.map { $0 == item.meetingID } ?? true }
            .sorted { $0.meetingID.uuidString < $1.meetingID.uuidString }
        let recordings = shown.flatMap { item in item.recordings.map { (item.meetingID, $0) } }
        let header = ChatKnowledgeToolText.coverageHeader(recordings.map(\.1), meetings: shown.count, isComplete: read.isComplete)
        return ChatKnowledgeToolText.output(header: header, lines: recordings.map { ChatKnowledgeToolText.coverage($0.1, meeting: $0.0) },
                                            offset: params.offset, limit: params.limit,
                                            scope: (read.revision, read.meetings.count))
    }
}

extension ChatKnowledgeToolText {
    static func coverageHeader(_ recordings: [KnowledgeMaintenanceCoverage], meetings: Int, isComplete: Bool) -> String {
        let examined = recordings.reduce(0) { $0 + $1.examinedSegments }
        let total = recordings.reduce(0) { $0 + $1.totalSegments }
        let current = recordings.filter { $0.state == .current }.count
        return "coverage: \(examined) of \(total) segments examined in \(meetings) meetings; "
            + "\(current) of \(recordings.count) recordings current; complete: \(isComplete ? "yes" : "no")\n"
            + "(segments the latest compilation read, not its accuracy; a recording that is not current needs compiling again)\n"
            + "recordings (meeting | recording | state | examined of total segments):"
    }

    static func coverage(_ coverage: KnowledgeMaintenanceCoverage, meeting: UUID) -> Rendered {
        Rendered(text: "- meeting \(meeting.uuidString) | recording \(coverage.recordingID.uuidString) | state: \(coverage.state.rawValue)"
                     + " | \(coverage.examinedSegments) of \(coverage.totalSegments) segments", omittedScalars: 0)
    }
}
