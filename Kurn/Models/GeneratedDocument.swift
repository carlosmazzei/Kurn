//
//  GeneratedDocument.swift
//  Kurn
//
//  A user-requested document synthesized from one or more meeting transcripts.
//  Source labels and meeting ids are snapshots: deleting or reorganizing a
//  meeting must not destroy a document that was already generated.
//

import Foundation
import SwiftData

enum DocumentSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case transcripts
    case tags
    case folders

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .transcripts:
            return NSLocalizedString("documents.source.transcripts", comment: "Transcripts")
        case .tags:
            return NSLocalizedString("documents.source.tags", comment: "Tags")
        case .folders:
            return NSLocalizedString("documents.source.folders", comment: "Folders")
        }
    }

    var systemImage: String {
        switch self {
        case .transcripts: return "text.quote"
        case .tags: return "tag"
        case .folders: return "folder"
        }
    }
}

@Model
final class GeneratedDocument {
    @Attribute(.unique) var id: UUID
    var title: String
    var bodyMarkdown: String
    var userPrompt: String
    var sourceKindRaw: String
    var sourceNamesData: Data
    var sourceMeetingIDsData: Data
    var generatorModelIdentifier: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        bodyMarkdown: String,
        userPrompt: String,
        sourceKind: DocumentSourceKind,
        sourceNames: [String],
        sourceMeetingIDs: [UUID],
        generatorModelIdentifier: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.userPrompt = userPrompt
        self.sourceKindRaw = sourceKind.rawValue
        self.sourceNamesData = JSONStorage.encode(sourceNames)
        self.sourceMeetingIDsData = JSONStorage.encode(sourceMeetingIDs)
        self.generatorModelIdentifier = generatorModelIdentifier
        self.createdAt = createdAt
    }

    var sourceKind: DocumentSourceKind {
        get { DocumentSourceKind(rawValue: sourceKindRaw) ?? .transcripts }
        set { sourceKindRaw = newValue.rawValue }
    }

    var sourceNames: [String] {
        get { JSONStorage.decode([String].self, from: sourceNamesData) }
        set { sourceNamesData = JSONStorage.encode(newValue) }
    }

    var sourceMeetingIDs: [UUID] {
        get { JSONStorage.decode([UUID].self, from: sourceMeetingIDsData) }
        set { sourceMeetingIDsData = JSONStorage.encode(newValue) }
    }
}
