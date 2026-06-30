//
//  PassthroughPreprocessor.swift
//  Kurn
//
//  No-op preprocessing engine: feeds the original recording straight to the
//  transcription path with no DSP cleanup. Selected via
//  `PreprocessingEngine.none` for users who prefer the raw audio (or want to
//  skip the cleanup cost).
//

import Foundation

struct PassthroughPreprocessor: AudioPreprocessing {
    /// Returns the input unchanged. The caller compares the result to the input
    /// before scheduling cleanup, so no temporary file is created here.
    func process(url: URL) async throws -> URL { url }

    /// Nothing to clean up — the original recording is owned elsewhere.
    func cleanup(_ url: URL) async {}
}
