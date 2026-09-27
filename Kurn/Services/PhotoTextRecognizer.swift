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
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results else { return nil }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
