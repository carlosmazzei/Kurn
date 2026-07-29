//
//  EvaluationDataset.swift
//  KurnTests
//
//  Finds annotated material to score against, and reports nothing to score when
//  there is none.
//
//  The data cannot live in this repository. Meeting recordings are the most
//  private thing this app touches — the reason every byte of them is encrypted
//  at rest — so a corpus of real ones, with transcripts, is exactly what must
//  never be committed. It is therefore pointed at from outside:
//
//      KURN_EVAL_DATA=~/kurn-eval xcodebuild … test
//
//  and the harness skips entirely when the variable is unset, which is how CI
//  runs. That skip is honest rather than convenient: with no reference material
//  there is genuinely nothing to measure, and a green run says only that the
//  metrics themselves are correct.
//
//  Layout — one pair per recording, matched by base name:
//
//      <name>.reference.txt    what was actually said
//      <name>.hypothesis.txt   what the app produced (the Markdown export, or
//                              a transcript copied out of it)
//      <name>.reference.rttm   who spoke when, annotated
//      <name>.hypothesis.rttm  who the diarizer thought spoke when
//

import Foundation

enum EvaluationDataset {

    static let directoryVariable = "KURN_EVAL_DATA"

    static var directoryPath: String? {
        guard let raw = ProcessInfo.processInfo.environment[directoryVariable],
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return NSString(string: raw).expandingTildeInPath
    }

    /// Whether there is a directory to read. Evaluated when the suite is
    /// registered, so the harness reports as skipped rather than as passing over
    /// no data.
    static var isAvailable: Bool {
        guard let directoryPath else { return false }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    struct Pair {
        var name: String
        var reference: String
        var hypothesis: String
    }

    struct AnnotatedAudio {
        var name: String
        var audio: URL
        var reference: String
    }

    /// Audio files that have a reference annotation, for the harness to run the
    /// app's own diarizer over.
    ///
    /// This is the pairing worth having: a hand-pasted hypothesis measures
    /// whatever the app happened to produce on the day it was pasted, while
    /// re-deriving it from the audio measures the code as it stands now, which
    /// is the only version of the question a regression harness can answer.
    static func audioWithReferenceRTTM() throws -> [AnnotatedAudio] {
        guard let directoryPath else { return [] }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: directoryPath)
        let suffix = ".reference.rttm"

        return try names
            .filter { $0.hasSuffix(suffix) }
            .sorted()
            .compactMap { fileName in
                let name = String(fileName.dropLast(suffix.count))
                let audio = ["m4a", "wav", "mp3", "caf"]
                    .map { directory.appendingPathComponent("\(name).\($0)") }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
                guard let audio else { return nil }
                return AnnotatedAudio(
                    name: name,
                    audio: audio,
                    reference: try String(contentsOf: directory.appendingPathComponent(fileName), encoding: .utf8)
                )
            }
    }

    /// Every `<name>.reference<suffix>` with a matching `<name>.hypothesis<suffix>`.
    ///
    /// A reference without its counterpart is skipped silently — half-finished
    /// annotation is the normal state of a corpus being built, and failing the
    /// run over it would make the harness useless exactly when it is being set
    /// up.
    static func pairs(suffix: String) throws -> [Pair] {
        guard let directoryPath else { return [] }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: directoryPath)

        let referenceSuffix = ".reference" + suffix
        return try names
            .filter { $0.hasSuffix(referenceSuffix) }
            .sorted()
            .compactMap { fileName in
                let name = String(fileName.dropLast(referenceSuffix.count))
                let hypothesisURL = directory.appendingPathComponent(name + ".hypothesis" + suffix)
                guard FileManager.default.fileExists(atPath: hypothesisURL.path) else { return nil }
                return Pair(
                    name: name,
                    reference: try String(contentsOf: directory.appendingPathComponent(fileName), encoding: .utf8),
                    hypothesis: try String(contentsOf: hypothesisURL, encoding: .utf8)
                )
            }
    }
}
