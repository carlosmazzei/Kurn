//
//  ProgressVocabularyTests.swift
//  KurnTests
//
//  The progress vocabulary the pipelines report to the UI, and the document
//  source kinds: every case has a label, the transcription bar only ever
//  moves forward within its fixed bands, and a percentage is clamped before
//  it reaches the screen.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

struct ProgressVocabularyTests {

    private static let transcriptionPhases: [TranscriptionPhase] = [
        .preparing, .preprocessing, .detectingLanguage, .detectingSpeech,
        .transcribing(progress: nil), .transcribing(progress: 0.5),
        .transcribing(progress: 0.5, chunks: ChunkProgress(completed: 2, total: 3)),
        .diarizing(progress: nil), .diarizing(progress: 0.25),
        .finalizing, .correcting(progress: nil), .correcting(progress: 0.75)
    ]

    @Test func everyTranscriptionPhaseHasALabel() {
        let labels = Self.transcriptionPhases.map(\.displayName)
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(Set(labels).count == labels.count)
    }

    @Test func determinatePhasesShowTheirPercentage() {
        #expect(TranscriptionPhase.transcribing(progress: 0.5).displayName.contains("50"))
        let chunked = TranscriptionPhase.transcribing(progress: 0.4, chunks: ChunkProgress(completed: 2, total: 3)).displayName
        #expect(chunked.contains("40") && chunked.contains("2") && chunked.contains("3"))
        #expect(TranscriptionPhase.diarizing(progress: 7).displayName.contains("100"))
        #expect(TranscriptionPhase.correcting(progress: -1).displayName.contains("0"))
    }

    @Test func theBarOnlyMovesForwardThroughTheStages() {
        let ordered: [TranscriptionPhase] = [
            .preparing, .preprocessing, .detectingLanguage, .detectingSpeech,
            .transcribing(progress: 0), .transcribing(progress: 1),
            .diarizing(progress: 0), .diarizing(progress: 1),
            .finalizing, .correcting(progress: 1)
        ]
        let fractions = ordered.map(\.fractionComplete)
        #expect(fractions == fractions.sorted())
        #expect(fractions.allSatisfy { (0...1).contains($0) })
    }

    @Test func subProgressIsClampedToItsBand() {
        #expect(TranscriptionPhase.transcribing(progress: 9).fractionComplete == TranscriptionPhase.transcribing(progress: 1).fractionComplete)
        #expect(TranscriptionPhase.transcribing(progress: nil).fractionComplete == TranscriptionPhase.transcribing(progress: 0).fractionComplete)
        #expect(TranscriptionPhase.diarizing(progress: -2).fractionComplete == TranscriptionPhase.diarizing(progress: 0).fractionComplete)
        #expect(TranscriptionPhase.correcting(progress: 5).fractionComplete == 1)
    }

    @Test func everyChatAndPostTranscriptionPhaseHasALabelAndIcon() {
        let chat: [ChatPhase] = [.rewritingQuery, .retrieving, .reranking, .synthesizing, .answering]
        #expect(chat.allSatisfy { !$0.displayName.isEmpty && !$0.systemImage.isEmpty })
        #expect(Set(chat.map(\.systemImage)).count == chat.count)

        let post: [PostTranscriptionPhase] = [.generatingTitle, .indexing, .generatingWiki]
        #expect(Set(post.map(\.displayName)).count == post.count)
    }

    @Test func everyDocumentSourceKindHasALabelAndIcon() {
        let kinds = DocumentSourceKind.allCases
        #expect(kinds.allSatisfy { !$0.displayName.isEmpty && !$0.systemImage.isEmpty && $0.id == $0.rawValue })
        #expect(Set(kinds.map(\.systemImage)).count == kinds.count)
    }

    @MainActor
    @Test func aGeneratedDocumentsSnapshotsCanBeRewritten() {
        let document = GeneratedDocument(
            title: "Brief",
            bodyMarkdown: "# Brief",
            userPrompt: "Write a brief",
            sourceKind: .tags,
            sourceNames: ["Launch"],
            sourceMeetingIDs: [],
            generatorModelIdentifier: "openai:gpt-4o"
        )
        let meetingID = UUID()

        document.sourceKind = .folders
        document.sourceNames = ["Q3", "Q4"]
        document.sourceMeetingIDs = [meetingID]

        #expect(document.sourceKind == .folders)
        #expect(document.sourceNames == ["Q3", "Q4"])
        #expect(document.sourceMeetingIDs == [meetingID])

        document.sourceKindRaw = "unknown"
        #expect(document.sourceKind == .transcripts)
    }
}
