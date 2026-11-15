import AgentHarness
import Foundation
import KurnCore

extension MeetingChatViewModel {
    /// One rendered turn in the conversation.
    struct Turn: Identifiable {
        let id: UUID
        let role: ChatMessage.Role
        var text: String
        /// Live harness usage and estimated USD cost, or nil when unreported. Unknown models have
        /// no cost estimate.
        var usage: TokenUsage?
        var costUSD: Double?
        /// Wall-clock time the reply took to fully generate, set once it
        /// finishes.
        var elapsedSeconds: TimeInterval?
        var steps: [AgentRunStep] = []
        var artifacts: [ChatArtifactReference] = []
        var artifactOrigins: [UUID: ChatArtifactOrigin] = [:]

        mutating func recordArtifacts(from previous: [ChatDocumentArtifact], to current: [ChatDocumentArtifact], origin: ChatArtifactOrigin,
                                      priorOrigins: [UUID: ChatArtifactOrigin] = [:]) {
            artifacts = ChatArtifactReference.updating(artifacts, from: previous, to: current)
            for reference in artifacts where previous.first(where: { $0.id == reference.id })?.version != reference.version {
                var revised = origin
                revised.sources = origin.sources?.retaining(artifactOrigins[reference.id]?.sources ?? priorOrigins[reference.id]?.sources)
                artifactOrigins[reference.id] = revised
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
            usage: TokenUsage? = nil,
            costUSD: Double? = nil,
            elapsedSeconds: TimeInterval? = nil,
            steps: [AgentRunStep] = []
        ) {
            self.id = id
            self.role = role
            self.text = text
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
            usage: turn.usage,
            costUSD: turn.costUSD,
            elapsedSeconds: turn.elapsedSeconds,
            steps: turn.steps.isEmpty ? nil : turn.steps,
            artifacts: turn.artifacts.isEmpty ? nil : turn.artifacts,
            artifactOrigins: turn.artifactOrigins.isEmpty ? nil : turn.artifactOrigins
        )
    }
}

extension MeetingChatViewModel.Turn {
    /// Restores a rendered `Turn` from a saved session. Retrieval citations stored by the old
    /// chat are ignored; the `[m:ss]` timestamps in the text stay tappable.
    init(_ persisted: PersistedChatTurn) {
        self.init(
            id: persisted.id,
            role: persisted.role,
            text: persisted.text,
            usage: persisted.usage,
            costUSD: persisted.costUSD,
            elapsedSeconds: persisted.elapsedSeconds,
            steps: persisted.steps ?? []
        )
        artifacts = persisted.artifacts ?? []
        artifactOrigins = persisted.artifactOrigins ?? [:]
    }
}
