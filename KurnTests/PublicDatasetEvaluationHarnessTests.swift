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

    private func printRunSummary(
        corpora: [(info: PublicEvaluationDataset.CorpusInfo, items: [PublicEvaluationDataset.Item])],
        entries: [PipelineEvaluationMatrix.Entry]
    ) {
        let mode = ProcessInfo.processInfo.environment["KURN_PUBLIC_EVAL_MATRIX"] == "essential" ? "essential" : "full"
        let cloudProviders = PipelineEvaluationMatrix.cloudProvidersFromEnvironment()
        let totalItems = corpora.reduce(0) { $0 + $1.items.count }

        let whisperModels = PipelineEvaluationMatrix.whisperCppModelsFromEnvironment().map(\.rawValue).joined(separator: ", ")
        print("[pipeline-eval] === run summary ===")
        print("[pipeline-eval] matrix: \(mode) (\(entries.count) configuration(s))")
        print("[pipeline-eval]   preprocessing: \(PreprocessingEngine.allCases.map(\.rawValue).joined(separator: ", "))")
        print("[pipeline-eval]   VAD: \(VADEngine.allCases.map(\.rawValue).joined(separator: ", "))")
        print("[pipeline-eval]   diarization: \(DiarizationEngine.allCases.map(\.rawValue).joined(separator: ", "))")
        print("[pipeline-eval]   on-device ASR: \(TranscriptionEngine.allCases.filter { $0 != .whisperAPI }.map(\.rawValue).joined(separator: ", "))")
        print("[pipeline-eval]   whisper.cpp models: \(whisperModels)")
        if cloudProviders.isEmpty {
            print("[pipeline-eval]   cloud ASR providers: none")
        } else {
            print("[pipeline-eval]   cloud ASR providers: \(cloudProviders.map(\.displayName).joined(separator: ", "))")
        }
        print("[pipeline-eval] corpora:")
        for (info, items) in corpora {
            let scoring = scoringDescription(for: items)
            let license = info.license.map { " [\($0)]" } ?? ""
            print("[pipeline-eval]   - \(info.corpus) (\(info.language), \(items.count) item(s), \(scoring))\(license)")
        }
        print("[pipeline-eval] total: \(entries.count) configuration(s) x \(totalItems) item(s) = ~\(entries.count * totalItems) run(s)")
    }

    private func scoringDescription(for items: [PublicEvaluationDataset.Item]) -> String {
        var parts: [String] = []
        if items.contains(where: { $0.reference != nil }) {
            parts.append("WER")
        }
        if items.contains(where: { $0.referenceRTTM != nil }) {
            parts.append("DER")
        }
        return parts.isEmpty ? "no reference" : parts.joined(separator: "+")
    }

    @Test func evaluatesPipelineMatrixAcrossPublicDatasets() async throws {
        let corpora = try PublicEvaluationDataset.corpora()
        try #require(
            !corpora.isEmpty,
            "No dataset.json + <name>.reference.txt/.reference.rttm found in \(PublicEvaluationDataset.directoryVariable)"
        )

        seedCloudProviderKeysFromEnvironment()
        let entries = matrix
        printRunSummary(corpora: corpora, entries: entries)
        try await prewarmModels(for: entries)

        let service = TranscriptionService()
        var rows: [Row] = []
        var failures: [String] = []

        for (info, items) in corpora {
            for item in items {
                for entry in entries {
                    guard TranscriptionLanguageSupport.isSupported(item.language, by: entry.configuration.transcription) else {
                        print("[pipeline-eval] SKIP \(item.corpusName)/\(item.name) [\(entry.label)]: \(entry.configuration.transcription) does not support \(item.language)")
                        continue
                    }
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
                    } catch let error as AppError {
                        if case .transcriptionLanguageUnsupported = error {
                            let reason = error.localizedDescription ?? String(describing: error)
                            print("[pipeline-eval] SKIP \(item.corpusName)/\(item.name) [\(entry.label)]: \(reason)")
                            continue
                        }
                        let description = "\(item.corpusName)/\(item.name) [\(entry.label)]: \(error)"
                        print("[pipeline-eval] FAILED \(description)")
                        failures.append(description)
                    } catch {
                        let description = "\(item.corpusName)/\(item.name) [\(entry.label)]: \(error)"
                        print("[pipeline-eval] FAILED \(description)")
                        failures.append(description)
                    }
                }
            }
        }

        let failureSummary = "\(failures.count) pipeline run(s) failed:\n\(failures.joined(separator: "\n"))"
        try #require(failures.isEmpty, "\(failureSummary)")
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
        let header = "corpus,name,language,configuration,wer_pct,wer_sub,wer_ins,wer_del,wer_ref,"
            + "der_pct,der_missed,der_false_alarm,der_confusion,der_ref_speech"
        var lines = [header]
        for row in rows {
            lines.append(csvRow(for: row).joined(separator: ","))
        }
        try (lines.joined(separator: "\n") + "\n").write(
            toFile: path, atomically: true, encoding: .utf8
        )
        print("[pipeline-eval] wrote \(rows.count) row(s) to \(path)")
    }

    /// Split out of `writeCSV` — a single array literal mixing this many
    /// `.map { ... } ?? ""` closures was too much for the type checker to
    /// solve in one pass ("unable to type-check this expression in reasonable
    /// time"). Building each field as its own statement keeps every
    /// sub-expression small enough to infer on its own.
    private func csvRow(for row: Row) -> [String] {
        var fields = [row.corpus, row.name, row.language, row.configLabel]

        let wer = row.wer
        fields.append(wer.map { String(format: "%.4f", $0.rate * 100) } ?? "")
        fields.append(wer.map { String($0.substitutions) } ?? "")
        fields.append(wer.map { String($0.insertions) } ?? "")
        fields.append(wer.map { String($0.deletions) } ?? "")
        fields.append(wer.map { String($0.referenceCount) } ?? "")

        let der = row.der
        fields.append(der.map { String(format: "%.4f", $0.rate * 100) } ?? "")
        fields.append(der.map { String(format: "%.3f", $0.missed) } ?? "")
        fields.append(der.map { String(format: "%.3f", $0.falseAlarm) } ?? "")
        fields.append(der.map { String(format: "%.3f", $0.confusion) } ?? "")
        fields.append(der.map { String(format: "%.3f", $0.referenceSpeech) } ?? "")

        return fields
    }
}
