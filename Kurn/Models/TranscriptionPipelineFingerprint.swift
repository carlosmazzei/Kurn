//
//  TranscriptionPipelineFingerprint.swift
//  Kurn
//
//  Identity of a chunked transcription run, used to decide whether a persisted
//  `TranscriptionCheckpoint` may seed a resume (H4). `TranscriptionCheckpoint`
//  used to compare only engine, language, VAD-compaction on/off, and the
//  transcription provider — mutating the source audio, switching preprocessing
//  or VAD, or landing on a different compaction map while those four fields
//  happened to stay the same could still splice incompatible chunks together
//  into one transcript. Every field here is either an exact content identity
//  (the source digest, the compaction-map digest) or a configuration choice
//  that changes what the engine actually produces; a mismatch in any one of
//  them means "not the same run," full stop.
//
//  The exact chunk plan (which depends on chunking having already run) is
//  deliberately not part of this type — see `TranscriptionCheckpoint.chunkPlanDigest`.
//

import Foundation
import KurnCore

struct TranscriptionPipelineFingerprint: Codable, Sendable, Equatable {
    /// Bump when a change to fusion's input shape, chunking semantics, or how
    /// this fingerprint itself is computed would make an old checkpoint's
    /// spans unsafe to reuse even though every other field below still
    /// matches.
    static let currentAlgorithmVersion = 1

    var algorithmVersion: Int
    /// Byte size of the original, unprocessed recording file.
    var sourceFileSize: Int64
    /// Duration of the original recording, seconds, stored at full precision
    /// but compared rounded to hundredths (see `==`) so float jitter between
    /// two `AVURLAsset` loads of the same file can't turn into a spurious
    /// mismatch. Rounding lives in the comparison rather than at
    /// construction time so it also covers a value set after construction
    /// (mutating this `var` directly) or decoded from JSON (synthesized
    /// `Codable` sets stored properties directly, bypassing `init`).
    var sourceDuration: TimeInterval
    /// SHA-256 of the original recording's bytes, or `nil` when the file
    /// couldn't be validated (unreadable, or a non-finite/zero duration).
    /// `nil` never equals `nil` — see `==` below — so an unverified source
    /// can never seed a resume; that is the safe direction; restart rather
    /// than trust an unverifiable file.
    var sourceDigest: String?
    var preprocessingRaw: String
    var vadRaw: String
    var languageRaw: String
    var engineRaw: String
    /// Exact swappable back-end: the transcription provider id for
    /// `.whisperAPI`, the weight-file variant for `.whisperCpp`. `nil` for
    /// engines with no such axis (Apple Speech, FluidAudio Parakeet).
    var providerID: String?
    /// Whether the engine ran over the VAD-compacted copy rather than the
    /// preprocessed original.
    var compacted: Bool
    /// SHA-256 over the VAD-compaction map's segments, `nil` when `compacted`
    /// is false. Two runs can agree on VAD engine and still compact
    /// differently if the upstream audio changed or VAD itself isn't
    /// perfectly deterministic.
    var compactionDigest: String?

    init(
        sourceFileSize: Int64,
        sourceDuration: TimeInterval,
        sourceDigest: String?,
        preprocessing: PreprocessingEngine,
        vad: VADEngine,
        language: MeetingLanguage,
        engine: TranscriptionEngine,
        providerID: String?,
        compacted: Bool,
        compactionDigest: String?,
        algorithmVersion: Int = TranscriptionPipelineFingerprint.currentAlgorithmVersion
    ) {
        self.algorithmVersion = algorithmVersion
        self.sourceFileSize = sourceFileSize
        self.sourceDuration = sourceDuration
        self.sourceDigest = sourceDigest
        self.preprocessingRaw = preprocessing.rawValue
        self.vadRaw = vad.rawValue
        self.languageRaw = language.rawValue
        self.engineRaw = engine.rawValue
        self.providerID = providerID
        self.compacted = compacted
        self.compactionDigest = compactionDigest
    }

    /// Content-identity equality. A `nil` `sourceDigest` on either side means
    /// "this run's source was never verified" and can't be proven identical
    /// to anything, including another equally-unverified fingerprint, so it
    /// always compares unequal rather than accidentally matching two
    /// unrelated unverifiable runs.
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard let lhsDigest = lhs.sourceDigest, let rhsDigest = rhs.sourceDigest, lhsDigest == rhsDigest else {
            return false
        }
        return lhs.algorithmVersion == rhs.algorithmVersion
            && lhs.sourceFileSize == rhs.sourceFileSize
            && (lhs.sourceDuration * 100).rounded() == (rhs.sourceDuration * 100).rounded()
            && lhs.preprocessingRaw == rhs.preprocessingRaw
            && lhs.vadRaw == rhs.vadRaw
            && lhs.languageRaw == rhs.languageRaw
            && lhs.engineRaw == rhs.engineRaw
            && lhs.providerID == rhs.providerID
            && lhs.compacted == rhs.compacted
            && lhs.compactionDigest == rhs.compactionDigest
    }
}
