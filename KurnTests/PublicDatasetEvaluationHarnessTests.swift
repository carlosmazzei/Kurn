//
//  PublicDatasetEvaluationHarnessTests.swift
//  KurnTests
//
//  Runs the app's actual pipeline — `TranscriptionService`, exactly as
//  `TranscriptionViewModel` drives it, not a stand-in — over public benchmark
//  audio, once per configuration in `PipelineEvaluationMatrix`. This is what
//  answers "does audio cleanup help", "which diarizer is better", "which ASR
//  engine wins" with a measured number instead of an inference from the
//  literature, the same complaint `EvaluationHarnessTests` exists to fix for
//  private recordings — but that harness is gated on a corpus that can never be
//  committed, so it never runs unattended. Public benchmark material carries no
//  such restriction, so this suite is meant to run in CI, on demand
//  (`.github/workflows/pipeline-eval.yml`), after any change to a pipeline
//  stage.
//
//  Skipped whenever `KURN_PUBLIC_EVAL_DATA` is unset, same rationale as
//  `EvaluationDataset`: with no corpus fetched there is nothing to measure, and
//  a green run only proves this file compiles.
//
//  Deliberately no pass/fail threshold, for the same reason `EvaluationHarnessTests`
//  has none: a budget invented here would have no provenance. What is asserted
//  is that every (item, configuration) pair actually produced a transcript —
//  a thrown error is a broken run, not a data point, and must not be silently
//  skipped out of the matrix.
//

import Foundation
import Testing
@testable import Kurn

@Suite(.serialized, .enabled(if: PublicEvaluationDataset.isAvailable))
struct PublicDatasetEvaluationHarnessTests {

    private struct Row {
        var corpus: String
        var name: String
        var language: String
        var configLabel: String
        /// `nil` for an item with no `.reference.txt` (e.g. AMI, which is
        /// DER-only — see `PublicEvaluationDataset`).
        var wer: WordErrorRate.Result?
        var der: DiarizationErrorRate.Result?
    }

    /// `KURN_PUBLIC_EVAL_MATRIX=essential` restricts the run to the 4-entry
    /// cleanup×diarization sweep (VAD and ASR engine held at their zero-download
    /// defaults) — useful for a fast local check before dispatching the full
    /// 24-entry matrix in CI. Anything else, including unset, runs the full matrix.
    private var matrix: [PipelineEvaluationMatrix.Entry] {
        ProcessInfo.processInfo.environment["KURN_PUBLIC_EVAL_MATRIX"] == "essential"
            ? PipelineEvaluationMatrix.essential
            : PipelineEvaluationMatrix.all
    }

    @Test func evaluatesPipelineMatrixAcrossPublicDatasets() async throws {
        let corpora = try PublicEvaluationDataset.corpora()
        try #require(
            !corpora.isEmpty,
            "No dataset.json + <name>.reference.txt/.reference.rttm found in \(PublicEvaluationDataset.directoryVariable)"
        )

        seedCloudProviderKeysFromEnvironment()
        let entries = matrix
        print("[pipeline-eval] \(entries.count) configuration(s) x \(corpora.reduce(0) { $0 + $1.items.count }) item(s)")
        try await prewarmModels(for: entries)

        let service = TranscriptionService()
        var rows: [Row] = []
        var failures: [String] = []

        for (info, items) in corpora {
            for item in items {
                for entry in entries {
                    do {
                        let output = try await service.transcribe(
                            fileURL: item.audio,
                            fileName: item.name,
                            language: item.language,
                            config: entry.configuration
                        )
                        let row = score(item: item, corpusLanguage: info.language, entry: entry, output: output)
                        report(row)
                        rows.append(row)
                    } catch {
                        let description = "\(item.corpusName)/\(item.name) [\(entry.label)]: \(error)"
                        print("[pipeline-eval] FAILED \(description)")
                        failures.append(description)
                    }
                }
            }
        }

