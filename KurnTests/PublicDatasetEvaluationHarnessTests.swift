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

    /// `KURN_PUBLIC_EVAL_MATRIX=essential` restricts the run to
    /// `PipelineEvaluationMatrix.essential` — the 8-entry cleanup×VAD×diarization
    /// sweep against whisper.cpp only — useful for a fast local check before
    /// dispatching the full 24-entry matrix in CI. Anything else, including
    /// unset, runs the full matrix. Both counts assume one whisper.cpp model.
    private var matrix: [PipelineEvaluationMatrix.Entry] {
        let base = ProcessInfo.processInfo.environment["KURN_PUBLIC_EVAL_MATRIX"] == "essential"
            ? PipelineEvaluationMatrix.essential
            : PipelineEvaluationMatrix.all
        return PipelineEvaluationMatrix.withCorrectionVariants(of: base)
    }

    private func printRunSummary(
        corpora: [(info: PublicEvaluationDataset.CorpusInfo, items: [PublicEvaluationDataset.Item])],
        entries: [PipelineEvaluationMatrix.Entry]
    ) {
        let mode = ProcessInfo.processInfo.environment["KURN_PUBLIC_EVAL_MATRIX"] == "essential" ? "essential" : "full"
        let cloudMode = ProcessInfo.processInfo.environment["KURN_PUBLIC_EVAL_CLOUD_PROVIDERS"] ?? "auto"
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
        print("[pipeline-eval]   cloud mode: \(cloudMode)")
        if cloudProviders.isEmpty {
            print("[pipeline-eval]   cloud ASR providers: none")
        } else {
            print("[pipeline-eval]   cloud ASR providers: \(cloudProviders.map(\.displayName).joined(separator: ", "))")
        }
        if let correctionProvider = PipelineEvaluationMatrix.correctionProviderFromEnvironment() {
            print("[pipeline-eval]   LLM correction: on (\(correctionProvider.displayName))")
        } else {
            print("[pipeline-eval]   LLM correction: off")
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
        var failures: [String] = []

        let writer = try PublicEvaluationDataset.reportPath.map {
            try CSVReportWriter(path: $0, resuming: Self.isResuming)
        }
        var rows: [Row] = writer?.resumedRows ?? []
        if let resumed = writer?.resumedRows, !resumed.isEmpty {
            print("[pipeline-eval] resuming: reusing \(resumed.count) row(s) already in the report")
        }

        for (info, items) in corpora {
            let corpusEntries = Self.entries(entries, for: items)
            if corpusEntries.count < entries.count {
                print(
                    "[pipeline-eval] \(info.corpus): scored on WER only, so the diarization axis is "
                    + "collapsed — \(entries.count) -> \(corpusEntries.count) configuration(s)"
                )
            }
            for item in items {
                for entry in corpusEntries {
                    guard TranscriptionLanguageSupport.isSupported(item.language, by: entry.configuration.transcription) else {
                        print("[pipeline-eval] SKIP \(item.corpusName)/\(item.name) [\(entry.label)]: \(entry.configuration.transcription) does not support \(item.language)")
                        continue
                    }
                    if writer?.alreadyHas(corpus: item.corpusName, name: item.name, configLabel: entry.label) == true {
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
                        // Appended and flushed here rather than accumulated for a
                        // single write at the end: a run that hits the job's time
                        // limit, or is cancelled, keeps everything it had already
                        // measured instead of yielding nothing.
                        writer?.append(csvRow(for: row))
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

        if let writer {
            print("[pipeline-eval] wrote \(rows.count) row(s) to \(writer.path)")
        }

        // The aggregate is printed before the assertion, not after it: a run with
        // one broken cell still measured everything else, and throwing first threw
        // that away along with the table that explains what happened.
        reportAggregate(rows)

        let failureSummary = "\(failures.count) pipeline run(s) failed:\n\(failures.joined(separator: "\n"))"
        try #require(failures.isEmpty, "\(failureSummary)")
    }

    /// `KURN_PUBLIC_EVAL_RESUME=1` keeps whatever rows the report already holds
    /// and runs only the missing cells.
    ///
    /// Opt-in rather than automatic, because a row carries no record of the code
    /// that produced it: reusing one is only sound while the pipeline is
    /// unchanged, which the harness cannot yet check. Turning that into a safe
    /// default is what per-stage versions in the CSV would buy.
    private static var isResuming: Bool {
        ProcessInfo.processInfo.environment["KURN_PUBLIC_EVAL_RESUME"] == "1"
    }

    /// Drops the diarization axis for a corpus that carries no reference RTTM.
    ///
    /// `TranscriptFusion.splitCoarseSpan` is word-preserving — it partitions a
    /// span's words into contiguous ranges and returns the span untouched unless
    /// the partition consumes every one — so the concatenated transcript is the
    /// same word sequence no matter who the turns are attributed to. The
    /// diarizer therefore **cannot** change WER, which the measurements confirm:
    /// every WER in a Portuguese run appears exactly twice, once per diarizer,
    /// without exception.
    ///
    /// So on a WER-only corpus that axis is not a comparison, it is the same
    /// number computed twice at double the cost. Spending that budget on more
    /// items instead is what makes the rate mean anything — a corpus of 16 short
    /// utterances came to ~143 reference tokens, where one wrong word moves the
    /// result by 0.7 points and two unrelated engines land on the same figure by
    /// coincidence.
    ///
    /// Only collapsed when the whole corpus is WER-only; a mixed one keeps the
    /// full matrix rather than deciding per item.
    private static func entries(
        _ entries: [PipelineEvaluationMatrix.Entry],
        for items: [PublicEvaluationDataset.Item]
    ) -> [PipelineEvaluationMatrix.Entry] {
        guard !items.isEmpty, items.allSatisfy({ $0.referenceRTTM == nil }) else { return entries }
        let collapsed = entries.filter { $0.configuration.diarization == diarizerForWEROnlyCorpora }
        return collapsed.isEmpty ? entries : collapsed
    }

    /// Which diarizer the collapsed axis keeps. The app's own default, so a
    /// WER-only run still exercises the configuration users actually get.
    private static let diarizerForWEROnlyCorpora: DiarizationEngine = .fluidAudio

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

    /// The table that answers "which combination is best for English" /
    /// "...for Portuguese", weighted by reference length rather than averaged
    /// per-file, same rationale as `EvaluationHarnessTests.reportsWordErrorRate`.
    ///
    /// Reported twice, at two grains, because one language can span materially
    /// different material: English is both LibriSpeech (one voice reading, clean)
    /// and AMI (four people around a table). Micro-averaging weights by reference
    /// length, so the meeting corpus dominates the language total and the
    /// read-speech signal — the one number comparable to the wider literature —
    /// disappears into it. The per-language line stays for continuity with runs
    /// recorded before AMI had a transcript; the per-corpus line is the one to
    /// read when deciding anything.
    private func reportAggregate(_ rows: [Row]) {
        print("[pipeline-eval] === aggregate WER/DER by language x configuration ===")
        reportGroups(rows, keyedBy: { "\($0.language)|\($0.configLabel)" }, named: { $0.language })
        print("[pipeline-eval] === aggregate WER/DER by corpus x configuration ===")
        reportGroups(
            rows,
            keyedBy: { "\($0.language)|\($0.corpus)|\($0.configLabel)" },
            named: { "\($0.language)/\($0.corpus)" }
        )
    }

    private func reportGroups(
        _ rows: [Row],
        keyedBy key: (Row) -> String,
        named name: (Row) -> String
    ) {
        let byGroup = Dictionary(grouping: rows, by: key)
        for key in byGroup.keys.sorted() {
            let group = byGroup[key] ?? []
            guard let first = group.first else { continue }
            let (label, configLabel) = (name(first), first.configLabel)

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
            print("[pipeline-eval] \(label) [\(configLabel)]: " + parts.joined(separator: ", "))
        }
    }

    // MARK: - CSV report

    /// Appends each scored row to the report as it is produced.
    ///
    /// The report used to be built in memory and written once, after the loop and
    /// after the failure assertion — so a run that hit the job's 6-hour ceiling,
    /// got cancelled, or tripped over a single broken cell produced **no** file at
    /// all, and hours of measurement went with it. Appending as we go means the
    /// file on disk is always everything measured so far.
    ///
    /// That also makes it a resume point: `resumedRows` reads back what a previous
    /// attempt left behind so the next one can run only the missing cells.
    private final class CSVReportWriter {
        static let header = "corpus,name,language,configuration,wer_pct,wer_sub,wer_ins,wer_del,wer_ref,"
            + "der_pct,der_missed,der_false_alarm,der_confusion,der_ref_speech"

        let path: String
        private let handle: FileHandle
        private var done: Set<String> = []
        private(set) var resumedRows: [Row] = []

        init(path: String, resuming: Bool) throws {
            self.path = path

            let existing = resuming ? (try? String(contentsOfFile: path, encoding: .utf8)) : nil
            if let existing, existing.hasPrefix(Self.header) {
                (resumedRows, done) = Self.parse(existing)
            } else {
                // No usable prior report — start a fresh one. A file whose header
                // does not match is from an older column layout; appending to it
                // would interleave two shapes into one unparseable CSV.
                try Self.header.appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
            }

            handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.seekToEnd()
        }

        func alreadyHas(corpus: String, name: String, configLabel: String) -> Bool {
            done.contains(Self.key(corpus, name, configLabel))
        }

        func append(_ fields: [String]) {
            guard let data = (fields.joined(separator: ",") + "\n").data(using: .utf8) else { return }
            // `FileHandle.write` goes straight to the descriptor, so the bytes
            // survive the process being killed — which is the whole point.
            try? handle.write(contentsOf: data)
        }

        private static func key(_ corpus: String, _ name: String, _ configLabel: String) -> String {
            "\(corpus)|\(name)|\(configLabel)"
        }

        /// Rebuilds rows from a previous report. Only the fields the aggregate
        /// needs are restored; a malformed line is dropped rather than guessed at.
        private static func parse(_ text: String) -> ([Row], Set<String>) {
            var rows: [Row] = []
            var done: Set<String> = []
            for line in text.split(separator: "\n").dropFirst() {
                let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard f.count == 14 else { continue }
                let wer = f[8].isEmpty ? nil : WordErrorRate.Result(
                    substitutions: Int(f[5]) ?? 0,
                    insertions: Int(f[6]) ?? 0,
                    deletions: Int(f[7]) ?? 0,
                    referenceCount: Int(f[8]) ?? 0
                )
                let der = f[13].isEmpty ? nil : DiarizationErrorRate.Result(
                    missed: Double(f[10]) ?? 0,
                    falseAlarm: Double(f[11]) ?? 0,
                    confusion: Double(f[12]) ?? 0,
                    referenceSpeech: Double(f[13]) ?? 0,
                    mapping: [:]
                )
                rows.append(Row(corpus: f[0], name: f[1], language: f[2], configLabel: f[3], wer: wer, der: der))
                done.insert(key(f[0], f[1], f[3]))
            }
            return (rows, done)
        }
    }

    /// Split out of the row writer — a single array literal mixing this many
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
