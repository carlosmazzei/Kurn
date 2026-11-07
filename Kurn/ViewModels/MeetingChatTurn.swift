import Foundation
import KurnCore

extension MeetingChatViewModel {
    /// One rendered turn in the conversation.
    struct Turn: Identifiable {
        let id: UUID
        let role: ChatMessage.Role
        var text: String
        var citations: [SemanticSearchService.Hit] = []
        /// Live harness usage and estimated USD cost; legacy providers attach
        /// usage at completion, or nil when unreported. Unknown models have no cost estimate.
        var usage: TokenUsage?
        var costUSD: Double?
        /// Wall-clock time the reply took to fully generate, set once it
        /// finishes.
        var elapsedSeconds: TimeInterval?
        var steps: [ChatAgentStep] = []
        var artifacts: [ChatArtifactReference] = []
        var artifactOrigins: [UUID: ChatArtifactOrigin] = [:]

        mutating func recordArtifacts(from previous: [ChatDocumentArtifact], to current: [ChatDocumentArtifact], origin: ChatArtifactOrigin) {
            artifacts = ChatArtifactReference.updating(artifacts, from: previous, to: current)
            for reference in artifacts where previous.first(where: { $0.id == reference.id })?.version != reference.version {
                artifactOrigins[reference.id] = origin
            }
        }

        mutating func inheritArtifacts(from other: Self) {
            artifacts = ChatArtifactReference.merging(artifacts, with: other.artifacts)
            artifactOrigins.merge(other.artifactOrigins) { _, new in new }
        }

        /// `id` defaults to a fresh `UUID` for a brand-new turn; restoring a
        /// saved one (`Turn.init(_ persisted:)` below) passes its stored id
        /// through instead, so a turn's identity survives a save/load
        /// round trip.
        init(
            id: UUID = UUID(),
            role: ChatMessage.Role,
            text: String,
            citations: [SemanticSearchService.Hit] = [],
            usage: TokenUsage? = nil,
            costUSD: Double? = nil,
            elapsedSeconds: TimeInterval? = nil,
            steps: [ChatAgentStep] = []
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.citations = citations
            self.usage = usage
            self.costUSD = costUSD
            self.elapsedSeconds = elapsedSeconds
            self.steps = steps
        }
    }
}

extension PersistedChatTurn {
    /// Snapshot of a rendered `Turn` for JSON storage.
    init(_ turn: MeetingChatViewModel.Turn) {
        self.init(
            id: turn.id,
            role: turn.role,
            text: turn.text,
            citations: turn.citations.map(PersistedCitation.init),
            usage: turn.usage,
            costUSD: turn.costUSD,
            elapsedSeconds: turn.elapsedSeconds,
            steps: turn.steps.isEmpty ? nil : turn.steps,
            artifacts: turn.artifacts.isEmpty ? nil : turn.artifacts,
            artifactOrigins: turn.artifactOrigins.isEmpty ? nil : turn.artifactOrigins
        )
    }
}

extension PersistedCitation {
    init(_ hit: SemanticSearchService.Hit) {
        self.init(
            meetingID: hit.meetingID,
            recordingID: hit.recordingID,
            meetingTitle: hit.meetingTitle,
            start: hit.start,
            speakerLabel: hit.speakerLabel,
            text: hit.text
        )
    }
}

extension MeetingChatViewModel.Turn {
    /// Restores a rendered `Turn` from a saved session. `end`/`score` have no
    /// persisted counterpart (unused once retrieval ranking is done), so
    /// reconstructed citations zero them — display and jump-to-citation only
    /// ever read `start`/`speakerLabel`/`text`/the two ids.
    init(_ persisted: PersistedChatTurn) {
        self.init(
            id: persisted.id,
            role: persisted.role,
            text: persisted.text,
            citations: persisted.citations.map { citation in
                SemanticSearchService.Hit(
                    chunkID: UUID(),
                    meetingID: citation.meetingID,
                    recordingID: citation.recordingID,
                    text: citation.text,
                    start: citation.start,
                    end: citation.start,
                    speakerLabel: citation.speakerLabel,
                    score: 0,
                    meetingTitle: citation.meetingTitle
                )
            },
            usage: persisted.usage,
            costUSD: persisted.costUSD,
            elapsedSeconds: persisted.elapsedSeconds,
            steps: persisted.steps ?? []
        )
        artifacts = persisted.artifacts ?? []
        artifactOrigins = persisted.artifactOrigins ?? [:]
    }
}
