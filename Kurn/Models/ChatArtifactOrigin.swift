import Foundation
import KurnCore
import SwiftData

struct ChatArtifactOrigin: Codable, Sendable, Equatable {
    var question: String
    var modelIdentifier: String
    var sources: ChatArtifactSources? = nil
}

struct ChatArtifactSources: Codable, Sendable, Equatable {
    var kind: DocumentSourceKind
    var meetingIDs: [UUID]
    var names: [String]
    var meetingNames: [UUID: String]? = nil

    @MainActor
    static func capture(scope: ChatSourceScope, context: ModelContext) throws -> Self {
        let resolved = SourceScopeResolver.resolve(scope, meetings: try context.fetch(FetchDescriptor<Meeting>()),
            tags: try context.fetch(FetchDescriptor<Tag>()), folders: try context.fetch(FetchDescriptor<Folder>()))
        let kind: DocumentSourceKind = scope.kind == .tags ? .tags : scope.kind == .folders ? .folders : .transcripts
        return Self(kind: kind, meetingIDs: resolved.meetings.map(\.id), names: resolved.sourceNames,
                    meetingNames: Dictionary(uniqueKeysWithValues: resolved.meetings.map { ($0.id, $0.title) }))
    }

    func retaining(_ previous: Self?) -> Self {
        guard let previous else { return self }
        let ids = previous.meetingIDs + meetingIDs.filter { !previous.meetingIDs.contains($0) }
        var titles = previous.meetingNames ?? previous.transcriptNames
        titles.merge(meetingNames ?? transcriptNames) { _, latest in latest }
        if kind != previous.kind || kind == .transcripts {
            return Self(kind: .transcripts, meetingIDs: ids, names: ids.map { titles[$0] ?? $0.uuidString }, meetingNames: titles)
        }
        return Self(kind: kind, meetingIDs: ids, names: previous.names + names.filter { !previous.names.contains($0) }, meetingNames: titles)
    }

    private var transcriptNames: [UUID: String] {
        guard kind == .transcripts else { return [:] }
        return Dictionary(zip(meetingIDs, names), uniquingKeysWith: { _, last in last })
    }
}
