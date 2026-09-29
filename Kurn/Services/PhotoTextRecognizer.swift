//
//  PhotoTextRecognizer.swift
//  Kurn
//
//  On-device OCR (Vision) over a meeting photo — the single most useful
//  piece of context a photo taken mid-recording can carry (a whiteboard or
//  slide's text), extracted with no network call, no consent gate, and no
//  cloud LLM cost, unlike a scene caption (a separate, opt-in feature). Runs
//  once per photo, right after capture.
//

import Foundation
import ImageIO
import Vision

enum PhotoTextRecognizer {
    /// Recognize text in the image at `url`. Returns `nil` on any failure or
    /// when nothing was recognized — OCR is best-effort context, never a
    /// reason to fail the photo capture itself.
    static func recognizeText(at url: URL) async -> String? {
        guard let data = try? Data(contentsOf: url),
              let cgImage = cgImage(from: data) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Language correction nudges each recognized token toward the
        // closest dictionary-like word — helpful for a photographed page of
        // prose, actively harmful for the case this feature is really for
        // (a whiteboard or a screen full of code/identifiers): a camelCase
        // variable or an acronym isn't a dictionary word to begin with, so
        // "correcting" it produces a string that is neither the original
        // text nor a real word (e.g. a `successfully` mangled into
        // "sucesftry"). Off, so the result is what the glyphs actually say.
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results else { return nil }
        // Vision does not guarantee reading order in `results` — it groups by
        // its own internal detection order, which for a photographed screen
        // or whiteboard (multiple text blocks at different depths/angles)
        // routinely interleaves unrelated lines. `boundingBox` is normalized
        // with a bottom-left origin, so sorting by descending Y (top first),
        // then ascending X (left first) within a row, reconstructs the
        // top-to-bottom, left-to-right order a reader would actually use.
        let sorted = observations.sorted { lhs, rhs in
            let lhsBox = lhs.boundingBox
            let rhsBox = rhs.boundingBox
            if abs(lhsBox.midY - rhsBox.midY) > 0.01 {
                return lhsBox.midY > rhsBox.midY
            }
            return lhsBox.midX < rhsBox.midX
        }
        let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
