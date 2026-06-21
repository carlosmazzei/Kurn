//
//  Summary.swift
//  MeetSync
//
//  AI-generated summary for a meeting: markdown body plus extracted action items
//  and key decisions.
//

import Foundation
import SwiftData

@Model
final class Summary {
    @Attribute(.unique) var id: UUID
    var meeting: Meeting?
    var content: String
    /// JSON-encoded `[String]`.
    private var actionItemsData: Data
    /// JSON-encoded `[String]`.
    private var keyDecisionsData: Data
    var providerRaw: String
    var modelRaw: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        meeting: Meeting? = nil,
        content: String,
        actionItems: [String] = [],
        keyDecisions: [String] = [],
        provider: AIProvider,
        model: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.meeting = meeting
        self.content = content
        self.actionItemsData = (try? JSONEncoder().encode(actionItems)) ?? Data()
        self.keyDecisionsData = (try? JSONEncoder().encode(keyDecisions)) ?? Data()
        self.providerRaw = provider.rawValue
        self.modelRaw = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var actionItems: [String] {
        get { (try? JSONDecoder().decode([String].self, from: actionItemsData)) ?? [] }
        set { actionItemsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var keyDecisions: [String] {
        get { (try? JSONDecoder().decode([String].self, from: keyDecisionsData)) ?? [] }
        set { keyDecisionsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var provider: AIProvider {
        get { AIProvider(rawValue: providerRaw) ?? .openAI }
        set { providerRaw = newValue.rawValue }
    }

    var model: String? {
        get {
            guard let modelRaw, !modelRaw.isEmpty else { return nil }
            return modelRaw
        }
        set { modelRaw = newValue }
    }
}
