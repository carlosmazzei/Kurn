//
//  Summary.swift
//  Kurn
//
//  AI-generated summary for a meeting: template-driven sections plus a
//  provenance footer (provider + model + timestamp).
//

import Foundation
import KurnCore
import SwiftData

@Model
final class Summary {
    @Attribute(.unique) var id: UUID
    /// Inverse of `Meeting.summaries`. Every summary created after the
    /// multi-summary feature shipped is linked through this property.
    var owningMeeting: Meeting?
    /// JSON-encoded `[SummarySection]` — the template-driven summary body.
    /// Not `private`: `TranscriptionViewModel.generateSummary` writes it
    /// directly with an already-encoded, pre-checked payload rather than
    /// encoding `sections` a second time through the setter below. Matches
    /// `Transcript.segmentsData`'s access level for the same reason.
    var sectionsData: Data = Data()
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
        self.owningMeeting = meeting
        // `?? Data()` only ever applies to the `= []` default here; a real
        // payload that fails to encode goes through
        // `TranscriptionViewModel.generateSummary`'s explicit pre-check
        // instead, which fails the save. See `JSONStorage.encodeAuthoritative`.
        self.sectionsData = JSONStorage.encodeAuthoritative(sections) ?? Data()
        self.templateName = templateName
        self.providerRaw = provider.rawValue
        self.modelRaw = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var sections: [SummarySection] {
        // Normalize on read so both already-stored and new summaries are cleaned
        // in one place: some models double-escape newlines in the JSON they
        // return, which would otherwise render as a literal "\n". Every consumer
        // (views, export) reads through this getter, so the fix reaches all of
        // them without a migration.
        get { (JSONStorage.decodeAuthoritative([SummarySection].self, from: sectionsData).decodedValue ?? []).map { $0.normalizedWhitespace() } }
        // A failed encode leaves the previously-stored bytes untouched
        // rather than blanking them — see `Transcript.segments`'s setter.
        set { sectionsData = JSONStorage.encodeAuthoritative(newValue) ?? sectionsData }
    }

    /// Whether the stored sections failed to decode or verify — see
    /// `Transcript.isSegmentsDataCorrupted`.
    var isSectionsDataCorrupted: Bool {
        JSONStorage.decodeAuthoritative([SummarySection].self, from: sectionsData).isCorrupted
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
