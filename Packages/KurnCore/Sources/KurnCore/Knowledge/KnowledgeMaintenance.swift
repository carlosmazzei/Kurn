import Foundation

/// Versioned, content-free maintenance output. Counts describe inspected
/// segments/records, never semantic recall or calibrated extraction quality.
public struct KnowledgeMaintenanceReport: Codable, Equatable, Sendable {
    public let version: Int
    public let revision: Int
    public let isComplete: Bool
    public let coverage: [KnowledgeMaintenanceCoverage]
    public let findings: [KnowledgeMaintenanceFinding]
    public var isClean: Bool { isComplete && findings.isEmpty }

    public static func decode(_ data: Data) throws -> Self {
        let report = try JSONDecoder().decode(Self.self, from: data)
        guard report.version == 1 else { throw KnowledgeMaintenanceError.unsupportedReport }
        guard report.revision >= 0, report.findings.count <= KnowledgeMaintenanceLinter.findingLimit,
              Set(report.findings.map(\.id)).count == report.findings.count,
              report.findings.allSatisfy({ $0 == KnowledgeMaintenanceFinding(code: $0.code, subjects: $0.subjects) }),
              Set(report.coverage.map(\.recordingID)).count == report.coverage.count,
              report.coverage.allSatisfy({ $0.totalSegments >= 0 && (0...$0.totalSegments).contains($0.examinedSegments) }) else {
            throw KnowledgeMaintenanceError.invalidInput
        }
        return report
    }

    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum KnowledgeMaintenanceError: String, Error, Sendable {
    case unsupportedReport = "maintenance_unsupported_report"
    case unsupportedArtifact = "maintenance_unsupported_artifact"
    case invalidInput = "maintenance_invalid_input"
    case limitExceeded = "maintenance_limit_exceeded"
}

public struct KnowledgeMaintenanceFinding: Equatable, Sendable, Identifiable {
    public let code: Code
    /// Only IDs already authorized by the host. Unknown link targets are never
    /// included; a broken-link finding identifies its readable source page.
    public let subjects: [Reference]
    public var id: String { code.rawValue + ":" + subjects.map { $0.kind.rawValue + ":" + $0.id.uuidString.lowercased() }.joined(separator: ",") }
    public var recommendation: Recommendation {
        switch code {
        case .projectionMissing, .staleProjection, .invalidProjection, .invalidNarrative, .brokenEntityLink, .brokenEvidenceLink: .rebuildProjection
        case .duplicateCandidate: .reviewIdentity
        case .orphanEntity, .artifactUnreadable, .canonicalUnavailable: .inspectCanonical
        case .coverageGap, .compilationMissing, .sourceChanged, .policyChanged, .transcriptMissing: .compileSource
        }
    }

    public enum Code: String, Codable, CaseIterable, Sendable {
        case brokenEntityLink, brokenEvidenceLink, orphanEntity, projectionMissing, staleProjection
        case invalidProjection, invalidNarrative, duplicateCandidate, coverageGap, compilationMissing
        case sourceChanged, policyChanged, transcriptMissing, artifactUnreadable, canonicalUnavailable
    }
    public enum Recommendation: String, Codable, Sendable { case rebuildProjection, reviewIdentity, inspectCanonical, compileSource }
    public struct Reference: Codable, Hashable, Sendable {
        public let kind: Kind
        public let id: UUID
        public init(_ kind: Kind, _ id: UUID) { self.kind = kind; self.id = id }
    }
    public enum Kind: String, Codable, Sendable { case entity, assertion, recording, meeting, projection }

    public init(code: Code, subjects: [Reference]) {
        self.code = code
        self.subjects = Array(Set(subjects)).sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

public struct KnowledgeMaintenanceCoverage: Codable, Equatable, Sendable {
    public let recordingID: UUID
    public let totalSegments: Int
    public let examinedSegments: Int
    public let state: State
    public enum State: String, Codable, CaseIterable, Sendable {
        case current, missingCompilation, sourceChanged, policyChanged, transcriptMissing, unreadable
    }
    public init(recordingID: UUID, totalSegments: Int, examinedSegments: Int, state: State) {
        self.recordingID = recordingID
        self.totalSegments = totalSegments
        self.examinedSegments = examinedSegments
        self.state = state
    }
}

/// A metadata-only graph supplied AFTER host authorization. Raw names, quotes,
/// Markdown and diagnostic error text never enter a maintenance report.
public struct KnowledgeMaintenanceInput: Sendable {
    public var revision: Int
    public var isComplete = true
    public var entities: [Entity] = []
    public var evidenceIDs: Set<UUID> = []
    public var assertionIDs: Set<UUID> = []
    public var pages: [Page] = []
    public var projection: ProjectionState = .missing
    public var candidates: [Candidate] = []
    public var coverage: [KnowledgeMaintenanceCoverage] = []
    public var findings: [KnowledgeMaintenanceFinding] = []
    public init(revision: Int) { self.revision = revision }

    public struct Entity: Sendable {
        public let id: UUID
        public let isOrphan: Bool
        public init(id: UUID, isOrphan: Bool) { self.id = id; self.isOrphan = isOrphan }
    }
    public struct Page: Sendable {
        public let entityID: UUID
        public let revision: Int
        public var entityLinks: Set<UUID> = []
        public var evidenceLinks: Set<UUID> = []
        public var assertionIDs: Set<UUID> = []
        public var narrativeAssertionIDs: Set<UUID> = []
        public var matchesCanonical = true
        public init(entityID: UUID, revision: Int) { self.entityID = entityID; self.revision = revision }
    }
    public struct Candidate: Sendable {
        public let leftID: UUID
        public let rightID: UUID
        public init(_ leftID: UUID, _ rightID: UUID) { self.leftID = leftID; self.rightID = rightID }
    }
    public enum ProjectionState: Equatable, Sendable { case current, missing, stale, unreadable }
}
