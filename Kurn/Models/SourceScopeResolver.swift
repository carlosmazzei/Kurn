import Foundation
import KurnCore

@MainActor
enum SourceScopeResolver {
    static func resolve(_ scope: ChatSourceScope, meetings: [Meeting], tags: [Tag],
                        folders: [Folder]) -> ResolvedDocumentSources {
        let transcribed = meetings.filter(\.hasAnyTranscript)
        switch scope.kind {
        case .library:
            return ResolvedDocumentSources(meetings: transcribed, sourceNames: transcribed.map(\.title))
        case .meetings:
            let selected = transcribed.filter { scope.selectedIDs.contains($0.id) }
            return ResolvedDocumentSources(meetings: selected, sourceNames: selected.map(\.title))
        case .tags:
            return ResolvedDocumentSources(meetings: transcribed.filter { meeting in
                meeting.tags.contains { scope.selectedIDs.contains($0.id) }
            }, sourceNames: tags.filter { scope.selectedIDs.contains($0.id) }.map(\.name))
        case .folders:
            let included = DocumentSourceResolver.descendantIDs(startingWith: scope.selectedIDs, in: folders)
            return ResolvedDocumentSources(meetings: transcribed.filter { meeting in
                meeting.folder.map { included.contains($0.id) } ?? false
            }, sourceNames: folders.filter { scope.selectedIDs.contains($0.id) }.map(\.name))
        }
    }
}
