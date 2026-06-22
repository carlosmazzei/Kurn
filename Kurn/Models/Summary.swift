//
//  Summary.swift
//  Kurn
//
//  AI-generated summary for a meeting: template-driven sections plus a
//  provenance footer (provider + model + timestamp).
//

import Foundation
import SwiftData

@Model
final class Summary {
    @Attribute(.unique) var id: UUID
    var meeting: Meeting?
    /// JSON-encoded `[SummarySection]` — the template-driven summary body.
    private var sectionsData: Data = Data()
    /// Display name of the template used to generate this summary, if any.
    var templateName: String?
    var providerRaw: String
    var modelRaw: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        meeting: Meeting? = nil,
        sections: [SummarySection] = [],
        templateName: String? = nil,
        provider: AIProvider,
        model: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.meeting = meeting
        self.sectionsData = (try? JSONEncoder().encode(sections)) ?? Data()
        self.templateName = templateName
        self.providerRaw = provider.rawValue
        self.modelRaw = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var sections: [SummarySection] {
        get { (try? JSONDecoder().decode([SummarySection].self, from: sectionsData)) ?? [] }
        set { sectionsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
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
