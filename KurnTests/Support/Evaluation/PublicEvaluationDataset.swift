//
//  PublicEvaluationDataset.swift
//  KurnTests
//
//  Finds public-corpus material for the pipeline matrix harness
//  (`PublicDatasetEvaluationHarnessTests`) to run the app's own pipeline
//  against — as opposed to `EvaluationDataset`, which reads a private corpus of
//  real meetings that can never be committed. Public benchmark audio (LibriSpeech,
//  AMI, Common Voice, CORAA — see `Tools/evaluation/public_datasets/`) carries no
//  such restriction, but it still is not committed to this repository: even
//  permissively-licensed corpora run to gigabytes, and re-fetching them on demand
//  keeps the repository small and the corpus swappable without a code change.
//
//  Layout — one subdirectory per corpus, each with a `dataset.json` describing
//  it and any number of `<name>.audio.<ext>` items. An item needs at least one
//  of `<name>.reference.txt` (scored for WER) or `<name>.reference.rttm`
//  (scored for DER) — not every public corpus offers both truths for the same
//  audio (e.g. AMI's lexical transcript lives in NXT XML this tooling doesn't
//  parse, so it contributes DER-only material):
//
//      $KURN_PUBLIC_EVAL_DATA/
//        librispeech-en/
//          dataset.json                 {"language": "english", "corpus": "..."}
//          1089-134686-0000.audio.flac
//          1089-134686-0000.reference.txt
//        ami-en/
//          dataset.json
//          ES2004a.audio.wav
//          ES2004a.reference.rttm       (no .reference.txt — DER only)
//

import Foundation
@testable import Kurn

enum PublicEvaluationDataset {

    static let directoryVariable = "KURN_PUBLIC_EVAL_DATA"

    /// Optional path to write a CSV report to, one row per (dataset item,
    /// configuration). Human-readable `[pipeline-eval]` lines are always
    /// printed regardless of whether this is set.
    static let reportVariable = "KURN_PUBLIC_EVAL_REPORT"

    static var directoryPath: String? {
        guard let raw = ProcessInfo.processInfo.environment[directoryVariable],
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return NSString(string: raw).expandingTildeInPath
    }

    static var reportPath: String? {
        guard let raw = ProcessInfo.processInfo.environment[reportVariable],
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return NSString(string: raw).expandingTildeInPath
    }

    /// Evaluated when the suite is registered, so the harness reports as
    /// skipped rather than passing over a corpus that was never fetched.
    static var isAvailable: Bool {
        guard let directoryPath else { return false }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    struct CorpusInfo: Decodable {
        var language: String
        var corpus: String
        var license: String?
    }

    struct Item {
        var corpusName: String
        var name: String
        var language: MeetingLanguage
        var audio: URL
        /// Reference transcript text, when this item has one. `nil` means
        /// "DER only" (e.g. AMI).
        var reference: String?
        /// Reference speaker turns, when this item has multi-speaker
        /// annotation. `nil` means "WER only" — not every public corpus has
        /// diarization ground truth.
        var referenceRTTM: String?
    }

    enum DatasetError: Error, CustomStringConvertible {
        case missingCorpusInfo(URL)
        case unknownLanguage(String, URL)

        var description: String {
            switch self {
            case .missingCorpusInfo(let url):
                return "\(url.path): missing or unreadable dataset.json"
            case .unknownLanguage(let raw, let url):
                return "\(url.path): dataset.json language \"\(raw)\" is not a known MeetingLanguage case"
            }
        }
    }

    /// Every corpus subdirectory with a `dataset.json`, each holding its items.
    /// A subdirectory without `dataset.json` is skipped rather than failing the
    /// whole run — an unfetched or partially-fetched corpus is the normal state
    /// while building this material up, same rationale as `EvaluationDataset`.
    static func corpora() throws -> [(info: CorpusInfo, items: [Item])] {
        guard let directoryPath else { return [] }
        let root = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        )

        var results: [(CorpusInfo, [Item])] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let infoURL = entry.appendingPathComponent("dataset.json")
            guard let data = try? Data(contentsOf: infoURL),
                  let info = try? JSONDecoder().decode(CorpusInfo.self, from: data) else { continue }
            let items = try items(in: entry, corpusName: entry.lastPathComponent, info: info)
            if !items.isEmpty {
                results.append((info, items))
            }
        }
        return results
    }

    private static let audioExtensions = ["wav", "flac", "m4a", "mp3", "caf"]

    private static func items(in directory: URL, corpusName: String, info: CorpusInfo) throws -> [Item] {
        guard let language = language(for: info.language) else {
            throw DatasetError.unknownLanguage(info.language, directory.appendingPathComponent("dataset.json"))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let audioSuffix = ".audio."

        return names
            .filter { fileName in
                guard let range = fileName.range(of: audioSuffix) else { return false }
                return audioExtensions.contains(String(fileName[range.upperBound...]))
            }
            .compactMap { fileName -> String? in
                guard let range = fileName.range(of: audioSuffix) else { return nil }
                return String(fileName[fileName.startIndex..<range.lowerBound])
            }
            .sorted()
            .compactMap { name -> Item? in
                let reference = try? String(
                    contentsOf: directory.appendingPathComponent("\(name).reference.txt"), encoding: .utf8
                )
                let referenceRTTM = try? String(
                    contentsOf: directory.appendingPathComponent("\(name).reference.rttm"), encoding: .utf8
                )
                // Neither ground truth present -> nothing to score this item against.
                guard reference != nil || referenceRTTM != nil else { return nil }

                let audio = audioExtensions
                    .map { directory.appendingPathComponent("\(name).audio.\($0)") }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
                guard let audio else { return nil }

                return Item(
                    corpusName: corpusName,
                    name: name,
                    language: language,
                    audio: audio,
                    reference: reference,
                    referenceRTTM: referenceRTTM
                )
            }
    }

    /// Maps a `dataset.json` language string (matched case-insensitively
    /// against `MeetingLanguage`'s raw values, e.g. `"english"`, `"portuguese"`)
    /// to the enum the pipeline expects.
    private static func language(for raw: String) -> MeetingLanguage? {
        MeetingLanguage(rawValue: raw.lowercased())
    }
}
