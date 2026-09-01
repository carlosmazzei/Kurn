//
//  PipelineReportTests.swift
//  KurnCoreTests
//
//  Pins the properties a stored run report is read for: it survives a round
//  trip (it is persisted beside the transcript, so a report that cannot be
//  re-read is a report that does not exist), a skipped stage is not a warning
//  while a degraded one is, the aggregate takes the worst outcome, and a
//  fallback keeps both engines so "ran as requested" cannot be claimed for a
//  run that stepped down.
//
//  The encoded form is also asserted to contain only the closed vocabularies —
//  the whole reason this type has no free-text field (H5 PR 11).
//

import Foundation
import Testing
@testable import KurnCore

struct PipelineReportTests {

    @Test func reportSurvivesACodableRoundTrip() throws {
        var builder = PipelineReportBuilder()
        builder.record(.preprocessing, .degraded, requested: "standardDSP", effective: "none", reason: .originalAudioUsed)
        builder.record(.transcription, .succeeded, requested: "whisperCpp", effective: "whisperCpp")
        builder.record(.correction, .skipped, requested: "none", effective: "none", reason: .notRequested)
        let report = builder.report

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(PipelineReport.self, from: data)
        #expect(decoded == report)
        #expect(decoded.version == PipelineReport.currentVersion)
    }

    @Test func recordedStagesKeepExecutionOrder() {
        var builder = PipelineReportBuilder()
        builder.record(.preprocessing, .succeeded)
        builder.record(.transcription, .succeeded)
        builder.record(.diarization, .succeeded)
        #expect(builder.report.stages.map(\.stage) == [.preprocessing, .transcription, .diarization])
    }

    @Test func recordingAStageAgainReplacesItInPlace() {
        var builder = PipelineReportBuilder()
        builder.record(.diarization, .succeeded)
        builder.record(.transcription, .succeeded)
        builder.record(.diarization, .degraded, reason: .syntheticSingleTurn)

        let report = builder.report
        #expect(report.stages.map(\.stage) == [.diarization, .transcription])
        #expect(report[.diarization]?.outcome == .degraded)
        #expect(report[.diarization]?.reason == .syntheticSingleTurn)
    }

    @Test func skippedStagesAreNotWarnings() {
        var builder = PipelineReportBuilder()
        builder.record(.correction, .skipped, reason: .notRequested)
        builder.record(.languageDetection, .skipped, reason: .notRequested)
        let report = builder.report
        #expect(!report.hasWarnings)
        #expect(report.overall == .succeeded)
    }

    @Test func degradedStageIsAWarningAndAggregatesAsDegraded() {
        var builder = PipelineReportBuilder()
        builder.record(.transcription, .succeeded)
        builder.record(.diarization, .degraded, requested: "fluidAudio", effective: "heuristic", reason: .notConsented)
        let report = builder.report
        #expect(report.warnings.map(\.stage) == [.diarization])
        #expect(report.overall == .degraded)
    }

    @Test func failedStageOutranksDegradedInTheAggregate() {
        var builder = PipelineReportBuilder()
        builder.record(.diarization, .degraded, reason: .engineFailed)
        builder.record(.correction, .failed, reason: .engineFailed)
        #expect(builder.report.overall == .failed)
    }

    @Test func fallbackKeepsBothEnginesAndReadsAsFallback() {
        let stage = PipelineStageReport(
            stage: .diarization,
            outcome: .degraded,
            requestedEngine: "fluidAudio",
            effectiveEngine: "heuristic",
            reason: .notConsented
        )
        #expect(stage.fellBack)
        #expect(stage.isWarning)
    }

    @Test func sameEngineIsNotAFallback() {
        let stage = PipelineStageReport(
            stage: .transcription,
            outcome: .succeeded,
            requestedEngine: "whisperCpp",
            effectiveEngine: "whisperCpp"
        )
        #expect(!stage.fellBack)
        #expect(!stage.isWarning)
    }

    /// A stage with no engine axis (fusion) must not read as a fallback just
    /// because both engine fields are absent.
    @Test func missingEnginesAreNotAFallback() {
        let stage = PipelineStageReport(stage: .fusion, outcome: .succeeded)
        #expect(!stage.fellBack)
    }

    /// The encoded report may only ever contain the enum raw values and the
    /// engine identifiers it was given. This is the check that would fail if a
    /// free-text field (a provider message, a file name, a URL) were added.
    @Test func encodedReportContainsOnlyClosedVocabularyValues() throws {
        var builder = PipelineReportBuilder()
        builder.record(.preprocessing, .degraded, requested: "standardDSP", effective: "none", reason: .originalAudioUsed)
        builder.record(.correction, .failed, requested: "llm", effective: "llm", reason: .providerUnavailable)

        let data = try JSONEncoder().encode(builder.report)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stages = try #require(object["stages"] as? [[String: Any]])

        let allowedKeys: Set<String> = ["stage", "outcome", "requestedEngine", "effectiveEngine", "reason"]
        let allowedValues: Set<String> = Set(
            PipelineStage.allCases.map(\.rawValue)
                + ["succeeded", "degraded", "skipped", "failed"]
                + ["originalAudioUsed", "providerUnavailable"]
                + ["standardDSP", "none", "llm"]
        )
        #expect(object.keys.sorted() == ["stages", "version"])
        for stage in stages {
            #expect(Set(stage.keys).isSubset(of: allowedKeys))
            for value in stage.values {
                let string = try #require(value as? String)
                #expect(allowedValues.contains(string))
            }
        }
    }
}