        try #require(failures.isEmpty, "\(failures.count) pipeline run(s) failed:\n" + failures.joined(separator: "\n"))
        reportAggregate(rows)
        if let reportPath = PublicEvaluationDataset.reportPath {
            try writeCSV(rows, to: reportPath)
        }
    }

    /// Writes `OPENAI_API_KEY`/`GROQ_API_KEY` (when set) into the Keychain
    /// under the same account `ProviderFactory.whisperProvider` reads, exactly
    /// as if the user had pasted the key into Settings. This is what lets the
    /// `.whisperAPI` entries `PipelineEvaluationMatrix` adds for those
    /// providers actually authenticate — no special-casing in
    /// `TranscriptionService` or `ProviderFactory` for "running under the eval
    /// harness".
    private func seedCloudProviderKeysFromEnvironment() {
        let environment = ProcessInfo.processInfo.environment
        for (provider, variable) in [(AIProvider.openAI, "OPENAI_API_KEY"), (AIProvider.groq, "GROQ_API_KEY")] {
            guard let key = environment[variable], !key.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            KeychainManager.shared.set(key, for: provider.keychainAccount)
            print("[pipeline-eval] seeded \(provider.displayName) API key from \(variable)")
        }
    }

    // MARK: - Model prewarming

    /// Downloads every model any configuration in `entries` needs, once, up
    /// front. `ModelDownloadConsent.download` is itself idempotent (FluidAudio
    /// and the whisper.cpp downloader both skip work for an already-cached
    /// model), so this only costs time on the first run of a fresh cache.
    private func prewarmModels(for entries: [PipelineEvaluationMatrix.Entry]) async throws {
        var seen = Set<String>()
        for entry in entries {
            let config = entry.configuration
            for set in [
                config.vad.requiredModelSet,
                config.effectiveDiarization.requiredModelSet,
                config.transcription.requiredModelSet(whisperCppModel: config.whisperCppModel)
            ].compactMap({ $0 }) {
                let key = "\(set)"
                guard seen.insert(key).inserted else { continue }
                print("[pipeline-eval] downloading model set \(key)")
                try await ModelDownloadConsent.download(set)
            }
        }
    }

    // MARK: - Scoring

    private func score(
        item: PublicEvaluationDataset.Item,
        corpusLanguage: String,
        entry: PipelineEvaluationMatrix.Entry,
        output: TranscriptionService.Output
    ) -> Row {
        var wer: WordErrorRate.Result?
        if let reference = item.reference {
            let hypothesisText = output.segments.map(\.text).joined(separator: " ")
            wer = WordErrorRate.compare(reference: reference, hypothesis: hypothesisText)
        }

        var der: DiarizationErrorRate.Result?
        if let referenceRTTM = item.referenceRTTM {
            let reference = RTTM.parse(referenceRTTM)
            let hypothesis = output.segments.map {
                DiarizationErrorRate.Segment(label: $0.speakerLabel, start: $0.startTime, end: $0.endTime)
            }
            der = DiarizationErrorRate.compare(reference: reference, hypothesis: hypothesis)
        }

        return Row(
            corpus: item.corpusName,
            name: item.name,
            language: corpusLanguage,
            configLabel: entry.label,
            wer: wer,
            der: der
        )
    }

    private func report(_ row: Row) {
        if let wer = row.wer {
            print("[pipeline-eval] \(row.corpus)/\(row.name) [\(row.configLabel)]: \(wer.summary)")
        }
        if let der = row.der {
            print("[pipeline-eval] \(row.corpus)/\(row.name) [\(row.configLabel)]: \(der.summary)")
        }
    }

    /// Corpus-level rate per (language, configuration) — the table that answers
    /// "which combination is best for English" / "...for Portuguese", weighted
    /// by reference length rather than averaged per-file, same rationale as
    /// `EvaluationHarnessTests.reportsWordErrorRate`.
    private func reportAggregate(_ rows: [Row]) {
        let byGroup = Dictionary(grouping: rows) { "\($0.language)|\($0.configLabel)" }
        print("[pipeline-eval] === aggregate WER/DER by language x configuration ===")
        for key in byGroup.keys.sorted() {
            let group = byGroup[key] ?? []
            guard let language = group.first?.language, let configLabel = group.first?.configLabel else { continue }

            var parts: [String] = []
            let werGroup = group.compactMap(\.wer)
            if !werGroup.isEmpty {
                let werErrors = werGroup.reduce(0) { $0 + $1.errors }
                let werReference = werGroup.reduce(0) { $0 + $1.referenceCount }
                let werRate = werReference > 0 ? Double(werErrors) / Double(werReference) : 0
                parts.append(String(format: "WER %.2f%% over %d file(s)", werRate * 100, werGroup.count))
            }

            let derGroup = group.compactMap(\.der)
            if !derGroup.isEmpty {
                let derErrors: TimeInterval = derGroup.reduce(0.0) { $0 + $1.errors }
                let derSpeech: TimeInterval = derGroup.reduce(0.0) { $0 + $1.referenceSpeech }
                let derRate = derSpeech > 0 ? derErrors / derSpeech : 0
                parts.append(String(format: "DER %.2f%% over %d file(s)", derRate * 100, derGroup.count))
            }

            guard !parts.isEmpty else { continue }
            print("[pipeline-eval] \(language) [\(configLabel)]: " + parts.joined(separator: ", "))
        }
    }

    // MARK: - CSV report

    private func writeCSV(_ rows: [Row], to path: String) throws {
        var lines = ["corpus,name,language,configuration,wer_pct,wer_sub,wer_ins,wer_del,wer_ref,der_pct,der_missed,der_false_alarm,der_confusion,der_ref_speech"]
        for row in rows {
            let wer = row.wer
            let der = row.der
            lines.append([
                row.corpus,
                row.name,
                row.language,
                row.configLabel,
                wer.map { String(format: "%.4f", $0.rate * 100) } ?? "",
                wer.map { "\($0.substitutions)" } ?? "",
                wer.map { "\($0.insertions)" } ?? "",
                wer.map { "\($0.deletions)" } ?? "",
                wer.map { "\($0.referenceCount)" } ?? "",
                der.map { String(format: "%.4f", $0.rate * 100) } ?? "",
                der.map { String(format: "%.3f", $0.missed) } ?? "",
                der.map { String(format: "%.3f", $0.falseAlarm) } ?? "",
                der.map { String(format: "%.3f", $0.confusion) } ?? "",
                der.map { String(format: "%.3f", $0.referenceSpeech) } ?? ""
            ].joined(separator: ","))
        }
        try (lines.joined(separator: "\n") + "\n").write(
            toFile: path, atomically: true, encoding: .utf8
        )
        print("[pipeline-eval] wrote \(rows.count) row(s) to \(path)")
    }
}
