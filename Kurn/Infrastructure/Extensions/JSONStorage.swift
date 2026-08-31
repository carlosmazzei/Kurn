//
//  JSONStorage.swift
//  Kurn
//
//  SwiftData can't persist arbitrary `Codable` arrays, so models store them as
//  JSON `Data` and expose them through computed properties. These helpers hold
//  the shared encode/decode boilerplate so each model doesn't repeat it.
//
//  Two contracts live here, deliberately different:
//
//  - `encode`/`decode` are lenient — a decode failure returns an empty
//    array/`nil`, matching what a genuinely-never-written property already
//    looks like. Fine for content that is either regenerable (highlights,
//    voiceprints, a resumable checkpoint) or a saved search predicate: losing
//    it degrades a feature, it doesn't destroy the user's own words.
//  - `encodeAuthoritative`/`decodeAuthoritative` are for content where that
//    conflation is the bug: a corrupted transcript or summary must never
//    render identically to a legitimately empty one. See their doc comments.
//

import Foundation

enum JSONStorage {
    /// Encode a value to JSON `Data`, falling back to empty `Data` on failure so
    /// a persisted property always has a concrete value.
    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    /// Decode a JSON array from `Data`, falling back to an empty array on failure.
    static func decode<T: Decodable>(_ type: [T].Type, from data: Data) -> [T] {
        (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    /// Decode a single JSON value from `Data`, falling back to `nil` on failure.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Authoritative content

    private struct Envelope: Codable {
        let version: Int
        let payloadChecksum: UInt64
        let payload: Data
    }

    private static let envelopeVersion = 1

    /// FNV-1a over the raw bytes. Chosen over Swift's `Hasher`/`hashValue`,
    /// which are explicitly randomized per process launch as a
    /// hash-flooding defense — exactly the property that makes them unusable
    /// for a checksum that has to compare equal in a *different* process
    /// than the one that wrote it. FNV-1a is deterministic across launches
    /// and platforms, and needs no dependency for something this small.
    private static func fnv1aChecksum(of data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// Encodes `value` behind a versioned envelope carrying a checksum of the
    /// payload bytes, for content whose corruption must be identified rather
    /// than silently treated as absent — see `decodeAuthoritative`.
    ///
    /// Returns `nil` on an encode failure instead of `Data()`. `JSONEncoder`
    /// throws for a handful of real cases here (chiefly a NaN or infinite
    /// `Double`/`Float`, which JSON has no representation for, and which a
    /// pipeline confidence score or timestamp could in principle produce);
    /// the previous `encode`'s `?? Data()` fallback turned that failure into
    /// content indistinguishable from "nothing was ever recorded". A caller
    /// persisting authoritative content is expected to fail the save on
    /// `nil` rather than store it.
    static func encodeAuthoritative<T: Encodable>(_ value: T) -> Data? {
        guard let payload = try? JSONEncoder().encode(value) else { return nil }
        let envelope = Envelope(version: envelopeVersion, payloadChecksum: fnv1aChecksum(of: payload), payload: payload)
        return try? JSONEncoder().encode(envelope)
    }

    /// The corruption-aware counterpart to `encodeAuthoritative`.
    ///
    /// Zero stored bytes is `.empty` — nothing was ever written, the normal
    /// state for a new row. Anything else is checked two ways before being
    /// called `.corrupted`: first as an envelope (unwrapped and verified
    /// against its checksum, which catches a bit-level change that still
    /// happens to parse as valid JSON — a plain decode alone would silently
    /// accept it), then, if that fails, as bare `T` with no envelope, since
    /// every row written before this format existed looks exactly like
    /// that. A successful legacy-format decode is real content, not
    /// corruption; only what fails *both* reads is `.corrupted`, and it
    /// carries the original bytes rather than discarding them, so a future
    /// recovery or diagnostic path has something to work with.
    static func decodeAuthoritative<T: Decodable>(_ type: T.Type, from data: Data) -> JSONDecodeOutcome<T> {
        guard !data.isEmpty else { return .empty }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           envelope.payloadChecksum == fnv1aChecksum(of: envelope.payload),
           let value = try? JSONDecoder().decode(T.self, from: envelope.payload) {
            return .value(value)
        }
        if let legacyValue = try? JSONDecoder().decode(T.self, from: data) {
            return .value(legacyValue)
        }
        return .corrupted(originalData: data)
    }
}

/// Result of `JSONStorage.decodeAuthoritative`. A plain `T?` (as the lenient
/// `decode` returns) cannot tell a caller "there is nothing here" apart from
/// "there is something here and it's broken" — which is exactly the
/// distinction authoritative content exists to preserve.
enum JSONDecodeOutcome<Value> {
    case empty
    case value(Value)
    case corrupted(originalData: Data)

    /// The decoded value, or `nil` for both `.empty` and `.corrupted`. For a
    /// getter that still needs to return a bare `[T]`/`T?` to its many
    /// existing callers; prefer switching on the outcome itself wherever the
    /// distinction matters (e.g. `isSegmentsDataCorrupted`). Named
    /// `decodedValue` rather than `value` to stay unambiguous next to the
    /// `.value(Value)` case above.
    var decodedValue: Value? {
        if case .value(let value) = self { return value }
        return nil
    }

    var isCorrupted: Bool {
        if case .corrupted = self { return true }
        return false
    }
}
