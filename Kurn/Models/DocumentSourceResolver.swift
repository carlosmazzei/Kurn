//
//  DocumentSourceResolver.swift
//  Kurn
//
//  Pure source-selection logic shared by the document composer and its tests.
//  Keeping folder traversal here prevents the SwiftUI view from owning domain
//  rules about which meetings a tag or folder selection represents.
//

import Foundation

struct ResolvedDocumentSources {
    let meetings: [Meeting]
    let sourceNames: [String]
}

@MainActor
enum DocumentSourceResolver {
    static func resolve(
        kind: DocumentSourceKind,
        selectedIDs: Set<UUID>,
        meetings: [Meeting],
        tags: [Tag],
        folders: [Folder]
    ) -> ResolvedDocumentSources {
        let transcribed = meetings.filter(\.hasAnyTranscript)
        switch kind {
        case .transcripts:
            let selected = transcribed.filter { selectedIDs.contains($0.id) }
            return ResolvedDocumentSources(
                meetings: selected,
                sourceNames: selected.map(\.title)
            )
        case .tags:
            return ResolvedDocumentSources(
                meetings: transcribed.filter { meeting in
                    meeting.tags.contains { selectedIDs.contains($0.id) }
                },
                sourceNames: tags.filter { selectedIDs.contains($0.id) }.map(\.name)
            )
        case .folders:
            let includedFolderIDs = descendantIDs(startingWith: selectedIDs, in: folders)
            return ResolvedDocumentSources(
                meetings: transcribed.filter { meeting in
                    meeting.folder.map { includedFolderIDs.contains($0.id) } ?? false
                },
                sourceNames: folders.filter { selectedIDs.contains($0.id) }.map(\.name)
            )
        }
    }

    static func transcriptCount(in folder: Folder, meetings: [Meeting], folders: [Folder]) -> Int {
        let includedFolderIDs = descendantIDs(startingWith: [folder.id], in: folders)
        return meetings.lazy.filter { meeting in
            meeting.hasAnyTranscript
                && (meeting.folder.map { includedFolderIDs.contains($0.id) } ?? false)
        }.count
    }

    static func descendantIDs(startingWith selectedIDs: Set<UUID>, in folders: [Folder]) -> Set<UUID> {
        var result = selectedIDs
        var pending = folders.filter { selectedIDs.contains($0.id) }
        while let folder = pending.popLast() {
            for child in folder.children where result.insert(child.id).inserted {
                pending.append(child)
            }
        }
        return result
    }
}
