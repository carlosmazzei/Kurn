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

    @MainActor
    static func capture(scope: ChatSourceScope, context: ModelContext) throws -> Self {
        let resolved = SourceScopeResolver.resolve(scope, meetings: try context.fetch(FetchDescriptor<Meeting>()),
            tags: try context.fetch(FetchDescriptor<Tag>()), folders: try context.fetch(FetchDescriptor<Folder>()))
        let kind: DocumentSourceKind = scope.kind == .tags ? .tags : scope.kind == .folders ? .folders : .transcripts
        return Self(kind: kind, meetingIDs: resolved.meetings.map(\.id), names: resolved.sourceNames)
    }

    func retaining(_ previous: Self?) -> Self {
        guard let previous else { return self }
        return Self(kind: kind, meetingIDs: previous.meetingIDs + meetingIDs.filter { !previous.meetingIDs.contains($0) },
                    names: previous.names + names.filter { !previous.names.contains($0) })
    }
}
